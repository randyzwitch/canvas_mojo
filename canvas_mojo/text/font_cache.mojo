"""A per-caller cache of fontconfig's own family/slant/weight[/codepoint]
-> font-file-path resolution.

canvas_mojo/text/render.mojo's own _load_sized_face/_resolve_glyph
docstrings flagged the *lack* of this caching as a deliberate
simplification -- "correctness first... not a caching layer built
ahead of a concrete need." Profiling showed that need directly:
resolve_font_file/resolve_font_file_for_char (font_discovery.mojo)
used to open libfontconfig and, on Linux, unconditionally spawn real
`ldconfig -p`/`pkg-config` subprocesses on *every* call, ~35ms of it,
just to relocate a library that was already found the call before.
font_discovery.mojo's own _cheap_fontconfig_candidates/
_open_fontconfig_library docstrings cover the real fix for that --
try the library's plain canonical name (no subprocess) first, only
falling through to the subprocess-based hints if that actually fails
-- which cuts an uncached resolve_font_file call to a few ms on a
first call and under a millisecond on every one after (the OS's own
dlopen refcounting already makes a repeat load of the identical
library near-free, once nothing is paying to rediscover its own path
first).

That leaves what this cache still exists for: fontconfig's own
per-call pattern-construction/matching work (FcPatternCreate/
FcFontMatch/etc, still real, still paid on every resolve_font_file
call whether or not the library itself needed reloading) and, more
concretely, draw_text()'s own internal duplication -- a single call
resolves its font *twice* (once measuring via _layout_block, once
again rendering) without this cache threading one FontCache through
both passes. Every fallback glyph (resolve_font_file_for_char, used
when the requested font lacks a codepoint) still resolves
independently too, so a string with several fallback glyphs for the
same missing codepoint benefits from being asked only once instead of
once per glyph.

Also caches the parsed TTFFace itself now, not just the resolved
path -- profiling *did* say otherwise (dataviz_mojo measured
TTFFace's own parse + set_pixel_size at ~0.127ms each, against a
cache hit at ~0.00015ms; draw_text's own two-pass measure/render
split means every call paid that twice, ~0.255ms of it, even with
the path-only cache above already in play). The objection this
module's own docstring used to raise here -- TTFFace owns the whole
font file's raw bytes (`data: List[UInt8]`, Movable only, not
ImplicitlyCopyable), so caching it "for real" would mean copying a
multi-hundred-KB buffer out of the Dict on every hit -- is sidestepped
entirely by `ArcPointer[TTFFace]` rather than solved by widening
TTFFace's own trait surface: the Dict holds one heap-allocated
TTFFace per distinct (path, pixel size), and every `resolve_face`/
`resolve_face_for_char` hit just bumps an atomic refcount and returns
a copy of the pointer, not the payload. `set_pixel_size` (the one
method that actually mutates a TTFFace) is called exactly once, at
the point a face is first inserted -- every later hit returns that
same already-sized instance, never calls it again -- so caching by
`path + "@" + pixel_size` (not by path alone) is what keeps two
callers asking for the same font at two different sizes from
corrupting each other's scale state.

Mojo has no mutable global/module-level state (confirmed directly:
declaring one raises "global variables are not supported"; the same
wall _load_sized_face's own docstring already references as "no
global handle available yet"). So this cache can't live behind the
scenes automatically the way it might in a language that allows a
lazily-initialized global -- a caller that renders many labels off the
same font(s) (a chart's axis ticks and legend, say) creates one
FontCache and passes it into draw_text/measure_text/measure_text_block
themselves (the `cache=` keyword-only overload of each), reusing it
across every call. Callers that don't pass one keep today's exact
per-call, uncached resolution -- unchanged, never slower, just not
faster either.
"""

from std.math import ceil
from std.memory import ArcPointer

from canvas_mojo.text.font_discovery import (
    FontSlant,
    FontWeight,
    resolve_font_file,
    resolve_font_file_for_char,
)
from canvas_mojo.text.ttf import TTFFace


def _slant_key(slant: FontSlant) -> String:
    # FontSlant's own `_value` is private to font_discovery.mojo (see
    # that module's own convention for underscore-prefixed members) --
    # this mirrors font_discovery.mojo's own _fc_slant_value, comparing
    # against the three public NORMAL/ITALIC/OBLIQUE constants instead
    # of reaching into the private field directly.
    if slant == FontSlant.ITALIC:
        return "italic"
    if slant == FontSlant.OBLIQUE:
        return "oblique"
    return "normal"


def _weight_key(weight: FontWeight) -> String:
    if weight == FontWeight.BOLD:
        return "bold"
    return "normal"


def _cache_key(family: String, slant: FontSlant, weight: FontWeight) -> String:
    return family + "|" + _slant_key(slant) + "|" + _weight_key(weight)


struct FontCache(Movable):
    """See this module's own docstring. Construct one, then pass it
    (by `cache=`) into draw_text/measure_text/measure_text_block for
    every call expected to reuse the same font(s) -- there's no setup
    or cleanup step beyond that, it's just two plain Dicts.
    """

    var _paths: Dict[String, String]
    var _paths_for_char: Dict[String, String]
    var _faces: Dict[String, ArcPointer[TTFFace]]

    def __init__(out self):
        self._paths = Dict[String, String]()
        self._paths_for_char = Dict[String, String]()
        self._faces = Dict[String, ArcPointer[TTFFace]]()

    def _face_for_path(mut self, path: String, size: Float64) raises -> ArcPointer[TTFFace]:
        """Shared by resolve_face/resolve_face_for_char below -- both
        just need a parsed, sized TTFFace for a font *path* they've
        already resolved (one via `resolve`, the other via
        `resolve_for_char`); this is where that path turns into a
        cached, shared face, regardless of which one asked.

        Keyed on `path + "@" + pixel_size`, not `path` alone: two
        callers requesting the same font at two different sizes must
        land in two different cache entries, since `set_pixel_size`
        (called once, right here, on insert) mutates the instance
        they'd otherwise share.
        """
        var pixel_size = Int(ceil(size))
        var key = path + "@" + String(pixel_size)
        if key in self._faces:
            return self._faces[key]
        var face = TTFFace(path)
        face.set_pixel_size(pixel_size)
        var arc = ArcPointer(face^)
        self._faces[key] = arc
        return arc

    def resolve(mut self, family: String, slant: FontSlant, weight: FontWeight) raises -> String:
        """Cached resolve_font_file: fontconfig is only ever actually
        asked once per distinct (family, slant, weight) this cache has
        seen -- every later call for the identical combination returns
        the already-resolved path straight from the Dict.
        """
        var key = _cache_key(family, slant, weight)
        if key in self._paths:
            return self._paths[key]
        var path = resolve_font_file(family, slant, weight)
        self._paths[key] = path
        return path

    def resolve_for_char(
        mut self, family: String, slant: FontSlant, weight: FontWeight, codepoint: Int
    ) raises -> String:
        """Cached resolve_font_file_for_char -- same idea as resolve()
        above, keyed additionally on `codepoint` (a charset-constrained
        match can legitimately return a different font than the
        unconstrained one), so repeated fallback glyphs for the same
        missing codepoint (e.g. a string with several CJK characters
        under a Latin-only family) each cost fontconfig exactly once.
        """
        var key = _cache_key(family, slant, weight) + "|" + String(codepoint)
        if key in self._paths_for_char:
            return self._paths_for_char[key]
        var path = resolve_font_file_for_char(family, slant, weight, codepoint)
        self._paths_for_char[key] = path
        return path

    def resolve_face(
        mut self, family: String, slant: FontSlant, weight: FontWeight, size: Float64
    ) raises -> ArcPointer[TTFFace]:
        """`resolve` (cached path) + parse-and-size (now also cached,
        via `_face_for_path`) in one call -- the replacement for what
        `render.mojo`'s own `_load_sized_face` used to do inline every
        time it was called. render.mojo's own draw_text calls this
        twice per invocation (once via `_layout_block`'s measuring
        pass, once again for its own render pass) -- with a `cache`
        shared between the two, the second call is a face-cache hit,
        not a second parse of the same font file.
        """
        var path = self.resolve(family, slant, weight)
        return self._face_for_path(path, size)

    def resolve_face_for_char(
        mut self, family: String, slant: FontSlant, weight: FontWeight, codepoint: Int, size: Float64
    ) raises -> ArcPointer[TTFFace]:
        """`resolve_for_char` (cached path) + parse-and-size (also
        cached) in one call -- the fallback-glyph counterpart to
        `resolve_face` above, for `render.mojo`'s own `_resolve_glyph`.
        A string with several fallback glyphs for the same missing
        codepoint already got its fontconfig resolution deduplicated
        by `resolve_for_char`'s own cache; this also stops each one
        from re-parsing that same fallback font file from scratch.
        """
        var path = self.resolve_for_char(family, slant, weight, codepoint)
        return self._face_for_path(path, size)

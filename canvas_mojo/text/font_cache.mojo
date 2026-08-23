"""A per-caller cache of fontconfig's own family/slant/weight[/codepoint]
-> font-file-path resolution, and of the parsed, sized `TTFFace` behind
each resolved path.

What the path half saves: fontconfig's own per-call pattern-
construction/matching work (FcPatternCreate/FcFontMatch/etc, paid on
every `resolve_font_file` call) -- and, more concretely, draw_text()'s
own internal duplication, since a single call resolves its font
*twice* (once measuring via _layout_block, once again rendering)
unless one FontCache is threaded through both passes. Every fallback
glyph (resolve_font_file_for_char, used when the requested font lacks
a codepoint) resolves independently too, so a string with several
fallback glyphs for the same missing codepoint is asked only once
instead of once per glyph.

What the face half saves: TTFFace's own parse + set_pixel_size costs
~0.127ms, against a cache hit at ~0.00015ms (measured in
dataviz_mojo), and draw_text's two-pass measure/render split pays it
twice per call. TTFFace owns the whole font file's raw bytes
(`data: List[UInt8]`, Movable only, not ImplicitlyCopyable), so the
Dict holds `ArcPointer[TTFFace]` rather than the face itself: one
heap-allocated TTFFace per distinct (path, pixel size), and every
`resolve_face`/`resolve_face_for_char` hit bumps an atomic refcount
and returns a copy of the pointer, not the payload. `set_pixel_size`
(the one method that actually mutates a TTFFace) is called exactly
once, at the point a face is first inserted -- every later hit returns
that same already-sized instance -- so keying by `path + "@" +
pixel_size` (not by path alone) is what keeps two callers asking for
the same font at two different sizes from corrupting each other's
scale state.

Mojo has no mutable global/module-level state (confirmed directly:
declaring one raises "global variables are not supported"), so this
cache can't live behind the scenes automatically the way it might in a
language that allows a lazily-initialized global. A caller that
renders many labels off the same font(s) (a chart's axis ticks and
legend, say) creates one FontCache and passes it into draw_text/
measure_text/measure_text_block themselves (the `cache=` keyword-only
overload of each), reusing it across every call. Callers that don't
pass one get per-call, uncached resolution.
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
        """`resolve` (cached path) + parse-and-size (also cached, via
        `_face_for_path`) in one call -- what `render.mojo`'s own
        `_load_sized_face` is a thin wrapper around. render.mojo's own
        draw_text calls this twice per invocation (once via
        `_layout_block`'s measuring pass, once again for its own render
        pass) -- with a `cache`
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

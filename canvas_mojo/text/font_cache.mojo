"""A per-caller cache of fontconfig's own family/slant/weight[/codepoint]
-> font-file-path resolution.

canvas_mojo/text/render.mojo's own _load_sized_face/_resolve_glyph
docstrings flagged the *lack* of this caching as a deliberate
simplification -- "correctness first... not a caching layer built
ahead of a concrete need." Profiling now shows that need, directly:
resolve_font_file/resolve_font_file_for_char (font_discovery.mojo)
each open libfontconfig and, on Linux, spawn real `ldconfig -p`/
`pkg-config` subprocesses just to relocate a library that was already
found the call before -- ~35ms per call, confirmed via a timing probe,
*including* two back-to-back calls for the identical (family, slant,
weight). Every fallback glyph (resolve_font_file_for_char, used when
the requested font lacks a codepoint) pays this again on its own: a
3-fallback-glyph string alone costs ~270ms. A single draw_text() call
even pays it *twice* internally today (once measuring via
_layout_block, once again rendering) before this cache existed.

Deliberately does *not* also cache the parsed TTFFace -- only the
resolved path. TTFFace holds the entire font file's own raw bytes
(`data: List[UInt8]`, Movable only, not ImplicitlyCopyable) and
parsing one already costs only ~2ms of the ~35-40ms a path-cache hit
here saves; making TTFFace copyable just to claw back that remaining
~2ms would mean copying a multi-hundred-KB-to-multi-MB buffer out of
the cache on every hit, and would widen TTFFace's own public trait
surface for a sub-5% marginal win. Not worth it unless profiling says
otherwise later.

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

from canvas_mojo.text.font_discovery import (
    FontSlant,
    FontWeight,
    resolve_font_file,
    resolve_font_file_for_char,
)


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

    def __init__(out self):
        self._paths = Dict[String, String]()
        self._paths_for_char = Dict[String, String]()

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

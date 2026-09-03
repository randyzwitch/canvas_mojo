"""A per-caller cache of the family/slant/weight[/codepoint] -> font-
file-path resolution `font_discovery.mojo` does, and of the parsed,
sized `TTFFace` behind each resolved path.

The path half saves a rescan of the font directories per
`resolve_font_file` call, including draw_text()'s own duplication: one
call resolves its font twice, measuring then rendering, unless a
FontCache threads through both passes.

Behind both halves sits one `FontDatabase`, built in `__init__`, which is
where the directory walk and per-file table reads are paid. Constructing
a FontCache therefore does a few milliseconds of real work: construct
one per run of many labels, not one per label.

The face half saves TTFFace's parse + set_pixel_size. TTFFace owns the
font file's raw bytes (`data: List[UInt8]`, Movable only), so the Dict
holds `ArcPointer[TTFFace]`: one heap-allocated face per (path, pixel
size), and a hit bumps a refcount rather than copying the payload.
`set_pixel_size`, the one mutating method, runs once at insert, and
keying by `path + "@" + pixel_size` rather than path alone keeps two
callers at different sizes from corrupting each other's scale state.

Mojo has no mutable global state (declaring one raises "global variables
are not supported"), so there is no implicit shared cache. Pass one
FontCache to draw_text/measure_text/measure_text_block through their
`cache=` keyword-only overloads; callers that don't get per-call
resolution.
"""

from std.math import ceil
from std.memory import ArcPointer

from canvas.text.font_discovery import (
    FontDatabase,
    FontSlant,
    FontWeight,
)
from canvas.text.ttf import TTFFace


def _slant_key(slant: FontSlant) -> String:
    # FontSlant's `_value` is private to font_discovery.mojo, so this
    # compares against the public NORMAL/ITALIC/OBLIQUE constants, as
    # that module's own `_requested_slant` does.
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
    """Construct one, then pass it by `cache=` into
    draw_text/measure_text/measure_text_block for every call reusing
    the same fonts. No cleanup; setup is the one font scan `__init__`
    does, which is the work every later lookup then skips.
    """

    var _database: FontDatabase
    var _paths: Dict[String, String]
    var _paths_for_char: Dict[String, String]
    var _faces: Dict[String, ArcPointer[TTFFace]]

    def __init__(out self):
        """Scans the installed fonts once -- see this module's
        docstring for why that happens here rather than per lookup.
        """
        self._database = FontDatabase()
        self._paths = Dict[String, String]()
        self._paths_for_char = Dict[String, String]()
        self._faces = Dict[String, ArcPointer[TTFFace]]()

    def _face_for_path(
        mut self, path: String, size: Float64
    ) raises -> ArcPointer[TTFFace]:
        """Turns an already-resolved font *path* into a cached, shared
        face; resolve_face and resolve_face_for_char both land here.

        Keyed on `path + "@" + pixel_size`, not path alone: two callers
        wanting the same font at different sizes need different
        entries, since `set_pixel_size` (called once, here, on insert)
        mutates the instance they'd otherwise share.
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

    def resolve(
        mut self, family: String, slant: FontSlant, weight: FontWeight
    ) raises -> String:
        """Cached resolve_font_file: the scanned font database is
        matched once per distinct (family, slant, weight), and every
        later call for that combination reads the path from the Dict.

        Args:
            family: Font family name or generic alias.
            slant: Requested upright/italic/oblique style.
            weight: Requested normal/bold weight.

        Returns:
            The matched font's absolute file path.

        Raises:
            Error: no fonts are installed on this machine.
        """
        var key = _cache_key(family, slant, weight)
        if key in self._paths:
            return self._paths[key]
        var path = self._database.resolve(family, slant, weight)
        self._paths[key] = path
        return path

    def resolve_for_char(
        mut self,
        family: String,
        slant: FontSlant,
        weight: FontWeight,
        codepoint: Int,
    ) raises -> String:
        """Cached resolve_font_file_for_char, keyed additionally on
        `codepoint`, since a charset-constrained match can return a
        different font than the unconstrained one.

        Args:
            family: Font family name or generic alias.
            slant: Requested upright/italic/oblique style.
            weight: Requested normal/bold weight.
            codepoint: Unicode codepoint the matched font should
                contain.

        Returns:
            The matched font's absolute file path.

        Raises:
            Error: no fonts are installed on this machine.
        """
        var key = _cache_key(family, slant, weight) + "|" + String(codepoint)
        if key in self._paths_for_char:
            return self._paths_for_char[key]
        var path = self._database.resolve(family, slant, weight, codepoint)
        self._paths_for_char[key] = path
        return path

    def resolve_face(
        mut self,
        family: String,
        slant: FontSlant,
        weight: FontWeight,
        size: Float64,
    ) raises -> ArcPointer[TTFFace]:
        """`resolve` plus `_face_for_path` in one call, wrapped by
        `render.mojo`'s `_load_sized_face`. draw_text calls it twice per
        invocation, so with a shared `cache` the second is a hit.

        Args:
            family: Font family name or generic alias.
            slant: Requested upright/italic/oblique style.
            weight: Requested normal/bold weight.
            size: Pixel size to rasterize glyphs at.

        Returns:
            The resolved, sized font face, shared across every caller
            requesting the same (path, size).

        Raises:
            Error: no fonts are installed on this machine, or the
                resolved file can't be parsed.
        """
        var path = self.resolve(family, slant, weight)
        return self._face_for_path(path, size)

    def resolve_face_for_char(
        mut self,
        family: String,
        slant: FontSlant,
        weight: FontWeight,
        codepoint: Int,
        size: Float64,
    ) raises -> ArcPointer[TTFFace]:
        """`resolve_face`'s fallback-glyph counterpart. `resolve_for_char`
        deduplicates the path lookup; this also stops each fallback glyph
        from re-parsing the file.

        Args:
            family: Font family name or generic alias.
            slant: Requested upright/italic/oblique style.
            weight: Requested normal/bold weight.
            codepoint: Unicode codepoint the matched font should
                contain.
            size: Pixel size to rasterize glyphs at.

        Returns:
            The resolved, sized font face, shared across every caller
            requesting the same (path, size).

        Raises:
            Error: no fonts are installed on this machine, or the
                resolved file can't be parsed.
        """
        var path = self.resolve_for_char(family, slant, weight, codepoint)
        return self._face_for_path(path, size)

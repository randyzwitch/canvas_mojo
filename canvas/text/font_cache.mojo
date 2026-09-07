"""A per-caller cache of the family/slant/weight[/codepoint] -> font-
file-path resolution `font_discovery.mojo` does, and of the parsed,
sized `TTFFace` behind each resolved path.

The path half saves a rescan of the font directories per
`resolve_font_file` call, including draw_text()'s own duplication: one
call resolves its font twice, measuring then rendering, unless a
FontCache threads through both passes.

Behind both halves sits one `FontDatabase`, built on the first lookup
that misses the path dictionaries. That build reads
`font_discovery.mojo`'s cache file when one is valid, a millisecond or
two; when none is (first run on a machine, or a font installed since)
it walks the font directories and reads every file's tables, tens of
milliseconds, and writes the file for next time. Either way it is paid
once per `FontDatabase` and scales with how many fonts are installed
rather than with what is being drawn -- against tens of *micro*seconds
for a cached label. Construct one per run of many labels, never one
per label. Constructing it costs nothing, so a cache shared across
code that may or may not draw text pays it only if some of it does
(#199).

The overloads that take no `cache=` build one of these per call, so they
carry that whole scan every time. See `canvas.text.render`, whose
docstrings say what that costs.

The face half saves TTFFace's parse + set_pixel_size. TTFFace owns the
font file's raw bytes (`data: List[UInt8]`, Movable only), so the Dict
holds `ArcPointer[TTFFace]`: one heap-allocated face per (path, pixel
size), and a hit bumps a refcount rather than copying the payload.
`set_pixel_size`, the one mutating method, runs once at insert, and
keying by `path + "@" + pixel_size` rather than path alone keeps two
callers at different sizes from corrupting each other's scale state.

The third half is rasterized glyphs. `draw_text` keys each unrotated
glyph by face, pixel size, codepoint and the glyph origin's sub-pixel
offset in 1/64 px, and stores its coverage as the sub-sample counts
the anti-aliased sweep computed (`_GlyphMask`); a hit composites the
counts instead of extracting and sweeping the outline again, for the
pixels a direct fill would write. This is what makes a cached label
tens of microseconds rather than a millisecond.

That store is bounded by bytes rather than by entry count, because a
72-pixel glyph's mask is forty times a 12-pixel one's and a count
cannot tell them apart. It is held in two generations: new masks go
into the young one, and when that reaches half the budget the old one
is released and the young becomes old. A mask found in the old
generation moves back to the young, so anything still in use survives
each turnover and only what has gone unused since the last one is
released. See `_store_glyph_mask`.

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
    FontFace,
    FontSlant,
    FontWeight,
)
from canvas.path import _CoverageMask
from canvas.text.ttf import TTFFace

# Distinct (face, size, codepoint, sub-pixel offset) masks kept before
# the glyph mask cache is emptied and starts over. A 13 px glyph mask
# is around 200 bytes, so this bounds the cache at a few megabytes for
# the largest text a chart draws.
# What the rasterized-glyph store may hold, in bytes of mask plus keys
# plus per-entry overhead, across both generations. A generation turns
# over at half of it.
#
# 32 MB is at least as permissive as the 4,096-entry cap it replaces --
# that allowed about 30 MB of 72-pixel masks -- and far more permissive
# for the small text a chart is mostly made of, where an entry is a few
# hundred bytes and this holds six figures of them.
comptime _GLYPH_MASK_BUDGET = 32 << 20
comptime _GLYPH_GENERATION_BUDGET = _GLYPH_MASK_BUDGET // 2

# ...and how many entries either generation may hold. Bytes alone are
# not enough: a store of small masks stays far inside the byte budget
# while growing to tens of thousands of entries, and a dictionary that
# size costs more to probe. Holding 14,000 masks measured a warm
# lookup at 17 us against 10 us for the 4,096-entry store this
# replaces, which is a bad trade for hits that were already cheap. Two
# generations of 2,048 keep the total where it was.
comptime _GLYPH_GENERATION_ENTRIES = 2048

# Charged per entry on top of its mask and its key, for the dictionary
# slot and the struct around them. An estimate, and deliberately
# generous: its job is to keep a flood of tiny masks from overrunning
# the budget by a wide margin, not to be exact.
comptime _GLYPH_ENTRY_OVERHEAD = 96


struct _GlyphMask(Copyable, Movable):
    """One glyph as `draw_text` composites it: its advance, and its
    coverage rasterized at a given sub-pixel offset. A whitespace glyph
    has an advance and an empty mask.
    """

    var advance: Float64
    var mask: _CoverageMask

    def __init__(out self, advance: Float64, var mask: _CoverageMask):
        self.advance = advance
        self.mask = mask^


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
    the same fonts. No cleanup, and no setup: the one font scan happens
    on the first lookup, and every later lookup skips it.
    """

    var _database: FontDatabase
    # Whether `_database` is the installed fonts yet. Until the first
    # lookup that misses the path dictionaries it is empty, and
    # `_scan_if_needed` replaces it with a scan once.
    var _scanned: Bool
    var _paths: Dict[String, String]
    var _paths_for_char: Dict[String, String]
    var _faces: Dict[String, ArcPointer[TTFFace]]
    # Rasterized glyphs, in two generations: `_glyph_masks` is the
    # young one every insert goes into, `_glyph_masks_old` the one it
    # displaced. See this module's docstring.
    var _glyph_masks: Dict[String, _GlyphMask]
    var _glyph_masks_old: Dict[String, _GlyphMask]
    var _glyph_bytes: Int
    var _glyph_bytes_old: Int
    var _glyph_turnovers: Int

    def __init__(out self):
        """Scans nothing. The installed fonts are read on the first
        lookup that misses the path dictionaries -- see this module's
        docstring for why once, and why then.
        """
        self._database = FontDatabase(List[FontFace]())
        self._scanned = False
        self._paths = Dict[String, String]()
        self._paths_for_char = Dict[String, String]()
        self._faces = Dict[String, ArcPointer[TTFFace]]()
        self._glyph_masks = Dict[String, _GlyphMask]()
        self._glyph_masks_old = Dict[String, _GlyphMask]()
        self._glyph_bytes = 0
        self._glyph_bytes_old = 0
        self._glyph_turnovers = 0

    def has_scanned(self) -> Bool:
        """Whether the installed fonts have been scanned yet: False
        after construction, True from the first lookup that needed
        them.

        Returns:
            True once the scan has happened.
        """
        return self._scanned

    def _scan_if_needed(mut self):
        """Build the `FontDatabase` on the first call, and do nothing
        after. Called only on a path-dictionary miss, so a hit never
        reaches it.
        """
        if self._scanned:
            return
        self._database = FontDatabase()
        self._scanned = True

    def glyph_mask_count(self) -> Int:
        """How many rasterized glyph masks the cache holds.

        Returns:
            The number of distinct (face, size, codepoint, sub-pixel
            offset) masks cached so far, across both generations.
        """
        return len(self._glyph_masks) + len(self._glyph_masks_old)

    def glyph_mask_bytes(self) -> Int:
        """How much the rasterized-glyph store is holding.

        Counts each entry's mask, its key, and a fixed charge for the
        dictionary slot around them, across both generations. Stays
        under `_GLYPH_MASK_BUDGET` except while a single mask larger
        than a generation's share is live, which is possible only for
        very large text and lasts one turnover.

        Returns:
            Bytes currently held.
        """
        return self._glyph_bytes + self._glyph_bytes_old

    def glyph_mask_turnovers(self) -> Int:
        """How many times the store has released a generation.

        Zero until a run of distinct glyphs reaches one of the two
        bounds. Useful for confirming that a workload actually
        exercises eviction rather than merely fitting.

        Returns:
            The number of turnovers so far.
        """
        return self._glyph_turnovers

    def clear_glyph_masks(mut self):
        """Release every rasterized glyph mask, keeping the resolved
        font paths and faces. The next draw re-rasterizes what it
        needs, at the cost of a cold label.
        """
        self._glyph_masks = Dict[String, _GlyphMask]()
        self._glyph_masks_old = Dict[String, _GlyphMask]()
        self._glyph_bytes = 0
        self._glyph_bytes_old = 0

    def _entry_bytes(self, key: String, entry: _GlyphMask) -> Int:
        return (
            key.byte_length() + len(entry.mask.counts) + _GLYPH_ENTRY_OVERHEAD
        )

    def _ensure_glyph_mask(mut self, key: String) raises -> Bool:
        """Whether `key` is in the young generation once this returns.

        A mask found in the old generation moves back to the young one,
        which is what keeps a label that is still being drawn from
        being released at the next turnover. Moved, not copied: the
        counts are handed over rather than duplicated.
        """
        if key in self._glyph_masks:
            return True
        if key not in self._glyph_masks_old:
            return False
        var entry = self._glyph_masks_old.pop(key)
        var cost = self._entry_bytes(key, entry)
        self._glyph_bytes_old -= cost
        self._insert_glyph_mask(key, entry^, cost)
        return True

    def _insert_glyph_mask(
        mut self, key: String, var entry: _GlyphMask, cost: Int
    ):
        """Put an entry in the young generation, turning the
        generations over first if it no longer fits.

        Turning over releases the old generation and makes the young
        one old, so what is released is exactly what has not been
        looked up since the previous turnover. Either bound can force
        it: entries, which is what keeps a lookup cheap, or bytes,
        which is what keeps a page of 72-pixel headings from holding
        tens of megabytes. A mask on its own larger than a
        generation's share does not trigger the byte bound against an
        empty young generation, since there would be nothing to
        release and it would loop.
        """
        if len(self._glyph_masks) >= _GLYPH_GENERATION_ENTRIES or (
            self._glyph_bytes > 0
            and self._glyph_bytes + cost > _GLYPH_GENERATION_BUDGET
        ):
            self._glyph_masks_old = self._glyph_masks^
            self._glyph_bytes_old = self._glyph_bytes
            self._glyph_masks = Dict[String, _GlyphMask]()
            self._glyph_bytes = 0
            self._glyph_turnovers += 1
        self._glyph_masks[key] = entry^
        self._glyph_bytes += cost

    def _store_glyph_mask(mut self, key: String, var entry: _GlyphMask):
        """Insert a freshly rasterized glyph.

        Bounded by `_GLYPH_MASK_BUDGET` bytes rather than by a count of
        entries: text anchored at arbitrary sub-pixel positions can
        produce a new key per call, and a mask's size varies forty-fold
        with the pixel size, so a count does not bound what is held.
        """
        var cost = self._entry_bytes(key, entry)
        self._insert_glyph_mask(key, entry^, cost)

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
        self._scan_if_needed()
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
        self._scan_if_needed()
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
        """`resolve` plus `_face_for_path` in one call. draw_text
        calls it twice per invocation, so with a shared `cache` the
        second is a hit.

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

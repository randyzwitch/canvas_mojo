"""Font discovery: resolves a family/slant/weight request to a font file
path on disk, with no linked library. One of the three parts of text
rendering, alongside glyph resolution and metrics (`ttf.mojo`) and
rasterization (`fill_path_aa`, see `path.mojo`).

Four steps, matching what `libfontconfig` does for a drawing library:

1. **Enumerate.** Walk each platform's font directories
   (`_font_directories`), collect every `sfnt` container
   (`.ttf`/`.ttc`/`.otf`/`.otc`), and read each one's identity from its
   `name`/`OS/2`/`head`/`post` tables (`_parse_face`). No XML; the font
   files are the database. The result is written to a cache file (see
   below), since it is the same on every run until a font is installed
   or removed.
2. **Expand generic families.** "sans-serif"/"serif"/"monospace" and the
   metric aliases (Helvetica, Arial, Times, Courier) are ordered
   preference lists, not real families (`_family_candidates`) -- the job
   fontconfig's `/etc/fonts/conf.d/*.conf` rules do.
3. **Score, don't filter.** Every installed face is ranked and the best
   wins, so a request resolves as long as one font is installed
   (`_score`). Terms run in fontconfig's priority order (`FcCompare*`):
   family, spacing, slant, weight, width.
4. **Fall back per character.** `resolve_font_file_for_char` ranks a
   font that maps the codepoint above every other term, reading
   candidate `cmap` tables in score order (`_face_covers_codepoint`) --
   fontconfig's `FC_CHARSET` constraint.

Not covered: fontconfig's XML rule engine, per-language coverage
matching, and named-instance expansion of variable fonts (a variable
font matches as its default instance).

Where it looks: on Linux `~/.local/share/fonts` and `~/.fonts` plus
`/usr/share/fonts`, `/usr/local/share/fonts` and `/usr/share/X11/fonts`;
on macOS `~/Library/Fonts`, `/Library/Fonts`, `/System/Library/Fonts`
(and its `Supplemental`) plus Homebrew's font prefixes.
**`CANVAS_MOJO_FONT_PATH`** (colon-separated directories) is searched
ahead of those. Fonts have to be installed for text to render; this
package bundles none.

A scan costs a few milliseconds, most of it the directory walk, and
its result is a pure function of which font files are installed -- the
same table on every run of every program. `FontDatabase()` therefore
reads it from a cache file when one is valid and writes one when it
scans (`_cache_path`, `_read_cache`, `_write_cache`), which takes a
first text call from tens of milliseconds to about one. The cache is
an accelerator and never a source of truth: unreadable, stale, corrupt
or unwritable, the scan runs exactly as it would have.

**Invalidation.** The cache records `_CACHE_FORMAT`, the font
directories searched, and the modification time of every directory the
walk visited. Installing or removing a font changes its directory's
mtime, so the next call rebuilds rather than silently missing the new
font -- the failure mode a version-keyed-only cache (matplotlib's
`fontlist-vXXX.json`) is famous for.

**`CANVAS_MOJO_FONT_CACHE`** overrides where the file lives, and the
value `off` disables the cache so every call scans -- what the tests
and anything debugging discovery want. Otherwise it is
`$XDG_CACHE_HOME/canvas_mojo/fonts.txt`, or `~/.cache/canvas_mojo/`
when that is unset.

Matching against an already-built `FontDatabase` is arithmetic over a
list, so build one `FontDatabase` (or `FontCache`) and reuse it rather
than resolving per call.

This module imports nothing from `canvas.text`, which is why
`FontSlant`/`FontWeight` and the small binary readers below live here:
Mojo resolves a struct's method surface, and whatever it imports,
eagerly. It is also why `_face_covers_codepoint` walks a `cmap` here --
it answers "is this codepoint mapped" from a byte range read off disk,
where `TTFFace` needs the whole parsed file.

This module resolves a font *file* and nothing more: no outline parsing,
measuring, hinting or rasterizing.
"""

from std.os import getenv, listdir, makedirs, stat
from std.runtime.asyncrt import TaskGroup, parallelism_level
from std.os.path import expanduser, isdir, realpath
from std.sys.info import CompilationTarget

comptime _FONT_PATH_ENV_VAR = "CANVAS_MOJO_FONT_PATH"
comptime _FONT_CACHE_ENV_VAR = "CANVAS_MOJO_FONT_CACHE"

# The cache file's format version, and the guard against a stale table
# after this module changes. Bump it in the same commit whenever the
# record layout changes OR `_parse_face` starts reading a field
# differently -- an older file then fails to validate and is rewritten.
# It stands in for the package version, which cannot be read at runtime
# from an installed package (there is no pixi.toml beside a
# `.mojopkg`), and keying on the package version would also discard a
# still-valid table on every release.
comptime _CACHE_FORMAT = 1
# Written as the last line, so a file cut short by a crash or by two
# processes writing at once is recognized and discarded. Mojo's stdlib
# has no `rename`, so the write cannot be made atomic by the usual
# temp-file-and-rename; this is what stands in for it.
comptime _CACHE_END_MARKER = "# end"
"""Colon-separated extra font directories, searched before the platform
defaults. The escape hatch for a font tree in a nonstandard prefix --
a container image, a test fixture, a vendored font shipped beside an
application -- for when the platform defaults in `_font_directories`
don't cover a machine.
"""


struct FontSlant(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """A font's upright/italic/oblique style. Defined here to keep this
    module independent of `canvas.text`; `render.mojo` re-exports
    it.
    """

    var _value: Int

    comptime NORMAL = Self(0)
    comptime ITALIC = Self(1)
    comptime OBLIQUE = Self(2)

    def __init__(out self, value: Int):
        """Prefer the `NORMAL`/`ITALIC`/`OBLIQUE` comptime constants
        over constructing one directly.

        Args:
            value: 0 for NORMAL, 1 for ITALIC, 2 for OBLIQUE.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def write_to[W: Writer](self, mut writer: W):
        if self._value == Self.NORMAL._value:
            writer.write("NORMAL")
        elif self._value == Self.ITALIC._value:
            writer.write("ITALIC")
        elif self._value == Self.OBLIQUE._value:
            writer.write("OBLIQUE")
        else:
            writer.write("FontSlant(", self._value, ")")

    def __str__(self) -> String:
        var out = String()
        out.write(self)
        return out


struct FontWeight(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """A font's normal/bold weight, defined here for the same reason
    FontSlant is.
    """

    var _value: Int

    comptime NORMAL = Self(0)
    comptime BOLD = Self(1)

    def __init__(out self, value: Int):
        """Prefer the `NORMAL`/`BOLD` comptime constants over
        constructing one directly.

        Args:
            value: 0 for NORMAL, 1 for BOLD.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def write_to[W: Writer](self, mut writer: W):
        if self._value == Self.NORMAL._value:
            writer.write("NORMAL")
        elif self._value == Self.BOLD._value:
            writer.write("BOLD")
        else:
            writer.write("FontWeight(", self._value, ")")

    def __str__(self) -> String:
        var out = String()
        out.write(self)
        return out


# The two axes a request and a face are compared on, both on the scales
# the font files themselves use: OpenType's `usWeightClass` (100..1000,
# 400 Regular, 700 Bold) and fontconfig's own slant numbering, which
# `OS/2`'s fsSelection bits get mapped onto.
comptime _SLANT_ROMAN = 0
comptime _SLANT_ITALIC = 100
comptime _SLANT_OBLIQUE = 110

comptime _WEIGHT_REGULAR = 400
comptime _WEIGHT_BOLD = 700


def _requested_slant(slant: FontSlant) -> Int:
    if slant == FontSlant.ITALIC:
        return _SLANT_ITALIC
    if slant == FontSlant.OBLIQUE:
        return _SLANT_OBLIQUE
    return _SLANT_ROMAN


def _requested_weight(weight: FontWeight) -> Int:
    if weight == FontWeight.BOLD:
        return _WEIGHT_BOLD
    return _WEIGHT_REGULAR


# --- Binary readers -------------------------------------------------------
# Big-endian, bounds-checked, over a `List[UInt8]` holding one table (or
# one table directory) read off disk. Same shape as `ttf.mojo`'s, kept
# local for the module-independence reason the docstring gives.


def _u8(data: List[UInt8], pos: Int) raises -> Int:
    if pos < 0 or pos >= len(data):
        raise Error("font_discovery: read past end of table")
    return Int(data[pos])


def _u16(data: List[UInt8], pos: Int) raises -> Int:
    if pos < 0 or pos + 2 > len(data):
        raise Error("font_discovery: read past end of table")
    return (Int(data[pos]) << 8) | Int(data[pos + 1])


def _i16(data: List[UInt8], pos: Int) raises -> Int:
    var v = _u16(data, pos)
    if v >= 32768:
        return v - 65536
    return v


def _u32(data: List[UInt8], pos: Int) raises -> Int:
    if pos < 0 or pos + 4 > len(data):
        raise Error("font_discovery: read past end of table")
    return (
        (Int(data[pos]) << 24)
        | (Int(data[pos + 1]) << 16)
        | (Int(data[pos + 2]) << 8)
        | Int(data[pos + 3])
    )


def _tag_at(data: List[UInt8], pos: Int) raises -> String:
    var s = String()
    for i in range(4):
        s += chr(_u8(data, pos + i))
    return s


def _read_at(mut f: FileHandle, offset: Int, length: Int) raises -> List[UInt8]:
    """`length` bytes starting at `offset`. A short read at end-of-file
    is not an error here -- the bounds checks above turn any resulting
    truncation into a raise at the field that actually needed the
    missing bytes.
    """
    if length <= 0:
        return List[UInt8]()
    _ = f.seek(offset)
    return f.read_bytes(length)


# --- Family-name normalization --------------------------------------------


def _normalize_family(name: String) -> String:
    """Case- and blank-insensitive family key, fontconfig's own
    `FcStrCmpIgnoreBlanksAndCase` comparison reduced to a normal form:
    "DejaVu Sans", "dejavu sans" and "DejaVuSans" all collide, while
    "DejaVu Sans Mono" stays distinct.

    Walks codepoints, not bytes. Both sides of a comparison go through
    this same function, so a byte walk would still match correctly --
    it would just mangle every non-ASCII family name into mojibake
    along the way ("Grotesk" with an o-slash coming back as two Latin-1
    characters), which is a trap for anything that later reads a key
    rather than only comparing two.
    """
    var out = String()
    for codepoint in name.lower().codepoints():
        var value = Int(codepoint.to_u32())
        if value != ord(" ") and value != ord("\t"):
            out += String(codepoint)
    return out^


# --- Installed-face record ------------------------------------------------


@fieldwise_init
struct FontFace(Copyable, Movable):
    """One installed face: where its file is, what it calls itself, and
    the handful of style axes matching compares. Everything here comes
    out of the font's own tables; nothing is inferred from the filename.
    """

    var path: String
    """Absolute, symlink-resolved path to the font file."""

    var names: List[String]
    """Every normalized name this face answers to -- typographic family
    (`name` ID 16), legacy family (ID 1), full name (ID 4) and
    PostScript name (ID 6), deduplicated. A request matches the face if
    it equals any of them, which is how "DejaVu Sans" and
    "DejaVuSans-Bold" both find the same file.
    """

    var weight: Int
    """`OS/2` usWeightClass, 100..1000."""

    var slant: Int
    """`_SLANT_ROMAN`/`_SLANT_ITALIC`/`_SLANT_OBLIQUE`."""

    var width: Int
    """`OS/2` usWidthClass, 1..9, 5 being normal width. Only a tie-break,
    but the one that keeps "Nimbus Sans Narrow" from outranking "Nimbus
    Sans" for a plain request.
    """

    var monospace: Bool
    """`post`'s isFixedPitch, or PANOSE bProportion == 9."""

    var renderable: Bool
    """Whether `ttf.mojo` can actually parse this file: `glyf` or `CFF `
    outlines or `CBDT` color bitmaps, and not a collection container it
    reads no face index from. False for every face in a `.ttc`.
    Ranked below every real matching term -- an exact family match wins
    even when the answer is a font this library will then refuse, which
    is a clear error rather than a silently different font.
    """

    var cmap_offset: Int
    """Absolute file offset of this face's `cmap` table, -1 if it has
    none. Read lazily, only when a codepoint constraint is in play.
    """

    var cmap_length: Int


# --- Scanning the font directories ----------------------------------------


def _append_unique(mut items: List[String], value: String):
    var trimmed = String(value.strip())
    if trimmed.byte_length() == 0:
        return
    if trimmed not in items:
        items.append(trimmed)


def _append_home_relative(mut items: List[String], relative: String):
    try:
        _append_unique(items, String(expanduser(String("~/", relative))))
    except:
        pass


def _font_directories() -> List[String]:
    """Where each platform keeps installed fonts, most specific first:
    the env-var override, then the user's own font directories, then the
    system-wide ones. Listed rather than discovered, the same fixed set
    fontconfig's shipped `fonts.conf` hard-codes.
    """
    var dirs = List[String]()

    for entry in getenv(_FONT_PATH_ENV_VAR).split(":"):
        _append_unique(dirs, String(entry))

    if CompilationTarget.is_macos():
        _append_home_relative(dirs, "Library/Fonts")
        _append_unique(dirs, "/Library/Fonts")
        _append_unique(dirs, "/System/Library/Fonts")
        _append_unique(dirs, "/System/Library/Fonts/Supplemental")
        _append_unique(dirs, "/Network/Library/Fonts")
        # Homebrew's two prefixes (Apple silicon, then Intel), where
        # `brew install --cask font-*` puts its font files.
        _append_unique(dirs, "/opt/homebrew/share/fonts")
        _append_unique(dirs, "/usr/local/share/fonts")
    else:
        var xdg_data_home = String(getenv("XDG_DATA_HOME").strip())
        if xdg_data_home.byte_length() > 0:
            _append_unique(dirs, String(xdg_data_home, "/fonts"))
        _append_home_relative(dirs, ".local/share/fonts")
        _append_home_relative(dirs, ".fonts")
        _append_unique(dirs, "/usr/share/fonts")
        _append_unique(dirs, "/usr/local/share/fonts")
        _append_unique(dirs, "/usr/share/X11/fonts")
        # Flatpak exposes the host's fonts here.
        _append_unique(dirs, "/run/host/fonts")

    return dirs^


def _has_sfnt_extension(name: String) -> Bool:
    """The container formats `_parse_face` can read. Excludes the
    bitmap and Type 1 formats a Linux font tree is also full of
    (`.pcf.gz`, `.pfb`, `.afm`): they carry no `sfnt` tables to read an
    identity out of, and `ttf.mojo` cannot draw them.
    """
    var lowered = name.lower()
    return (
        lowered.endswith(".ttf")
        or lowered.endswith(".ttc")
        or lowered.endswith(".otf")
        or lowered.endswith(".otc")
    )


def _listdir_or_empty(directory: String) -> List[String]:
    try:
        return listdir(directory)
    except:
        # A directory in the platform list that this machine simply
        # doesn't have, or one this process can't read. Neither is an
        # error: the list is every place fonts *might* live.
        return List[String]()


comptime _MAX_SCAN_DEPTH = 8
"""How deep under a font directory to recurse. Real font trees are two
or three levels (`/usr/share/fonts/truetype/dejavu/`); the cap is what
keeps a symlink cycle from turning the walk into an infinite one.
"""


comptime _ENTRY_OTHER = 0
comptime _ENTRY_DIRECTORY = 1
comptime _ENTRY_FONT = 2


def _classify_entries(
    children: List[String],
    font_named: List[Bool],
    mut kind: List[Int],
    mut canonical: List[String],
    first: Int,
    last: Int,
):
    """Entries [first, last) of a directory level: a font by extension
    is resolved through `realpath` (a directory named `*.ttf` would be
    misfiled here and then dropped by `_parse_font_file`, which cannot
    open it); anything else is a subdirectory or not."""
    for i in range(first, last):
        if font_named[i]:
            var resolved = children[i]
            try:
                resolved = String(realpath(children[i]))
            except:
                pass
            canonical[i] = resolved
            kind[i] = _ENTRY_FONT
        elif isdir(children[i]):
            kind[i] = _ENTRY_DIRECTORY


async def _classify_entries_async(
    children: List[String],
    font_named: List[Bool],
    mut kind: List[Int],
    mut canonical: List[String],
    first: Int,
    last: Int,
):
    """`_classify_entries` as a task; bands write disjoint slots."""
    _classify_entries(children, font_named, kind, canonical, first, last)


def _collect_font_files() -> List[String]:
    """Every readable `sfnt` file under `_font_directories`, discarding
    the visited-directory list `_collect_font_files_visited` also
    returns."""
    var visited = List[String]()
    return _collect_font_files_visited(visited)


def _collect_font_files_visited(mut visited: List[String]) -> List[String]:
    """Every readable `sfnt` file under `_font_directories`, resolved
    through symlinks and deduplicated.

    A distro package like `fonts-ubuntu` ships `Ubuntu-B.ttf`,
    `Ubuntu-R.ttf` and half a dozen more as links onto one variable
    `Ubuntu[wdth,wght].ttf`. Without resolving them each enters the
    database as a separate face with identical properties, and which file
    a request resolves to comes down to directory order.

    The list is sorted because `listdir` returns filesystem order, so two
    equally-good faces would otherwise tie-break differently on different
    machines.
    """
    var files = List[String]()
    var seen = Dict[String, Bool]()
    var frontier = _font_directories()
    for directory in frontier:
        visited.append(directory)
    var depth = 0
    # Level by level: every directory of the level is listed, then
    # each entry is classified -- a stat to tell a subdirectory from
    # a stray file, `realpath` on a font -- in bands across cores,
    # since those two calls are the whole cost of the walk and each
    # entry's is independent. The tasks borrow the entry lists and
    # write their own slots of `kind` and `canonical` (#97, #263).
    while len(frontier) > 0 and depth <= _MAX_SCAN_DEPTH:
        var children = List[String]()
        var font_named = List[Bool]()
        for directory in frontier:
            var entries = _listdir_or_empty(directory)
            sort(entries)
            for entry in entries:
                children.append(String(directory, "/", entry))
                font_named.append(_has_sfnt_extension(entry))
        var count = len(children)
        var kind = List[Int](length=count, fill=0)
        var canonical = List[String](length=count, fill="")
        var bands = parallelism_level()
        if bands > count:
            bands = count
        if bands <= 1:
            _classify_entries(children, font_named, kind, canonical, 0, count)
        else:
            var per_band = (count + bands - 1) // bands
            var tg = TaskGroup()
            for b in range(bands):
                var first = b * per_band
                var last = min(first + per_band, count)
                if first >= last:
                    continue
                tg.create_task(
                    _classify_entries_async(
                        children, font_named, kind, canonical, first, last
                    )
                )
            tg.wait()
            _ = len(children) + len(font_named) + len(kind) + len(canonical)
        var next_frontier = List[String]()
        for i in range(count):
            if kind[i] == _ENTRY_DIRECTORY:
                next_frontier.append(children[i])
                visited.append(children[i])
            elif kind[i] == _ENTRY_FONT:
                if canonical[i] in seen:
                    continue
                seen[canonical[i]] = True
                files.append(canonical[i])
        frontier = next_frontier^
        depth += 1
    sort(files)
    return files^


# --- Reading one face's identity ------------------------------------------


def _name_rank(platform_id: Int, encoding_id: Int, language_id: Int) -> Int:
    """Which `name` record to believe when a face spells one name
    several ways. Windows/Unicode-BMP/US-English is the record every
    real font has and every text stack reads; the rest are ordered
    behind it as fallbacks rather than excluded, since a font with only
    a Macintosh record still has a usable name.
    """
    if platform_id == 3 and encoding_id == 1 and language_id == 0x0409:
        return 0
    if platform_id == 3:
        return 1
    if platform_id == 0:
        return 2
    if platform_id == 1 and language_id == 0:
        return 3
    return 4


def _decode_name(
    data: List[UInt8], offset: Int, length: Int, platform_id: Int
) raises -> String:
    """One `name` record's bytes as text. Platform 1 (Macintosh) records
    are single-byte; every other platform's are UTF-16BE, including the
    surrogate pairs a font with an emoji in its name uses.
    """
    var out = String()
    if platform_id == 1:
        for i in range(length):
            var byte = _u8(data, offset + i)
            if byte != 0:
                out += chr(byte)
        return out^

    var i = 0
    while i + 2 <= length:
        var unit = _u16(data, offset + i)
        i += 2
        if unit >= 0xD800 and unit <= 0xDBFF and i + 2 <= length:
            var low = _u16(data, offset + i)
            if low >= 0xDC00 and low <= 0xDFFF:
                i += 2
                out += chr(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                continue
        if unit != 0:
            out += chr(unit)
    return out^


def _read_names(name_table: List[UInt8]) raises -> Dict[Int, String]:
    """The `name` IDs matching cares about -- 1 legacy family, 2
    subfamily, 4 full name, 6 PostScript name, 16 typographic family --
    each taken from its best-ranked record.
    """
    var out = Dict[Int, String]()
    var best = Dict[Int, Int]()
    var count = _u16(name_table, 2)
    var storage = _u16(name_table, 4)

    for i in range(count):
        var record = 6 + i * 12
        var name_id = _u16(name_table, record + 6)
        if (
            name_id != 1
            and name_id != 2
            and name_id != 4
            and name_id != 6
            and name_id != 16
        ):
            continue
        var platform_id = _u16(name_table, record)
        var encoding_id = _u16(name_table, record + 2)
        var language_id = _u16(name_table, record + 4)
        var rank = _name_rank(platform_id, encoding_id, language_id)
        if name_id in best and best[name_id] <= rank:
            continue
        var length = _u16(name_table, record + 8)
        var offset = storage + _u16(name_table, record + 10)
        var text = _decode_name(name_table, offset, length, platform_id)
        if text.byte_length() == 0:
            continue
        out[name_id] = text
        best[name_id] = rank

    return out^


def _parse_face(
    mut f: FileHandle, path: String, base: Int, in_collection: Bool
) raises -> FontFace:
    """One `sfnt` face, starting at table directory offset `base` (0 for
    a plain font file, a `ttcf` header entry for a face in a
    collection).
    """
    var directory_header = _read_at(f, base, 12)
    var num_tables = _u16(directory_header, 4)
    if num_tables == 0 or num_tables > 512:
        raise Error("font_discovery: implausible numTables")
    var table_directory = _read_at(f, base + 12, num_tables * 16)

    var name_offset = -1
    var name_length = 0
    var os2_offset = -1
    var head_offset = -1
    var post_offset = -1
    var cmap_offset = -1
    var cmap_length = 0
    var has_glyf = False
    var has_cff = False
    var has_cbdt = False

    for i in range(num_tables):
        var record = i * 16
        var tag = _tag_at(table_directory, record)
        var offset = _u32(table_directory, record + 8)
        var length = _u32(table_directory, record + 12)
        if tag == "name":
            name_offset = offset
            name_length = length
        elif tag == "OS/2":
            os2_offset = offset
        elif tag == "head":
            head_offset = offset
        elif tag == "post":
            post_offset = offset
        elif tag == "cmap":
            cmap_offset = offset
            cmap_length = length
        elif tag == "glyf":
            has_glyf = True
        elif tag == "CFF ":
            has_cff = True
        elif tag == "CBDT":
            has_cbdt = True

    if name_offset < 0 or name_length < 6:
        raise Error("font_discovery: face has no usable name table")
    var names = _read_names(_read_at(f, name_offset, name_length))

    var subfamily = String()
    if 2 in names:
        subfamily = names[2].lower()

    # `head`'s macStyle is the fallback for a face with no `OS/2` table
    # at all -- rare, but legal, and the only weight/slant signal such a
    # font carries.
    var mac_style = 0
    if head_offset >= 0:
        var head = _read_at(f, head_offset, 54)
        mac_style = _u16(head, 44)

    var weight = _WEIGHT_REGULAR
    var width = 5
    var fs_selection = 0
    var panose_proportion = 0
    if os2_offset >= 0:
        var os2 = _read_at(f, os2_offset, 78)
        weight = _u16(os2, 4)
        width = _u16(os2, 6)
        # PANOSE lives at OS/2 + 32; bProportion is its 4th digit.
        panose_proportion = _u8(os2, 35)
        fs_selection = _u16(os2, 62)
        # Fonts predating usWeightClass's 100..1000 range wrote 1..9.
        if weight >= 1 and weight <= 9:
            weight *= 100
        if weight < 1 or weight > 1000:
            weight = _WEIGHT_REGULAR
        if width < 1 or width > 9:
            width = 5
    elif (mac_style & 0x0001) != 0:
        weight = _WEIGHT_BOLD

    # fsSelection's OBLIQUE bit (9) is newer than its ITALIC bit (0) and
    # plenty of oblique faces set only the latter, so the subfamily name
    # breaks the tie -- DejaVu Sans Mono Oblique is exactly that font.
    var slant = _SLANT_ROMAN
    var italic = (fs_selection & 0x0001) != 0 or (mac_style & 0x0002) != 0
    if (fs_selection & 0x0200) != 0 or "oblique" in subfamily:
        slant = _SLANT_OBLIQUE
    elif italic or "italic" in subfamily:
        slant = _SLANT_ITALIC

    var monospace = panose_proportion == 9
    if post_offset >= 0 and not monospace:
        var post = _read_at(f, post_offset, 16)
        monospace = _u32(post, 12) != 0

    var keys = List[String]()
    for name_id in [16, 1, 4, 6]:
        if name_id in names:
            _append_unique(keys, _normalize_family(names[name_id]))
    if len(keys) == 0:
        raise Error("font_discovery: face has no family name")

    return FontFace(
        path,
        keys^,
        weight,
        slant,
        width,
        monospace,
        (has_glyf or has_cff or has_cbdt) and not in_collection,
        cmap_offset,
        cmap_length,
    )


def _parse_font_file(path: String) -> List[FontFace]:
    """Every face in one font file: one for a plain `.ttf`/`.otf`, one
    per entry for a `.ttc`/`.otc` collection.

    A file that can't be read or parsed is skipped, not raised on. A
    font directory is shared, mutable system state -- a truncated
    download, a format this parser doesn't read, a file the process
    can't open -- and one bad file there must not take down every
    lookup on the machine.
    """
    var faces = List[FontFace]()
    try:
        var f = open(path, "r")
        var header = _read_at(f, 0, 12)
        var in_collection = _tag_at(header, 0) == "ttcf"

        var bases = List[Int]()
        if in_collection:
            var num_fonts = _u32(header, 8)
            if num_fonts > 256:
                num_fonts = 256
            var offsets = _read_at(f, 12, num_fonts * 4)
            for i in range(num_fonts):
                bases.append(_u32(offsets, i * 4))
        else:
            bases.append(0)

        for base in bases:
            try:
                faces.append(_parse_face(f, path, base, in_collection))
            except:
                pass
        f.close()
    except:
        pass
    return faces^


def _parse_files(
    files: List[String],
    mut results: List[List[FontFace]],
    first: Int,
    last: Int,
):
    """`_parse_font_file` for files [first, last), each into its slot
    of `results`."""
    for i in range(first, last):
        results[i] = _parse_font_file(files[i])


async def _parse_files_async(
    files: List[String],
    mut results: List[List[FontFace]],
    first: Int,
    last: Int,
):
    """`_parse_files` as a task; bands write disjoint slots."""
    _parse_files(files, results, first, last)


# --- Codepoint coverage ---------------------------------------------------


def _face_covers_codepoint(face: FontFace, codepoint: Int) -> Bool:
    """Whether `face` maps `codepoint` to a real glyph, read straight
    out of its `cmap` table.

    Subtable selection matches `ttf.mojo`'s -- format 12 (full Unicode)
    over format 4 (BMP-only) over nothing -- so a face this says covers
    a character is one `TTFFace.glyph_index_for_codepoint` will then
    find the glyph in. Unreadable or exotic `cmap`s answer False, which
    costs at worst a fallback that skips a font it could have used.
    """
    if face.cmap_offset < 0 or face.cmap_length < 4:
        return False
    var cmap: List[UInt8]
    try:
        var f = open(face.path, "r")
        cmap = _read_at(f, face.cmap_offset, face.cmap_length)
        f.close()
    except:
        return False

    try:
        var num_tables = _u16(cmap, 2)
        var best_offset = -1
        var best_format = -1
        for i in range(num_tables):
            var record = 4 + i * 8
            var platform_id = _u16(cmap, record)
            var encoding_id = _u16(cmap, record + 2)
            # Subtable offsets are relative to the start of `cmap`,
            # which is exactly where this byte range begins.
            var subtable = _u32(cmap, record + 4)
            var format = _u16(cmap, subtable)
            var is_unicode = platform_id == 0 or (
                platform_id == 3 and (encoding_id == 1 or encoding_id == 10)
            )
            if not is_unicode:
                continue
            if format == 12 and best_format != 12:
                best_offset = subtable
                best_format = 12
            elif format == 4 and best_format != 12 and best_format != 4:
                best_offset = subtable
                best_format = 4

        if best_offset < 0:
            return False
        if best_format == 12:
            return _covers_format12(cmap, best_offset, codepoint)
        return _covers_format4(cmap, best_offset, codepoint)
    except:
        return False


def _covers_format4(
    cmap: List[UInt8], subtable: Int, codepoint: Int
) raises -> Bool:
    if codepoint > 0xFFFF:
        return False  # format 4 is BMP-only by definition
    var seg_count = _u16(cmap, subtable + 6) // 2
    var end_codes = subtable + 14
    var start_codes = end_codes + seg_count * 2 + 2  # +2 skips reservedPad
    var id_deltas = start_codes + seg_count * 2
    var id_range_offsets = id_deltas + seg_count * 2

    for i in range(seg_count):
        if codepoint > _u16(cmap, end_codes + i * 2):
            continue
        if codepoint < _u16(cmap, start_codes + i * 2):
            return False
        var range_offset = _u16(cmap, id_range_offsets + i * 2)
        if range_offset == 0:
            var delta = _i16(cmap, id_deltas + i * 2)
            return (codepoint + delta) % 65536 != 0
        # The spec's own glyphIdArray indexing trick, the same one
        # `ttf.mojo` transcribes.
        var start_code = _u16(cmap, start_codes + i * 2)
        var address = (
            id_range_offsets
            + i * 2
            + range_offset
            + (codepoint - start_code) * 2
        )
        return _u16(cmap, address) != 0
    return False


def _covers_format12(
    cmap: List[UInt8], subtable: Int, codepoint: Int
) raises -> Bool:
    var num_groups = _u32(cmap, subtable + 12)
    for i in range(num_groups):
        var group = subtable + 16 + i * 12
        if codepoint < _u32(cmap, group):
            return False  # groups are sorted by startCharCode
        if codepoint <= _u32(cmap, group + 4):
            return _u32(cmap, group + 8) + (codepoint - _u32(cmap, group)) != 0
    return False


# --- Generic families and metric aliases ----------------------------------
# The job fontconfig's `/etc/fonts/conf.d/*.conf` XML rules do, as
# ordered lists. Each list is "what a browser would pick, best first":
# the free families a Linux install actually ships ahead of the
# proprietary ones a macOS or Windows box has instead, so the same
# request resolves to the same look wherever a given font exists.


def _sans_serif_families() -> List[String]:
    return [
        "DejaVu Sans",
        "Liberation Sans",
        "Arimo",
        "Nimbus Sans",
        "Helvetica",
        "Arial",
        "Noto Sans",
        "Ubuntu",
        "Cantarell",
        "Roboto",
        "Open Sans",
        "Segoe UI",
        "Verdana",
        "Tahoma",
        "Bitstream Vera Sans",
        "FreeSans",
    ]


def _serif_families() -> List[String]:
    return [
        "DejaVu Serif",
        "Liberation Serif",
        "Tinos",
        "Nimbus Roman",
        "Times New Roman",
        "Times",
        "Noto Serif",
        "Georgia",
        "Bitstream Vera Serif",
        "FreeSerif",
    ]


def _monospace_families() -> List[String]:
    return [
        "DejaVu Sans Mono",
        "Liberation Mono",
        "Cousine",
        "Nimbus Mono PS",
        "Courier New",
        "Courier",
        "Noto Sans Mono",
        "Ubuntu Mono",
        "Menlo",
        "Consolas",
        "Bitstream Vera Sans Mono",
        "FreeMono",
    ]


def _generic_expansion(key: String) -> List[String]:
    """The preference list a generic family name stands for, or an empty
    list if `key` names a real family. Both the CSS spellings
    ("sans-serif") and fontconfig's own ("sans") are accepted, since
    `render.mojo` defaults to "Sans" and `svg.mojo` writes
    "sans-serif".
    """
    if key == "sans" or key == "sans-serif" or key == "sansserif":
        return _sans_serif_families()
    if key == "serif":
        return _serif_families()
    if key == "mono" or key == "monospace":
        return _monospace_families()
    # "system-ui", "ui-sans-serif" and CSS's decorative generics have no
    # better answer here than the default sans list; "cursive" and
    # "fantasy" would need families this scan can't count on finding.
    if (
        key == "system-ui"
        or key == "ui-sans-serif"
        or key == "cursive"
        or key == "fantasy"
    ):
        return _sans_serif_families()
    return List[String]()


def _metric_aliases(key: String) -> List[String]:
    """Substitutes for the handful of families whose *metrics* other
    families clone, so a document asking for one lays out the same under
    another. fontconfig ships this as
    `30-metric-aliases.conf`; these are the entries that matter for
    text a chart draws.
    """
    if key == "helvetica" or key == "arial":
        return ["Liberation Sans", "Arimo", "Nimbus Sans", "Helvetica", "Arial"]
    if key == "times" or key == "timesnewroman":
        return [
            "Liberation Serif",
            "Tinos",
            "Nimbus Roman",
            "Times New Roman",
        ]
    if key == "courier" or key == "couriernew":
        return [
            "Liberation Mono",
            "Cousine",
            "Nimbus Mono PS",
            "Courier New",
        ]
    return List[String]()


def _family_candidates(family: String) -> List[String]:
    """The requested family expanded into an ordered preference list of
    normalized family keys, best first.

    The default sans list is appended to every request, which is what
    makes an unknown family resolve to a real font instead of raising --
    fontconfig's `<default><family>sans-serif</family></default>` rule,
    and the reason a typo in a family name renders in the default font
    rather than failing.
    """
    var key = _normalize_family(family)
    var candidates = List[String]()

    var generic = _generic_expansion(key)
    if len(generic) > 0:
        for name in generic:
            _append_unique(candidates, _normalize_family(name))
    else:
        _append_unique(candidates, key)
        for name in _metric_aliases(key):
            _append_unique(candidates, _normalize_family(name))

    for name in _sans_serif_families():
        _append_unique(candidates, _normalize_family(name))

    return candidates^


# --- Scoring --------------------------------------------------------------
# One comparison key packed into an Int, as the digits of a mixed-radix
# number: each term's multiplier is the product of every less
# significant term's radix, so comparing two packed keys with `<` is
# exactly a lexicographic comparison of the terms, most significant
# first. The order is fontconfig's own `FcCompare*` priority -- family
# dominates everything, and no number of style points can promote the
# wrong family.


comptime _RADIX_RENDERABLE = 2
comptime _RADIX_WIDTH = 10
comptime _RADIX_WEIGHT = 1000
comptime _RADIX_SLANT = 4
comptime _RADIX_SPACING = 2

comptime _TERM_RENDERABLE = 1
comptime _TERM_WIDTH = _TERM_RENDERABLE * _RADIX_RENDERABLE
comptime _TERM_WEIGHT = _TERM_WIDTH * _RADIX_WIDTH
comptime _TERM_SLANT = _TERM_WEIGHT * _RADIX_WEIGHT
comptime _TERM_SPACING = _TERM_SLANT * _RADIX_SLANT
comptime _TERM_FAMILY = _TERM_SPACING * _RADIX_SPACING


def _slant_penalty(requested: Int, actual: Int) -> Int:
    """Italic and oblique are near-substitutes for each other; an
    upright face standing in for a slanted request is worse than the
    reverse, since the reverse at least keeps the requested weight of
    the page.
    """
    if requested == actual:
        return 0
    if requested != _SLANT_ROMAN and actual != _SLANT_ROMAN:
        return 1  # italic asked, oblique found, or the other way round
    if requested == _SLANT_ROMAN:
        return 2
    return 3


def _score(
    face: FontFace,
    candidates: List[String],
    requested_slant: Int,
    requested_weight: Int,
    want_monospace: Bool,
) -> Int:
    var family_rank = len(candidates)
    for i in range(len(candidates)):
        if candidates[i] in face.names:
            family_rank = i
            break

    var spacing_penalty = 0
    if want_monospace and not face.monospace:
        spacing_penalty = 1

    var weight_penalty = abs(face.weight - requested_weight)
    if weight_penalty >= _RADIX_WEIGHT:
        weight_penalty = _RADIX_WEIGHT - 1

    var renderable_penalty = 0 if face.renderable else 1

    return (
        family_rank * _TERM_FAMILY
        + spacing_penalty * _TERM_SPACING
        + _slant_penalty(requested_slant, face.slant) * _TERM_SLANT
        + weight_penalty * _TERM_WEIGHT
        + abs(face.width - 5) * _TERM_WIDTH
        + renderable_penalty * _TERM_RENDERABLE
    )


# --- The database ---------------------------------------------------------


# --- The cache file -------------------------------------------------------


def _cache_path() -> String:
    """Where the cache file lives: `CANVAS_MOJO_FONT_CACHE` if set,
    `$XDG_CACHE_HOME/canvas_mojo/fonts.txt` if that is set, else
    `~/.cache/canvas_mojo/fonts.txt`. The value `off` disables the
    cache, as does a home directory that cannot be resolved; both come
    back as "" and every caller reads that as "scan, do not cache".

    `off` rather than an empty value because a variable set to nothing
    and one never set are the same string through `getenv`, and the
    difference would have to be recovered from `/proc/self/environ`,
    which does not exist on macOS and does not see a `setenv` made by
    the running process.
    """
    var override = String(getenv(_FONT_CACHE_ENV_VAR).strip())
    if override == "off":
        return String("")
    if override.byte_length() > 0:
        return override
    var xdg = String(getenv("XDG_CACHE_HOME").strip())
    if xdg.byte_length() > 0:
        return String(xdg, "/canvas_mojo/fonts.txt")
    try:
        return String(expanduser("~/.cache/canvas_mojo/fonts.txt"))
    except:
        return String("")


def _directory_mtime(path: String) -> Int:
    """`path`'s modification time in nanoseconds, or -1 if it cannot be
    read (the directory does not exist, or is not readable). A
    directory that is absent on this machine keys as -1 and stays
    valid as long as it stays absent.
    """
    try:
        var spec = stat(path).st_mtimespec
        return Int(spec.tv_sec) * 1_000_000_000 + Int(spec.tv_subsec)
    except:
        return -1


def _search_key(directories: List[String]) -> String:
    """The part of the key known without walking: the format version
    and the directories that would be searched. A font directory that
    appears or disappears (a new `XDG_DATA_HOME`, a Homebrew prefix
    created) changes this.
    """
    var key = String("v", _CACHE_FORMAT, " dirs=")
    for directory in directories:
        key += directory + ","
    return key


def _mtimes_line(visited: List[String]) -> String:
    """Every directory the walk visited with its modification time, as
    the cache file's `# mtimes` line. Installing or removing a font
    changes the mtime of the directory holding it; creating or deleting
    a subdirectory changes its parent's. Checking these is what lets a
    valid cache skip the walk entirely, which is most of what the scan
    costs.
    """
    var out = String()
    for directory in visited:
        out += (
            _escape_field(directory)
            + ":"
            + String(_directory_mtime(directory))
            + "\t"
        )
    return out


def _mtimes_match(line: String) raises -> Bool:
    """Whether every directory recorded in a `# mtimes` line still has
    the modification time recorded for it. A directory that has since
    disappeared reads as -1, which is what `_directory_mtime` recorded
    for one that was already absent, so those agree too.

    Raises on a malformed line, which `_read_cache` catches as "scan".

    Raises:
        Error: A recorded time is not a number.
    """
    for entry in line.split("\t"):
        var field = String(entry)
        if field.byte_length() == 0:
            continue
        var colon = field.rfind(":")
        if colon <= 0:
            return False
        var directory = _unescape_field(String(field[byte=:colon]))
        var recorded = Int(String(field[byte = colon + 1 :]))
        if _directory_mtime(directory) != recorded:
            return False
    return True


def _escape_field(text: String) -> String:
    """A field for one tab-separated record: tabs, newlines and
    backslashes escaped, so a path or a family name containing one
    survives the round trip."""
    var out = String()
    for cp in text.codepoints():
        var c = Int(cp)
        if c == 92:
            out += "\\\\"
        elif c == 9:
            out += "\\t"
        elif c == 10:
            out += "\\n"
        else:
            out += chr(c)
    return out


def _unescape_field(text: String) -> String:
    """`_escape_field` backwards."""
    var out = String()
    var bytes = text.as_bytes()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        if c == 92 and i + 1 < len(bytes):
            var n = Int(bytes[i + 1])
            if n == 92:
                out += "\\"
            elif n == 116:
                out += "\t"
            elif n == 110:
                out += "\n"
            else:
                out += chr(n)
            i += 2
            continue
        out += chr(c)
        i += 1
    return out


def _write_cache(
    path: String,
    search_key: String,
    visited: List[String],
    faces: List[FontFace],
):
    """Write `faces` to `path` under `search_key` and the modification
    times of `visited`. Silent on any failure: an unwritable or absent
    cache directory is a machine this library still has to draw on.

    The record count is in the header and `_CACHE_END_MARKER` is the
    last line, so a reader can tell a complete file from one cut short
    -- there is no `rename` in the stdlib to make the write atomic, and
    two processes racing simply both scan and the last write wins.
    """
    if path.byte_length() == 0:
        return
    try:
        var slash = path.rfind("/")
        if slash > 0:
            makedirs(String(path[byte=:slash]), exist_ok=True)
        var out = String(
            "# canvas_mojo font cache -- delete freely; it is rebuilt on"
            " demand.\n"
        )
        out += "# key\t" + search_key + "\n"
        out += "# mtimes\t" + _mtimes_line(visited) + "\n"
        out += "# count\t" + String(len(faces)) + "\n"
        for i in range(len(faces)):
            ref face = faces[i]
            out += _escape_field(face.path)
            out += "\t" + String(len(face.names))
            for name in face.names:
                out += "\t" + _escape_field(name)
            out += "\t" + String(face.weight)
            out += "\t" + String(face.slant)
            out += "\t" + String(face.width)
            out += "\t" + ("1" if face.monospace else "0")
            out += "\t" + ("1" if face.renderable else "0")
            out += "\t" + String(face.cmap_offset)
            out += "\t" + String(face.cmap_length)
            out += "\n"
        out += _CACHE_END_MARKER + "\n"
        var f = open(path, "w")
        f.write(out)
        f.close()
    except:
        pass


def _read_cache(path: String, search_key: String) -> List[FontFace]:
    """The faces `path` holds if it is a complete file recorded under
    `search_key` whose recorded directories all still carry the
    modification times it recorded, else an empty list -- which the
    caller reads as "scan". Every failure mode (missing, unreadable,
    stale, truncated, corrupt) comes back the same way.

    Validating from the file's own directory list is the point: it
    costs one `stat` per directory, tens of microseconds, against the
    milliseconds the walk it replaces would cost.
    """
    var faces = List[FontFace]()
    if path.byte_length() == 0:
        return faces^
    try:
        var f = open(path, "r")
        var text = f.read()
        f.close()
        var lines = List[String]()
        for span in text.split("\n"):
            lines.append(String(span))
        if len(lines) < 4:
            return List[FontFace]()
        var found_key = String("")
        var mtimes = String("")
        var have_mtimes = False
        var count = -1
        var first_record = 0
        for i in range(len(lines)):
            var line = lines[i]
            if line.startswith("# key\t"):
                found_key = String(line[byte=6:])
            elif line.startswith("# mtimes\t"):
                mtimes = String(line[byte=9:])
                have_mtimes = True
            elif line.startswith("# count\t"):
                count = Int(String(line[byte=8:].strip()))
            elif not line.startswith("#"):
                first_record = i
                break
        if found_key != search_key or count < 0 or not have_mtimes:
            return List[FontFace]()
        # A complete file ends with the marker; anything else was cut
        # short while being written.
        var complete = False
        for i in range(len(lines) - 1, first_record - 1, -1):
            var line = String(lines[i].strip())
            if line == "":
                continue
            complete = line == _CACHE_END_MARKER
            break
        if not complete:
            return List[FontFace]()
        if not _mtimes_match(mtimes):
            return List[FontFace]()
        for i in range(first_record, len(lines)):
            var line = lines[i]
            if line.startswith("#") or String(line.strip()) == "":
                continue
            var fields = List[String]()
            for span in line.split("\t"):
                fields.append(String(span))
            if len(fields) < 9:
                return List[FontFace]()
            var face_path = _unescape_field(fields[0])
            var name_count = Int(fields[1])
            if len(fields) != 2 + name_count + 7:
                return List[FontFace]()
            var names = List[String]()
            for k in range(name_count):
                names.append(_unescape_field(fields[2 + k]))
            var rest = 2 + name_count
            faces.append(
                FontFace(
                    face_path,
                    names^,
                    Int(fields[rest]),
                    Int(fields[rest + 1]),
                    Int(fields[rest + 2]),
                    fields[rest + 3] == "1",
                    fields[rest + 4] == "1",
                    Int(fields[rest + 5]),
                    Int(fields[rest + 6]),
                )
            )
        if len(faces) != count:
            return List[FontFace]()
        return faces^
    except:
        return List[FontFace]()


struct FontDatabase(Movable):
    """Every installed face on this machine, scanned once.

    Construct one and reuse it: building it walks the font directories
    and reads a few tables out of every font file found, which is the
    whole cost of a lookup -- matching against an already-built database
    is arithmetic over a list. `resolve_font_file` builds a throwaway
    one per call, so a caller resolving more than a handful of fonts
    wants a `FontCache` (which holds one of these) instead.
    """

    var faces: List[FontFace]

    def __init__(out self):
        """Scan the platform's font directories.

        Reads the cache file when it holds a table recorded for these
        directories at these modification times, and writes one after a
        scan; see this module's docstring for the file and how to
        disable it.

        Never raises on a bad font file, an unreadable directory or an
        unusable cache -- those are skipped -- so a machine with no
        fonts installed at all yields an empty database, and it is
        `resolve` that reports that.
        """
        self.faces = List[FontFace]()
        var path = _cache_path()
        var search_key = _search_key(_font_directories())
        # Before the walk, not after: the file carries the directories
        # it was built from, so checking it is one `stat` each rather
        # than the walk those `stat`s would otherwise drive.
        var cached = _read_cache(path, search_key)
        if len(cached) > 0:
            self.faces = cached^
            return
        var visited = List[String]()
        var files = _collect_font_files_visited(visited)
        var count = len(files)
        if count == 0:
            return
        # The per-file reads are the cost -- a thousand files on a
        # desktop, each opened and read at three offsets -- and they
        # are independent, so the files are parsed in bands across
        # cores, each task writing its own slots of `results`. The
        # tasks borrow `files` and `results`, so both are named again
        # after `wait` (#263).
        var results = List[List[FontFace]]()
        for _ in range(count):
            results.append(List[FontFace]())
        var bands = parallelism_level()
        if bands > count:
            bands = count
        if bands < 1:
            bands = 1
        if bands == 1:
            _parse_files(files, results, 0, count)
        else:
            var per_band = (count + bands - 1) // bands
            var tg = TaskGroup()
            for b in range(bands):
                var first = b * per_band
                var last = min(first + per_band, count)
                if first >= last:
                    continue
                tg.create_task(_parse_files_async(files, results, first, last))
            tg.wait()
            _ = len(files) + len(results)
        for i in range(count):
            for face in results[i]:
                self.faces.append(face.copy())
        _write_cache(path, search_key, visited, self.faces)

    def __init__(out self, var faces: List[FontFace]):
        """A database over `faces` alone, with no scan of the installed
        fonts: what `FontCache` holds until its first lookup, and a way
        to build a database over known faces.

        Args:
            faces: The faces the database resolves against.
        """
        self.faces = faces^

    def resolve(
        self,
        family: String,
        slant: FontSlant = FontSlant.NORMAL,
        weight: FontWeight = FontWeight.NORMAL,
        codepoint: Int = -1,
    ) raises -> String:
        """Best-matching font file for this request.

        With `codepoint` set, a face that maps that character outranks
        every other term: candidates are ranked normally, then walked
        best-first until one covers it. If none does, the plain best
        match is returned rather than raising, so a missing glyph
        degrades to a `.notdef` box.

        Args:
            family: Font family name or generic alias (e.g.
                "sans-serif").
            slant: Requested upright/italic/oblique style.
            weight: Requested normal/bold weight.
            codepoint: Unicode codepoint the matched font should
                contain, or -1 for no constraint.

        Returns:
            The matched font's absolute file path.

        Raises:
            Error: no font files were found on this machine.
        """
        if len(self.faces) == 0:
            raise Error(
                String(
                    "no fonts found while resolving family '",
                    family,
                    "': searched this platform's font directories and ",
                    _FONT_PATH_ENV_VAR,
                    ", and found no readable .ttf/.ttc/.otf file",
                )
            )

        var key = _normalize_family(family)
        var candidates = _family_candidates(family)
        # Only the generic "monospace" request carries a spacing
        # constraint of its own; a named family says what it wants by
        # name, and its own faces already sit at the front of the list.
        var want_monospace = key == "mono" or key == "monospace"
        var requested_slant = _requested_slant(slant)
        var requested_weight = _requested_weight(weight)

        var scores = List[Int]()
        for face in self.faces:
            scores.append(
                _score(
                    face,
                    candidates,
                    requested_slant,
                    requested_weight,
                    want_monospace,
                )
            )

        var order = _ranked_order(scores)
        if codepoint < 0:
            return self.faces[order[0]].path
        for index in order:
            if _face_covers_codepoint(self.faces[index], codepoint):
                return self.faces[index].path
        return self.faces[order[0]].path


def _ranked_order(scores: List[Int]) -> List[Int]:
    """Indices into `scores`, best (lowest) first.

    Each entry is packed as `score * len(scores) + index` before being
    handed to the builtin `sort`, which takes no comparator: one
    ascending pass over the packed values then orders by score and, for
    equal scores, by index -- the sorted-path order
    `_collect_font_files` established, which is what keeps two equally
    good faces from swapping between runs. The packing has room to
    spare: a score tops out around twelve million, so the product stays
    far inside Int even on a machine with thousands of faces installed.
    """
    var count = len(scores)
    var order = List[Int]()
    if count == 0:
        return order^

    var packed = List[Int]()
    for i in range(count):
        packed.append(scores[i] * count + i)
    sort(packed)
    for value in packed:
        order.append(value % count)
    return order^


def resolve_font_file(
    family: String,
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
) raises -> String:
    """Resolve `family`/`slant`/`weight` to an absolute font file path.

    Generic and metric aliases are expanded, and an unrecognized family
    falls back through the default sans list, so this raises only on a
    machine with no installed fonts.

    Scans the font directories on every call; build one `FontDatabase`
    (or `FontCache`) to resolve more than a handful of fonts.

    Args:
        family: Font family name or generic alias (e.g. "sans-serif").
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.

    Returns:
        The matched font's absolute file path.

    Raises:
        Error: no font files were found on this machine.
    """
    var database = FontDatabase()
    return database.resolve(family, slant, weight)


def resolve_font_file_for_char(
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    codepoint: Int,
) raises -> String:
    """Like `resolve_font_file`, but constrained to a font that contains
    `codepoint` -- the fallback `render.mojo` uses when the requested
    family has no glyph for a character, such as CJK text under a
    Latin-only "Sans".

    If no installed font has `codepoint`, the unconstrained best match is
    returned. Check the result with `glyph_outline.has_glyph` to
    distinguish that from a real hit.

    Args:
        family: Font family name or generic alias (e.g. "sans-serif").
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        codepoint: Unicode codepoint the matched font should contain.

    Returns:
        The matched font's absolute file path.

    Raises:
        Error: no font files were found on this machine.
    """
    var database = FontDatabase()
    return database.resolve(family, slant, weight, codepoint)

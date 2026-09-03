"""Font discovery: resolves a family/slant/weight request to a font file
path on disk, with no linked library. One of the three parts of text
rendering, alongside glyph resolution and metrics (`ttf.mojo`) and
rasterization (`fill_path_aa`, see `path.mojo`).

Four steps, covering what `libfontconfig` does for a drawing library:

1. **Enumerate the installed fonts.** Walk each platform's font
   directories (`_font_directories`), collect every `sfnt` container
   found (`.ttf`/`.ttc`/`.otf`/`.otc`), and read each one's identity out
   of its own `name`/`OS/2`/`head`/`post` tables (`_parse_face`). There
   is no cache file and no XML; the tables in the font files are the
   database.
2. **Expand generic families.** "sans-serif"/"serif"/"monospace" and the
   classic metric aliases (Helvetica, Arial, Times, Courier) are ordered
   preference lists rather than real families (`_family_candidates`) --
   the job fontconfig's `/etc/fonts/conf.d/*.conf` rules do.
3. **Score, don't filter.** Every installed face is ranked against the
   request and the best one wins, so a request resolves as long as one
   font is installed (`_score`). The scoring terms run in fontconfig's
   own priority order (`FcCompare*`): family, spacing, slant, weight,
   width.
4. **Fall back per character.** `resolve_font_file_for_char` ranks a
   font that maps the codepoint above every other consideration, reading
   candidate `cmap` tables in score order (`_face_covers_codepoint`) --
   fontconfig's `FC_CHARSET` constraint.

Not covered here: fontconfig's XML rule engine, its
`~/.cache/fontconfig` binary cache, per-language coverage matching, and
named-instance expansion of variable fonts (a variable font matches as
its default instance).

Where it looks: on Linux `~/.local/share/fonts` and `~/.fonts` plus
`/usr/share/fonts`, `/usr/local/share/fonts` and `/usr/share/X11/fonts`;
on macOS `~/Library/Fonts`, `/Library/Fonts`, `/System/Library/Fonts`
(and its `Supplemental`) plus Homebrew's font prefixes.
**`CANVAS_MOJO_FONT_PATH`** (colon-separated directories) adds font
trees in a nonstandard prefix -- a container image, a test fixture, a
font vendored beside an application -- and is searched ahead of the
platform defaults. Fonts have to be installed for text to render; this
package bundles none.

A scan measures ~3.3ms on this machine (51 installed faces, warm page
cache), two thirds of it the directory walk rather than the font files;
each file is read a few hundred bytes at a time -- a table directory and
three or four small tables -- never whole, which `ttf.mojo` does later
for the one font that wins. Matching against an already-built
`FontDatabase` is arithmetic over a list, so the scan is paid once per
`FontDatabase` rather than once per lookup. `FontCache` holds one, and
`render.mojo`'s cache-less entry points each build one FontCache for the
duration of the call, so a `draw_text` scans once. A caller drawing many
labels through a single `FontCache` pays ~3.3ms in total.

This module imports nothing from `canvas.text`, which is why
`FontSlant`/`FontWeight` and the small binary readers below live here
rather than being imported from a module that uses them: Mojo resolves a
struct's method surface, and whatever it imports, eagerly rather than
lazily. It is also why `_face_covers_codepoint` walks a `cmap` here
rather than calling `ttf.mojo`'s -- this one answers "is this codepoint
mapped" from a byte range read off disk, where `TTFFace` needs the whole
parsed, `glyf`-bearing file it refuses to build for a CFF font.

This module resolves a font *file* and nothing more: it does not parse
that file's outlines, measure text, hint, or rasterize. `render.mojo`
drives it, together with `ttf.mojo` and `fill_path_aa`, to draw text.
"""

from std.os import getenv, listdir
from std.os.path import expanduser, isdir, realpath
from std.sys.info import CompilationTarget

comptime _FONT_PATH_ENV_VAR = "CANVAS_MOJO_FONT_PATH"
"""Colon-separated extra font directories, searched before the platform
defaults. The escape hatch for a font tree in a nonstandard prefix --
a container image, a test fixture, a vendored font shipped beside an
application -- for when the platform defaults in `_font_directories`
don't cover a machine.
"""


struct FontSlant(Copyable, ImplicitlyCopyable, Movable):
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


struct FontWeight(Copyable, ImplicitlyCopyable, Movable):
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
    """Whether `ttf.mojo` can actually parse this file: `glyf` outlines,
    and not a collection container it reads no face index from. False
    for a CFF/OpenType-CFF (`OTTO`) font and for every face in a `.ttc`.
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


def _collect_font_files() -> List[String]:
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
    var pending = List[String]()
    var depths = List[Int]()

    for directory in _font_directories():
        pending.append(directory)
        depths.append(0)

    var i = 0
    while i < len(pending):
        var directory = pending[i]
        var depth = depths[i]
        i += 1

        var entries = _listdir_or_empty(directory)
        sort(entries)
        for entry in entries:
            var child = String(directory, "/", entry)
            # Extension first, `isdir` second: `listdir` reports no
            # entry type, so deciding "recurse or not" costs a stat,
            # and a name that already looks like a font never needs
            # one. A directory named `*.ttf` would be misfiled here and
            # then dropped by `_parse_font_file`, which cannot open it.
            if not _has_sfnt_extension(entry):
                if isdir(child) and depth < _MAX_SCAN_DEPTH:
                    pending.append(child)
                    depths.append(depth + 1)
                continue
            var canonical = child
            try:
                canonical = String(realpath(child))
            except:
                pass
            if canonical in seen:
                continue
            seen[canonical] = True
            files.append(canonical)

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
        has_glyf and not in_collection,
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

        Never raises on a bad font file or an unreadable directory --
        those are skipped -- so a machine with no fonts installed at all
        yields an empty database, and it is `resolve` that reports that.
        """
        self.faces = List[FontFace]()
        for path in _collect_font_files():
            for face in _parse_font_file(path):
                self.faces.append(face.copy())

    def resolve(
        self,
        family: String,
        slant: FontSlant = FontSlant.NORMAL,
        weight: FontWeight = FontWeight.NORMAL,
        codepoint: Int = -1,
    ) raises -> String:
        """Best-matching font file for this request.

        With `codepoint` set, a face that actually maps that character
        outranks every other term: the candidates are ranked normally,
        then walked best-first until one covers the codepoint. If none
        does -- no installed font has the character at all -- the plain
        best match is returned rather than raising, so a missing glyph
        degrades to a `.notdef` box rather than a failed render.

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

    Generic aliases ("sans-serif", "serif", "monospace") and the classic
    metric aliases (Helvetica, Arial, Times, Courier) are expanded, and
    an unrecognized family falls back through the default sans list, so
    this raises only on a machine with no installed fonts at all.

    Scans the font directories on every call. A caller resolving more
    than a handful of fonts should build one `FontDatabase` (or
    `FontCache`) and reuse it.

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
    `codepoint`. This is the fallback lookup `render.mojo` uses when the
    requested family has no glyph for a character -- CJK text under a
    Latin-only "Sans", say -- and it searches every installed font, the
    way a desktop text stack's fallback chain does.

    If no installed font has `codepoint`, the unconstrained best match is
    returned. A caller that must distinguish "found a font with the
    glyph" from "gave up" checks the result with
    `glyph_outline.has_glyph`.

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

"""Tests for the persisted font database in font_discovery.mojo: the
cache file's round trip, and every way it can be invalid.

The point of each case is that an unusable cache costs correctness
nothing -- a `FontDatabase` built against a stale, corrupt, truncated
or unwritable cache holds exactly what a scan would have found. The
scanned database is captured once with the cache disabled and every
other case is compared against it.

Each test points `CANVAS_MOJO_FONT_CACHE` at its own file under
`tests/`, so nothing here reads or writes the developer's real cache
in `~/.cache/canvas_mojo/`.
"""

from std.os import getenv, remove, setenv
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from canvas.text.font_discovery import (
    FontDatabase,
    FontSlant,
    FontWeight,
    _cache_path,
    _escape_field,
    _read_cache,
    _search_key,
    _unescape_field,
    _font_directories,
)

comptime _CACHE_VAR = "CANVAS_MOJO_FONT_CACHE"


def _use_cache(path: String) raises:
    _ = setenv(_CACHE_VAR, path, overwrite=True)


def _disable_cache() raises:
    _ = setenv(_CACHE_VAR, "off", overwrite=True)


def _scanned_faces() raises -> Int:
    """How many faces a scan finds, with the cache out of the way."""
    _disable_cache()
    return len(FontDatabase().faces)


def _read_file(path: String) raises -> String:
    var f = open(path, "r")
    var text = f.read()
    f.close()
    return text


def _write_file(path: String, text: String) raises:
    var f = open(path, "w")
    f.write(text)
    f.close()


def test_fields_survive_escaping() raises:
    """A record is tab-separated, so a field holding a tab, a newline
    or a backslash has to come back as it went in -- and so does one
    holding text outside ASCII, which macOS ships as font filenames
    (`/System/Library/Fonts/\u30d2\u30e9\u30ae\u30ce\u4e38\u30b4 ProN W4.ttc`) and any
    machine can have as a family name.
    """
    var cases: List[String] = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        (
            "/System/Library/Fonts/\u30d2\u30e9\u30ae\u30ce\u4e38\u30b4 ProN"
            " W4.ttc"
        ),
        "Noto Sans CJK JP",
        "\u0627\u0644\u062e\u0637 \u0627\u0644\u0639\u0631\u0628\u064a",
        "back\\slash",
        "tab\there",
        "new\nline",
        "",
        "\u00e9\u00e8\u00ea",
    ]
    for sample in cases:
        var round_tripped = _unescape_field(_escape_field(sample))
        assert_equal(round_tripped, sample, "field survives the round trip")
    # And the escaped form carries no raw tab or newline, which is what
    # the record format depends on.
    assert_false("\t" in _escape_field("tab\there"), "no raw tab escapes")
    assert_false("\n" in _escape_field("new\nline"), "no raw newline escapes")


def test_disabled_cache_writes_nothing() raises:
    var path = String("tests/_test_font_cache_disabled.txt")
    if exists(path):
        remove(path)
    _disable_cache()
    assert_equal(_cache_path(), "", "`off` resolves to no path")
    var db = FontDatabase()
    assert_true(len(db.faces) > 0, "a scan still finds fonts")
    assert_false(exists(path), "nothing is written when the cache is off")


def test_round_trip_matches_a_scan() raises:
    var expected = _scanned_faces()
    var path = String("tests/_test_font_cache_round_trip.txt")
    if exists(path):
        remove(path)
    _use_cache(path)
    var first = FontDatabase()  # scans, then writes
    assert_true(exists(path), "the scan wrote a cache file")
    assert_equal(len(first.faces), expected, "the scan is unchanged by caching")

    var second = FontDatabase()  # reads
    assert_equal(len(second.faces), expected, "the cache holds every face")
    # Field for field on the first face, which is the whole record
    # layout: paths and names survive escaping, the numbers survive
    # the text round trip.
    ref a = first.faces[0]
    ref b = second.faces[0]
    assert_equal(a.path, b.path, "path")
    assert_equal(len(a.names), len(b.names), "name count")
    for i in range(len(a.names)):
        assert_equal(a.names[i], b.names[i], "name")
    assert_equal(a.weight, b.weight, "weight")
    assert_equal(a.slant, b.slant, "slant")
    assert_equal(a.width, b.width, "width")
    assert_equal(a.monospace, b.monospace, "monospace")
    assert_equal(a.renderable, b.renderable, "renderable")
    assert_equal(a.cmap_offset, b.cmap_offset, "cmap offset")
    assert_equal(a.cmap_length, b.cmap_length, "cmap length")
    remove(path)


def test_a_cached_database_resolves_the_same_font() raises:
    var path = String("tests/_test_font_cache_resolve.txt")
    if exists(path):
        remove(path)
    _use_cache(path)
    var scanned = FontDatabase()
    var from_cache = FontDatabase()
    var a = scanned.resolve("sans-serif", FontSlant.NORMAL, FontWeight.NORMAL)
    var b = from_cache.resolve(
        "sans-serif", FontSlant.NORMAL, FontWeight.NORMAL
    )
    assert_equal(a, b, "the same file wins from the cache as from the scan")
    var bold_a = scanned.resolve(
        "sans-serif", FontSlant.NORMAL, FontWeight.BOLD
    )
    var bold_b = from_cache.resolve(
        "sans-serif", FontSlant.NORMAL, FontWeight.BOLD
    )
    assert_equal(bold_a, bold_b, "and for a weight that picks a different file")
    remove(path)


def test_a_changed_directory_mtime_invalidates() raises:
    var expected = _scanned_faces()
    var path = String("tests/_test_font_cache_stale.txt")
    if exists(path):
        remove(path)
    _use_cache(path)
    _ = FontDatabase()
    var text = _read_file(path)
    # Rewrite one recorded modification time. That is what installing
    # or removing a font does to the directory holding it.
    var marker = String("# mtimes\t")
    var start = text.find(marker) + marker.byte_length()
    var colon = text.find(":", start)
    var tab = text.find("\t", colon)
    var doctored = String(text[byte=:colon]) + ":1" + String(text[byte=tab:])
    _write_file(path, doctored)
    assert_equal(
        len(_read_cache(path, _search_key(_font_directories()))),
        0,
        "a directory whose mtime moved invalidates the file",
    )
    var db = FontDatabase()
    assert_equal(len(db.faces), expected, "and the rebuild finds every face")
    remove(path)


def test_a_different_search_key_invalidates() raises:
    var path = String("tests/_test_font_cache_key.txt")
    if exists(path):
        remove(path)
    _use_cache(path)
    _ = FontDatabase()
    assert_equal(
        len(_read_cache(path, "v1 dirs=/somewhere/else,")),
        0,
        "a file recorded for other directories is not used",
    )
    remove(path)


def test_a_truncated_file_invalidates() raises:
    var expected = _scanned_faces()
    var path = String("tests/_test_font_cache_truncated.txt")
    if exists(path):
        remove(path)
    _use_cache(path)
    _ = FontDatabase()
    var text = _read_file(path)
    # Everything but the end marker: what a crash or a second process
    # writing at the same time leaves behind.
    var cut = text.rfind("# end")
    _write_file(path, String(text[byte=:cut]))
    assert_equal(
        len(_read_cache(path, _search_key(_font_directories()))),
        0,
        "a file with no end marker is not used",
    )
    var db = FontDatabase()
    assert_equal(len(db.faces), expected, "and the rebuild finds every face")
    remove(path)


def test_a_corrupt_record_invalidates() raises:
    var expected = _scanned_faces()
    var path = String("tests/_test_font_cache_corrupt.txt")
    if exists(path):
        remove(path)
    _use_cache(path)
    _ = FontDatabase()
    var text = _read_file(path)
    var count_marker = String("# count\t")
    var count_at = text.find(count_marker)
    var line_end = text.find("\n", count_at)
    # A record count that disagrees with the records present.
    var doctored = (
        String(text[byte=:count_at])
        + "# count\t999999"
        + String(text[byte=line_end:])
    )
    _write_file(path, doctored)
    assert_equal(
        len(_read_cache(path, _search_key(_font_directories()))),
        0,
        "a count that disagrees with the records is not used",
    )
    _write_file(path, "this is not a cache file at all\n")
    assert_equal(
        len(_read_cache(path, _search_key(_font_directories()))),
        0,
        "nor is a file that was never one",
    )
    var db = FontDatabase()
    assert_equal(len(db.faces), expected, "and the rebuild finds every face")
    remove(path)


def test_a_missing_file_is_not_an_error() raises:
    var path = String("tests/_test_font_cache_absent.txt")
    if exists(path):
        remove(path)
    assert_equal(
        len(_read_cache(path, _search_key(_font_directories()))),
        0,
        "a file that is not there reads as empty",
    )
    assert_equal(len(_read_cache("", "any key")), 0, "so does no path at all")


def test_an_unwritable_location_still_scans() raises:
    var expected = _scanned_faces()
    # /proc is present and unwritable on Linux; on macOS the path does
    # not exist and `makedirs` fails just the same. Either way the
    # write must be silent and the scan must stand.
    _use_cache("/proc/canvas_mojo_should_not_exist/fonts.txt")
    var db = FontDatabase()
    assert_equal(len(db.faces), expected, "an unwritable cache costs nothing")
    assert_false(
        exists("/proc/canvas_mojo_should_not_exist/fonts.txt"),
        "and writes nothing",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

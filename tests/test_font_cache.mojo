"""Tests for canvas_mojo/text/font_cache.mojo.

Needs the same "Sans"-resolvable system font
tests/test_font_discovery.mojo documents.

What's tested: FontCache.resolve/resolve_for_char return the path a
cache miss would, and resolve_face/resolve_face_for_char render and
measure identically to an uncached call. The cache must never change
*what* gets resolved, only how often the installed fonts get scanned
and how often a file is parsed.

Special attention to the failure mode a face cache invites that a
path-only cache can't: `set_pixel_size` mutates a `TTFFace` in place,
so a cache keyed on path alone would share one instance across two
sizes and silently corrupt whichever lost the race. The two
interleaved-size tests below exist for that, deliberately alternating
sizes rather than testing each in isolation.

Not tested: the font-directory scan and TTFFace-parse time this cache
exists to avoid. A wall-clock assertion would be flaky across machines
and CI load; font_cache.mojo documents the measured cost instead.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas_mojo.buffer import Canvas
from canvas_mojo.color import Color
from canvas_mojo.text.font_cache import FontCache
from canvas_mojo.text.font_discovery import (
    FontSlant,
    FontWeight,
    resolve_font_file,
    resolve_font_file_for_char,
)
from canvas_mojo.text.render import (
    draw_text,
    measure_text,
    measure_text_block,
    TextAlign,
)


def test_resolve_matches_an_uncached_lookup() raises:
    var cache = FontCache()
    var cached_path = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    var direct_path = resolve_font_file(
        "Sans", FontSlant.NORMAL, FontWeight.NORMAL
    )
    assert_equal(cached_path, direct_path)


def test_resolve_is_stable_across_repeated_calls_on_the_same_cache() raises:
    # The point of the cache: a second call for the same (family,
    # slant, weight) must return exactly what a fresh resolution
    # would, once it comes from the Dict rather than the database.
    var cache = FontCache()
    var first = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    var second = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    assert_equal(first, second)


def test_resolve_distinguishes_different_slant_weight_combinations() raises:
    # A cache keyed by family alone would collapse these into one
    # entry, so BOLD and NORMAL must be separate keys -- resting on the
    # machine-specific fact
    # test_bold_weight_resolves_to_a_different_file_than_normal
    # establishes against an uncached lookup directly.
    var cache = FontCache()
    var normal = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    var bold = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.BOLD)
    var direct_normal = resolve_font_file(
        "Sans", FontSlant.NORMAL, FontWeight.NORMAL
    )
    var direct_bold = resolve_font_file(
        "Sans", FontSlant.NORMAL, FontWeight.BOLD
    )
    assert_equal(normal, direct_normal)
    assert_equal(bold, direct_bold)


def test_resolve_for_char_matches_the_fallback_path_a_cache_miss_would_find() raises:
    # The "Ubuntu" family / snowman (U+2603) environment fact
    # test_font_discovery.mojo's char-constrained tests rely on.
    var cache = FontCache()
    var cached_path = cache.resolve_for_char(
        "Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603
    )
    var direct_path = resolve_font_file_for_char(
        "Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603
    )
    assert_equal(cached_path, direct_path)


def test_measure_text_cache_overload_matches_the_uncached_result() raises:
    var cache = FontCache()
    var cached = measure_text("Hello", 24.0, cache=cache)
    var uncached = measure_text("Hello", 24.0)
    assert_equal(cached.width, uncached.width)
    assert_equal(cached.height, uncached.height)
    assert_equal(cached.advance, uncached.advance)


def test_measure_text_block_cache_overload_matches_the_uncached_result() raises:
    var cache = FontCache()
    var cached = measure_text_block(
        "Hello\nWorld", 24.0, rotation=0.5, align=TextAlign.CENTER, cache=cache
    )
    var uncached = measure_text_block(
        "Hello\nWorld", 24.0, rotation=0.5, align=TextAlign.CENTER
    )
    assert_equal(cached.x, uncached.x)
    assert_equal(cached.y, uncached.y)
    assert_equal(cached.width, uncached.width)
    assert_equal(cached.height, uncached.height)


def test_draw_text_cache_overload_renders_identically_to_the_uncached_call() raises:
    var with_cache = Canvas(120, 60)
    var cache = FontCache()
    draw_text(with_cache, 10, 40, "Hi", Color(0, 0, 0), 24.0, cache=cache)

    var without_cache = Canvas(120, 60)
    draw_text(without_cache, 10, 40, "Hi", Color(0, 0, 0), 24.0)

    assert_equal(len(with_cache.pixels), len(without_cache.pixels))
    for i in range(len(with_cache.pixels)):
        assert_equal(with_cache.pixels[i], without_cache.pixels[i])


def test_shared_cache_serves_repeated_draw_text_calls_correctly() raises:
    # The intended usage: one FontCache across several draw_text calls,
    # as every tick label on an axis would share -- so reuse can't
    # corrupt anything between calls.
    var canvas = Canvas(200, 80)
    var cache = FontCache()
    draw_text(canvas, 5, 20, "One", Color(0, 0, 0), 18.0, cache=cache)
    draw_text(canvas, 5, 45, "Two", Color(0, 0, 0), 18.0, cache=cache)
    draw_text(canvas, 5, 70, "Three", Color(0, 0, 0), 18.0, cache=cache)

    var reference = Canvas(200, 80)
    draw_text(reference, 5, 20, "One", Color(0, 0, 0), 18.0)
    draw_text(reference, 5, 45, "Two", Color(0, 0, 0), 18.0)
    draw_text(reference, 5, 70, "Three", Color(0, 0, 0), 18.0)

    for i in range(len(canvas.pixels)):
        assert_equal(canvas.pixels[i], reference.pixels[i])


def test_shared_cache_at_two_different_sizes_does_not_corrupt_either_size() raises:
    # The risk in keying a face cache on path alone: set_pixel_size
    # mutates a TTFFace in place, so one shared instance across two
    # sizes leaves whichever drew second silently wrong -- an 11px axis
    # label beside a 16px title through one FontCache. Interleaved on
    # purpose (11, 16, 11), so a bug can't hide behind the cache having
    # seen one size at a time.
    var canvas = Canvas(200, 100)
    var cache = FontCache()
    draw_text(canvas, 5, 20, "Axis", Color(0, 0, 0), 11.0, cache=cache)
    draw_text(canvas, 5, 50, "Title", Color(0, 0, 0), 16.0, cache=cache)
    draw_text(canvas, 5, 80, "Axis", Color(0, 0, 0), 11.0, cache=cache)

    var reference = Canvas(200, 100)
    draw_text(reference, 5, 20, "Axis", Color(0, 0, 0), 11.0)
    draw_text(reference, 5, 50, "Title", Color(0, 0, 0), 16.0)
    draw_text(reference, 5, 80, "Axis", Color(0, 0, 0), 11.0)

    for i in range(len(canvas.pixels)):
        assert_equal(canvas.pixels[i], reference.pixels[i])


def test_shared_cache_serves_fallback_glyphs_at_two_different_sizes_correctly() raises:
    # The same corruption risk for resolve_face_for_char's cache:
    # "Ubuntu" has no snowman glyph (U+2603), so this drives the
    # fallback-face cache at two interleaved sizes.
    var canvas = Canvas(80, 120)
    var cache = FontCache()
    draw_text(
        canvas, 5, 40, "☃", Color(0, 0, 0), 20.0, family="Ubuntu", cache=cache
    )
    draw_text(
        canvas, 5, 100, "☃", Color(0, 0, 0), 32.0, family="Ubuntu", cache=cache
    )

    var reference = Canvas(80, 120)
    draw_text(reference, 5, 40, "☃", Color(0, 0, 0), 20.0, family="Ubuntu")
    draw_text(reference, 5, 100, "☃", Color(0, 0, 0), 32.0, family="Ubuntu")

    for i in range(len(canvas.pixels)):
        assert_equal(canvas.pixels[i], reference.pixels[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

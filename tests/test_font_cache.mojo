"""Tests for canvas_mojo/text/font_cache.mojo.

Needs the same "Sans"-resolvable system font tests/test_font_discovery.
mojo's own docstring already documents -- not a new real-machine
dependency this file introduces.

What's tested: FontCache.resolve/resolve_for_char return the identical
path a cache miss would (correctness first -- the cache must never
change *what* gets resolved, only how many times fontconfig is asked),
and the cache=-accepting overloads of measure_text/draw_text/
measure_text_block produce output identical to their uncached
counterparts. Not tested here: the actual subprocess-spawn/fontconfig-
round-trip time this cache exists to avoid -- a wall-clock assertion
would be flaky across machines/CI load, not a meaningful correctness
check; canvas_mojo/text/font_cache.mojo's own docstring documents the
measured, probe-confirmed cost directly instead.
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
from canvas_mojo.text.render import draw_text, measure_text, measure_text_block, TextAlign


def test_resolve_matches_an_uncached_lookup() raises:
    var cache = FontCache()
    var cached_path = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    var direct_path = resolve_font_file("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    assert_equal(cached_path, direct_path)


def test_resolve_is_stable_across_repeated_calls_on_the_same_cache() raises:
    # The actual point of the cache -- a second call for the identical
    # (family, slant, weight) must return the exact same path a fresh
    # resolution would, not something stale or subtly different, once
    # it's served from the Dict instead of fontconfig itself.
    var cache = FontCache()
    var first = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    var second = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    assert_equal(first, second)


def test_resolve_distinguishes_different_slant_weight_combinations() raises:
    # A cache keyed too loosely (e.g. by family alone) would wrongly
    # collapse these to the same entry -- confirms BOLD/NORMAL are
    # tracked as separate cache keys, matching the machine-specific
    # "BOLD differs from NORMAL" fact test_font_discovery.mojo's own
    # test_bold_weight_resolves_to_a_different_file_than_normal already
    # establishes directly against fontconfig.
    var cache = FontCache()
    var normal = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    var bold = cache.resolve("Sans", FontSlant.NORMAL, FontWeight.BOLD)
    var direct_normal = resolve_font_file("Sans", FontSlant.NORMAL, FontWeight.NORMAL)
    var direct_bold = resolve_font_file("Sans", FontSlant.NORMAL, FontWeight.BOLD)
    assert_equal(normal, direct_normal)
    assert_equal(bold, direct_bold)


def test_resolve_for_char_matches_the_fallback_path_a_cache_miss_would_find() raises:
    # Same "Ubuntu" family / snowman (U+2603) machine-specific fact
    # test_font_discovery.mojo's own char-constrained tests rely on --
    # see that file's own docstring for why this is a real, probe-
    # confirmed environment fact, not an assumption.
    var cache = FontCache()
    var cached_path = cache.resolve_for_char("Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603)
    var direct_path = resolve_font_file_for_char("Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603)
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
    var uncached = measure_text_block("Hello\nWorld", 24.0, rotation=0.5, align=TextAlign.CENTER)
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
    # The actual intended usage: one FontCache reused across several
    # draw_text calls (e.g. every tick label on one chart axis) --
    # confirms reuse doesn't corrupt anything from one call to the
    # next, not just that a single isolated call still works.
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

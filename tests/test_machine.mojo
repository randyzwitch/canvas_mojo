"""Tests for machine.mojo: what the package asks the CPU about itself.

The value `l3_slice_bytes` returns is the machine's, so a test cannot
assert a number -- it asserts the contract instead: plausible, stable
for the life of the process, and equal to the fallback when the
machine says nothing usable. `_parse_cache_size` is pure and is
checked against the shapes Linux writes.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.machine import (
    _L3_MAX_PLAUSIBLE,
    _L3_MIN_PLAUSIBLE,
    _L3_SLICE_FALLBACK,
    _init_l3_slice_bytes,
    _parse_cache_size,
    l3_slice_bytes,
)


def test_parses_the_sizes_sysfs_writes() raises:
    # The suffix is what sysfs uses; a 3970X writes "16384K\n".
    assert_equal(_parse_cache_size("16384K"), 16 * 1024 * 1024, "K suffix")
    assert_equal(_parse_cache_size("16384K\n"), 16 * 1024 * 1024, "trailing")
    assert_equal(_parse_cache_size("8M"), 8 * 1024 * 1024, "M suffix")
    assert_equal(_parse_cache_size("2G"), 2 * 1024 * 1024 * 1024, "G suffix")
    assert_equal(_parse_cache_size("512"), 512, "no suffix is bytes")
    assert_equal(_parse_cache_size("32k"), 32 * 1024, "lower case")


def test_unparseable_text_reads_as_no_answer() raises:
    # 0 is what the caller reads as "the machine did not say", which
    # the clamp then turns into the fallback.
    assert_equal(_parse_cache_size(""), 0, "empty")
    assert_equal(_parse_cache_size("unknown"), 0, "not a number")
    assert_equal(_parse_cache_size("\n"), 0, "newline alone")


def test_the_size_is_plausible_and_stable() raises:
    var first = l3_slice_bytes()
    assert_true(
        first >= _L3_MIN_PLAUSIBLE and first <= _L3_MAX_PLAUSIBLE,
        "inside the range the clamp admits, whatever this machine is",
    )
    # Cached for the life of the process, so every later call agrees.
    for _ in range(4):
        assert_equal(l3_slice_bytes(), first, "stable across calls")


def test_an_implausible_probe_falls_back() raises:
    # The initializer is what applies the clamp, so it is what has to
    # be right on a machine whose answer this one cannot produce: a
    # part with no L3 reports nothing and must not yield a threshold
    # of zero, which would band every clear.
    var chosen = _init_l3_slice_bytes()
    assert_true(
        chosen >= _L3_MIN_PLAUSIBLE and chosen <= _L3_MAX_PLAUSIBLE,
        "the initializer clamps to the plausible range",
    )
    assert_true(_L3_SLICE_FALLBACK >= _L3_MIN_PLAUSIBLE, "fallback is usable")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

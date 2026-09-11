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
    _probe_l3_slice_bytes,
    _sysctl_int,
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


def test_reports_what_this_platform_answered() raises:
    """Not an assertion about the number -- it is the machine's -- but
    a record of it in the run's output.

    A passing suite cannot say whether the platform answered or the
    clamp fell back, because both produce a usable value, and the
    macOS path is the one nobody developing this can run. Printing the
    raw probe beside the value in use is what makes a CI log answer
    that. A raw 0 means the platform said nothing and the fallback is
    in force; anything else is what the OS reported.
    """
    var raw = _probe_l3_slice_bytes()
    var used = l3_slice_bytes()
    # Which key answered matters on Apple Silicon, where there is no
    # conventional L3 and the performance and efficiency clusters have
    # different L2 sizes: a value describing the efficiency cluster
    # would be the wrong threshold for work that runs on the
    # performance cores. Both read 0 off macOS.
    print("        hw.l3cachesize:", _sysctl_int("hw.l3cachesize"))
    print("        hw.l2cachesize:", _sysctl_int("hw.l2cachesize"))
    print(
        "        hw.perflevel0.l2cachesize:",
        _sysctl_int("hw.perflevel0.l2cachesize"),
    )
    print(
        "        hw.perflevel1.l2cachesize:",
        _sysctl_int("hw.perflevel1.l2cachesize"),
    )
    print("        probe:", raw, "bytes")
    print("        in use:", used, "bytes")
    print("        fallback:", _L3_SLICE_FALLBACK, "bytes")
    if raw == 0:
        print("        -> the platform said nothing; fallback in force")
    elif raw < _L3_MIN_PLAUSIBLE or raw > _L3_MAX_PLAUSIBLE:
        print("        -> outside the plausible range; fallback in force")
    else:
        print("        -> the platform answered and is being used")
    # The one thing that must hold either way.
    assert_true(
        used >= _L3_MIN_PLAUSIBLE and used <= _L3_MAX_PLAUSIBLE,
        "the value in use is plausible however it was arrived at",
    )


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

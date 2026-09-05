"""Tests for named_colors.mojo: the CSS named-colour table resolves
from the module and from the package root, holds the spec's values,
and spells the gray pairs identically.
"""

from std.testing import assert_equal, TestSuite

from canvas import CORNFLOWERBLUE, REBECCAPURPLE, WHITE
from canvas.color import Color
from canvas.named_colors import (
    ALICEBLUE,
    BLACK,
    DARKGRAY,
    DARKGREY,
    GRAY,
    GREY,
    LIGHTSLATEGRAY,
    LIGHTSLATEGREY,
    YELLOWGREEN,
)


def _assert_rgb(c: Color, r: Int, g: Int, b: Int, name: String) raises:
    assert_equal(Int(c.r), r, name + " r")
    assert_equal(Int(c.g), g, name + " g")
    assert_equal(Int(c.b), b, name + " b")
    assert_equal(Int(c.a), 255, name + " is opaque")


def test_spec_values() raises:
    # Spot checks against the CSS Color Module Level 3 table, the
    # first and last entries included.
    _assert_rgb(ALICEBLUE, 240, 248, 255, "aliceblue")
    _assert_rgb(BLACK, 0, 0, 0, "black")
    _assert_rgb(CORNFLOWERBLUE, 100, 149, 237, "cornflowerblue")
    _assert_rgb(REBECCAPURPLE, 102, 51, 153, "rebeccapurple")
    _assert_rgb(WHITE, 255, 255, 255, "white")
    _assert_rgb(YELLOWGREEN, 154, 205, 50, "yellowgreen")


def test_gray_and_grey_spellings_agree() raises:
    assert_equal(GRAY.r, GREY.r)
    assert_equal(GRAY.g, GREY.g)
    assert_equal(GRAY.b, GREY.b)
    assert_equal(DARKGRAY.r, DARKGREY.r)
    assert_equal(LIGHTSLATEGRAY.b, LIGHTSLATEGREY.b)
    _assert_rgb(GRAY, 128, 128, 128, "gray")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

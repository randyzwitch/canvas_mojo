"""Tests for canvas/text/text_run.mojo: the run a multi-run label is
made of. Laying a list of them out is render.mojo's job and is tested
in test_text.mojo; drawing them is each backend's and is tested with
that backend. Here, only the value itself.
"""

from std.testing import assert_equal, TestSuite

from canvas.text.font_discovery import FontSlant
from canvas.text.text_run import TextRun


def test_defaults_are_upright_at_the_pen_on_the_baseline() raises:
    var r = TextRun("x", 14.0)
    assert_equal(r.text, "x")
    assert_equal(r.size, 14.0)
    assert_equal(r.slant, FontSlant.NORMAL)
    assert_equal(r.dx, 0.0)
    assert_equal(r.dy, 0.0)


def test_every_field_is_kept() raises:
    var r = TextRun("2", 12.6, FontSlant.ITALIC, dx=1.5, dy=-6.3)
    assert_equal(r.text, "2")
    assert_equal(r.size, 12.6)
    assert_equal(r.slant, FontSlant.ITALIC)
    assert_equal(r.dx, 1.5)
    assert_equal(r.dy, -6.3)


def test_is_a_value() raises:
    var a = TextRun("a", 10.0)
    var b = a
    b.text = "b"
    b.dy = -3.0
    assert_equal(a.text, "a")
    assert_equal(a.dy, 0.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

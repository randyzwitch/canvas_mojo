"""Tests for the worker cap and the band policy it feeds.

The cap changes how a pass divides its rows, never what it draws.
Every banded pass here writes disjoint rows, so a render at one worker
and a render at sixty-four have to agree byte for byte -- which is the
property these check, across the kernels that band: the anti-aliased
sweep under both fill rules, a gradient source fill, a blur, a
transformed composite, and a downsample.
"""

from std.math import cos, pi, sin
from std.testing import assert_equal, assert_true, TestSuite

from canvas.blur import blur
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.compose import Filter, draw_canvas
from canvas.fill_rule import FillRule
from canvas.geometry import Matrix2D
from canvas.gradient import LinearGradient
from canvas.path import Path, fill_path_aa, fill_path_gradient_aa
from canvas.resize import downsample
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.rects import fill_rect
from canvas.workers import _bands_for, _worker_limit

comptime W = 160
comptime H = 120
comptime INK = Color(20, 30, 40, 255)
comptime WHITE = Color(255, 255, 255, 255)


def _wiggle() raises -> Path:
    var p = Path()
    p.move_to(10.0, 60.0)
    for i in range(12):
        var a = Float64(i) * 0.41
        p.cubic_curve_to(
            15.0 + 12.0 * Float64(i),
            60.0 + 45.0 * sin(a),
            22.0 + 12.0 * Float64(i),
            60.0 - 45.0 * cos(a * 1.3),
            30.0 + 11.0 * Float64(i),
            60.0 + 30.0 * sin(a * 1.9),
        )
    p.close()
    return p^


def _render(workers: Int) raises -> Canvas:
    """One scene through every kernel that bands, at a given cap."""
    var c = Canvas(W, H, WHITE)
    c.set_max_workers(workers)
    var path = _wiggle()
    fill_path_aa(c, path, Color(30, 90, 160, 200), FillRule.EVEN_ODD)
    fill_path_aa(c, path, Color(200, 60, 40, 120), FillRule.NONZERO)

    var g = LinearGradient(-10.0, 5.0, 170.0, 115.0)
    g.add_stop(0.0, Color(255, 0, 0, 255))
    g.add_stop(1.0, Color(0, 0, 255, 180))
    fill_path_gradient_aa(c, path, g, FillRule.NONZERO)

    var layer = Canvas(W, H, Color(0, 0, 0, 0))
    layer.set_max_workers(workers)
    fill_circle_aa(layer, 75.0, 55.0, 40.0, Color(60, 120, 200, 128))
    fill_rect(layer, 10, 10, 45, 30, Color(240, 90, 30, 255))
    var placed = (
        Matrix2D.scaling(1.4, 1.4)
        .then(Matrix2D.rotation(pi / 7.0))
        .then(Matrix2D.translation(20.0, 10.0))
    )
    draw_canvas(c, layer, placed, filter=Filter.BILINEAR)

    blur(c, 6)

    var big = Canvas(W * 2, H * 2, WHITE)
    big.set_max_workers(workers)
    fill_circle_aa(big, Float64(W), Float64(H), Float64(H) * 0.8, INK)
    var small = downsample(big, 2)
    draw_canvas(c, small, 0, 0, 160)
    return c^


def test_a_render_is_identical_at_every_worker_cap() raises:
    var reference = _render(1)
    var caps: List[Int] = [3, 16, 64, 0]
    for ci in range(len(caps)):
        var other = _render(caps[ci])
        assert_equal(other.width, reference.width)
        assert_equal(other.height, reference.height)
        for i in range(len(reference.pixels)):
            assert_equal(
                other.pixels[i],
                reference.pixels[i],
                String("byte ", i, " at cap ", caps[ci]),
            )


def test_the_cap_is_reported_and_normalized() raises:
    var c = Canvas(8, 8, WHITE)
    assert_equal(c.max_workers(), 0, "no cap by default")
    c.set_max_workers(4)
    assert_equal(c.max_workers(), 4)
    c.set_max_workers(0)
    assert_equal(c.max_workers(), 0, "zero clears it")
    c.set_max_workers(-3)
    assert_equal(c.max_workers(), 0, "a negative cap is no cap")


def test_the_cap_does_not_survive_save_and_restore() raises:
    # It is a resource policy for the whole render, not drawing state
    # a local frame should be able to undo.
    var c = Canvas(8, 8, WHITE)
    c.set_max_workers(4)
    c.save()
    c.set_max_workers(2)
    c.restore()
    assert_equal(c.max_workers(), 2, "restore leaves the worker cap alone")


def test_small_work_stays_on_one_band() raises:
    # Below the floor a pass runs inline however many workers exist,
    # because dispatching costs more than the work does.
    assert_equal(_bands_for(1000, 100, 5000, 0), 1)
    assert_equal(_bands_for(39999, 1000, 5000, 0), 1)
    assert_true(_bands_for(400000, 1000, 5000, 0) > 1)


def test_bands_follow_the_work_and_respect_every_bound() raises:
    # One band per `work_per_band`, then the caller's cap, then the
    # rows there are to divide.
    assert_equal(_bands_for(400000, 1000, 50000, 0), 8)
    assert_equal(_bands_for(400000, 1000, 50000, 4), 4)
    assert_equal(_bands_for(400000, 3, 50000, 0), 3)
    assert_equal(_bands_for(400000, 1000, 10000000, 0), 1)


def test_the_worker_limit_falls_back_to_the_runtime() raises:
    var available = _worker_limit(0)
    assert_true(available >= 1)
    assert_equal(_worker_limit(-1), available, "a negative cap is no cap")
    assert_equal(
        _worker_limit(available + 100),
        available,
        "a cap above what exists is no cap",
    )
    if available > 1:
        assert_equal(_worker_limit(1), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

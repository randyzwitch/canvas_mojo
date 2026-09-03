"""Tests for canvas/shapes/arcs.mojo: exact pixel sets for known
inputs, verified against hand-traced runs of the same algorithms.
"""

from std.testing import assert_equal, assert_true, TestSuite
from std.math import atan2, cos, pi, sin

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.shapes.arcs import (
    _AngleSpan,
    _angle_in_span,
    _arc_points,
    draw_arc,
    draw_arc_aa,
    fill_arc,
    fill_arc_aa,
    fill_ring_sector,
    fill_ring_sector_aa,
)

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _assert_pixel(
    c: Canvas, x: Int, y: Int, expected: Color, label: String
) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected.r, label + " (r)")
    assert_equal(p.g, expected.g, label + " (g)")
    assert_equal(p.b, expected.b, label + " (b)")


def _ink(c: Canvas) -> Int:
    """Total red written to the canvas -- a whole-image fingerprint,
    since BG is black and every arc below draws a red-channel color.
    """
    var total = 0
    for y in range(c.height):
        for x in range(c.width):
            total += Int(c.get_pixel(x, y).r)
    return total


def _max_red(c: Canvas) -> Int:
    """The brightest red on the canvas -- the ceiling a translucent
    stroke must not blow past by blending a pixel twice.
    """
    var highest = 0
    for y in range(c.height):
        for x in range(c.width):
            var v = Int(c.get_pixel(x, y).r)
            if v > highest:
                highest = v
    return highest


def test_arc_points_matches_hand_derived_quarter_circle() raises:
    # Computed by hand: radius=10, angle 0 -> pi/2 gives
    # steps=max(4,int(10*pi/2))=15, so 16 points, start exactly (10,0)
    # and end (0,10) -- cos(pi/2) is ~6e-16, which rounds to 0.
    var pts = _arc_points(0.0, 0.0, 10.0, 0.0, pi / 2.0)
    assert_equal(len(pts), 16)
    assert_equal(pts[0].x, 10)
    assert_equal(pts[0].y, 0)
    assert_equal(pts[15].x, 0)
    assert_equal(pts[15].y, 10)


def test_angle_in_span_matches_hand_traced_cases() raises:
    assert_true(_angle_in_span(pi / 4.0, 0.0, pi / 2.0))
    assert_true(not _angle_in_span(pi, 0.0, pi / 2.0))
    # A span crossing the atan2 discontinuity at +/-pi: a raw sample
    # angle of -3*pi/4 is equivalent to 5*pi/4, inside
    # [5*pi/4, 7*pi/4] -- the wraparound _angle_in_span exists for.
    assert_true(_angle_in_span(-3.0 * pi / 4.0, 5.0 * pi / 4.0, 7.0 * pi / 4.0))
    assert_true(not _angle_in_span(0.0, 5.0 * pi / 4.0, 7.0 * pi / 4.0))


def test_draw_arc_degenerate_radius_plots_center() raises:
    var c = Canvas(5, 5, BG)
    draw_arc(c, 2.0, 2.0, 0.0, 0.0, pi, FG)
    _assert_pixel(c, 2, 2, FG, "radius<=0 falls back to a single pixel")


def test_fill_arc_degenerate_radius_is_a_noop() raises:
    var c = Canvas(5, 5, BG)
    fill_arc(c, 2.0, 2.0, 0.0, 0.0, pi, FG)
    _assert_pixel(
        c, 2, 2, BG, "radius<=0 draws nothing (unlike draw_arc's single pixel)"
    )


def test_fill_arc_wedge_covers_only_its_own_angle_span() raises:
    # A quarter-circle wedge from angle 0 to pi/2, right to down on
    # screen: a point on the bisector (pi/4) must be filled, one in the
    # opposite direction (5*pi/4, up-left) must stay background.
    var c = Canvas(60, 60, BG)
    fill_arc(c, 30.0, 30.0, 20.0, 0.0, pi / 2.0, FG)
    _assert_pixel(c, 30 + 10, 30 + 10, FG, "inside the wedge's own bisector")
    _assert_pixel(
        c, 30 - 10, 30 - 10, BG, "opposite direction, outside the wedge"
    )
    _assert_pixel(
        c,
        30,
        30,
        FG,
        "center is part of every wedge (the two radii meet there)",
    )


def test_fill_arc_three_wedges_tile_a_full_circle_without_gaps() raises:
    # Three 120-degree wedges at one center/radius covering the full
    # circle: every point strictly inside the radius must carry some
    # wedge's color, with no gaps. Opaque colors can't distinguish
    # overlap from coverage, so this checks "not background"
    # everywhere inside, which a gap would fail.
    var c = Canvas(80, 80, BG)
    var cx = 40.0
    var cy = 40.0
    var r = 30.0
    var third = 2.0 * pi / 3.0
    fill_arc(c, cx, cy, r, 0.0, third, Color(255, 0, 0))
    fill_arc(c, cx, cy, r, third, 2.0 * third, Color(0, 255, 0))
    fill_arc(c, cx, cy, r, 2.0 * third, 3.0 * third, Color(0, 0, 255))

    var gaps = 0
    for dy in range(-20, 21):
        for dx in range(-20, 21):
            if dx * dx + dy * dy <= 15 * 15:  # comfortably inside the radius
                var p = c.get_pixel(40 + dx, 40 + dy)
                if p.r == BG.r and p.g == BG.g and p.b == BG.b:
                    gaps += 1
    assert_equal(gaps, 0)


def test_fill_arc_aa_respects_translucent_input_color() raises:
    var c = Canvas(60, 60, Color(0, 0, 0))
    fill_arc_aa(c, 30.0, 30.0, 20.0, 0.0, pi / 2.0, Color(200, 0, 0, 128))
    var p = c.get_pixel(40, 40)  # inside the wedge, well clear of any AA edge
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def test_fill_ring_sector_only_fills_between_the_two_radii() raises:
    var c = Canvas(80, 80, BG)
    fill_ring_sector(c, 40.0, 40.0, 15.0, 30.0, 0.0, 2.0 * pi, FG)
    _assert_pixel(c, 40, 40, BG, "inner hole stays background")
    _assert_pixel(c, 40 + 22, 40, FG, "the ring itself is filled")
    _assert_pixel(
        c, 40 + 45, 40, BG, "well outside the outer radius stays background"
    )


def test_fill_ring_sector_degenerate_radii_is_a_noop() raises:
    var c = Canvas(10, 10, BG)
    fill_ring_sector(c, 5.0, 5.0, 3.0, 3.0, 0.0, 2.0 * pi, FG)  # inner == outer
    fill_ring_sector(c, 5.0, 5.0, 5.0, 3.0, 0.0, 2.0 * pi, FG)  # inner > outer
    fill_ring_sector(c, 5.0, 5.0, -1.0, 0.0, 0.0, 2.0 * pi, FG)  # outer <= 0
    _assert_pixel(
        c, 5, 5, BG, "every degenerate radius combination draws nothing"
    )


def test_fill_ring_sector_aa_respects_translucent_input_color() raises:
    var c = Canvas(80, 80, Color(0, 0, 0))
    fill_ring_sector_aa(
        c, 40.0, 40.0, 15.0, 30.0, 0.0, 2.0 * pi, Color(200, 0, 0, 128)
    )
    var p = c.get_pixel(40 + 22, 40)  # deep in the ring, clear of any AA edge
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def test_fill_ring_sector_aa_fills_past_the_outer_arcs_own_bounding_box() raises:
    """Regression test for canvas_mojo issue #33 -- a wedge whose
    [start_angle, end_angle] span doesn't cross a cardinal angle (0,
    pi/2, pi, 3*pi/2) has an inner-arc extreme that reaches *closer to
    the center* than anything on the outer arc does over that same
    span, past the outer arc's bounding box rather than inside it (see
    _arc_bounds). Scanning only that box never visits those pixels,
    cutting a rectangular notch into the ring instead of a clean
    angular gap.

    cx=cy=100, outer_radius=100, inner_radius=50, start_angle=pi/6
    (30deg), end_angle=pi/3 (60deg) -- round angles, so the geometry is
    exact. Computed via Python's `math` module, not taken from this
    package's `_arc_bounds`/`cos`/`sin`:

    - The outer arc's y-range over that span is exactly
      [150, 186.60...], just the two endpoints, since no cardinal
      angle falls in [30deg, 60deg].
    - The straight edge from the outer endpoint at 30deg,
      (186.60..., 150), back to the inner endpoint at 30deg,
      (143.30..., 125), passes through y=125 -- 25 below the outer
      arc's min_y of 150, so past its bounding box.
    - A point deep inside the sector and clear of every edge
      (angle=35deg, radius=60, 10 units in from inner_radius=50 and 40
      from outer_radius=100) rounds to pixel (149, 134). y=134 falls
      outside an outer-bounds-only scan range of ~[149, 188] and well
      inside the correct ~[124, 188].
    """
    var c = Canvas(200, 200, BG)
    fill_ring_sector_aa(c, 100.0, 100.0, 50.0, 100.0, pi / 6.0, pi / 3.0, FG)
    _assert_pixel(
        c,
        149,
        134,
        FG,
        "deep in the ring, past the outer arc's own bounding box",
    )


def test_wedge_fast_fill_does_not_bleed_past_the_straight_edges() raises:
    # The provably-inside fast path fills a pixel outright without
    # sampling it. If its containment test were too permissive, the
    # first casualty would be the wedge's two straight edges: pixels
    # the boundary crosses would come out solid instead of partially
    # covered. This pins that they stay anti-aliased.
    #
    # A sweep of 1.2 radians is under pi, so the fast path is active.
    var c = Canvas(120, 120, BG)
    fill_arc_aa(c, 60.0, 60.0, 45.0, 0.0, 1.2, FG)

    # Deep interior of the wedge -- solid, and the fast path's job.
    _assert_pixel(c, 78, 72, FG, "interior of the wedge is solid")

    # Just outside the start edge (angle 0 runs along +x, so anything
    # a little above it in screen terms is outside the sweep).
    assert_equal(c.get_pixel(80, 58).r, 0, "outside the start edge")

    # The edge itself must be partially covered somewhere along it: a
    # scan across the boundary has to find at least one intermediate
    # value, which a too-eager fast fill would replace with a hard
    # 0/255 step.
    var partials = 0
    for y in range(45, 76):
        var v = Int(c.get_pixel(72, y).r)
        if v > 0 and v < 255:
            partials += 1
    assert_true(
        partials > 0,
        "the wedge's boundary is anti-aliased, not a hard step",
    )


def test_wedge_renders_consistently_either_side_of_the_half_turn_guard() raises:
    # The fast path is only sound for a sweep of at most pi, so it is
    # switched off above that. Both branches must produce a wedge with
    # the same character: solid deep inside, anti-aliased at the arc.
    # A bug in either branch shows up as one of these failing while its
    # twin passes.
    var narrow = Canvas(120, 120, BG)
    fill_arc_aa(narrow, 60.0, 60.0, 45.0, 0.0, 3.10, FG)  # just under pi
    var wide = Canvas(120, 120, BG)
    fill_arc_aa(wide, 60.0, 60.0, 45.0, 0.0, 3.18, FG)  # just over pi

    _assert_pixel(narrow, 60, 75, FG, "narrow sweep fills its interior")
    _assert_pixel(wide, 60, 75, FG, "wide sweep fills its interior")

    # Both must be anti-aliased at the outer arc, on a ray that is
    # inside both sweeps.
    var narrow_partials = 0
    var wide_partials = 0
    for y in range(100, 112):
        var nv = Int(narrow.get_pixel(60, y).r)
        var wv = Int(wide.get_pixel(60, y).r)
        if nv > 0 and nv < 255:
            narrow_partials += 1
        if wv > 0 and wv < 255:
            wide_partials += 1
    assert_true(narrow_partials > 0, "narrow sweep's arc is anti-aliased")
    assert_true(wide_partials > 0, "wide sweep's arc is anti-aliased")


def test_ring_sector_fast_fill_keeps_its_inner_hole() raises:
    # The ring's fast path additionally requires the pixel square to
    # clear the inner radius. If that test were wrong the hole would
    # fill in, which is the most visible way a donut chart can break.
    var c = Canvas(120, 120, BG)
    fill_ring_sector_aa(c, 60.0, 60.0, 20.0, 45.0, 0.0, 1.2, FG)

    _assert_pixel(c, 60, 60, BG, "the centre stays empty")
    _assert_pixel(c, 68, 63, BG, "and so does the rest of the hole")
    _assert_pixel(c, 85, 70, FG, "while the band itself is solid")


def test_draw_arc_aa_degenerate_radius_plots_center() raises:
    var c = Canvas(5, 5, BG)
    draw_arc_aa(c, 2.0, 2.0, 0.0, 0.0, pi, FG)
    _assert_pixel(c, 2, 2, FG, "radius<=0 falls back to a single pixel")


def test_draw_arc_aa_draws_the_boundary_without_filling_the_wedge() raises:
    # The curved boundary only: no radii back to the center, and no
    # fill. cx=cy=50, radius=25, sweeping 0 -> pi/2, so the arc runs
    # from (75, 50) round to (50, 75) through its bisector at pi/4,
    # 50 + 25*cos(pi/4) = 67.68 in both axes.
    var c = Canvas(100, 100, BG)
    draw_arc_aa(c, 50.0, 50.0, 25.0, 0.0, pi / 2.0, FG)

    assert_true(
        Int(c.get_pixel(68, 68).r) > 0, "the arc itself is drawn at radius"
    )
    _assert_pixel(c, 50, 50, BG, "no radii meet at the center")
    _assert_pixel(c, 58, 58, BG, "the wedge interior is not filled")
    _assert_pixel(c, 32, 32, BG, "same radius, outside the angular span")


def test_draw_arc_aa_respects_translucent_input_color() raises:
    # An arc is a polyline whose segments share endpoints, so a stroke
    # that drew segment by segment would blend those joints twice --
    # the "every pixel gets exactly one set_pixel" rule. Color
    # (200, 0, 0, 128) over black blends once to
    # _div255(200 * 128) = 100, and a second blend of the same color
    # over that would give 150. So 100 is both the value a fully
    # covered pixel must reach and the ceiling no pixel may exceed.
    #
    # Width 5 rather than 1 so the band is wide enough to guarantee at
    # least one fully covered pixel for the equality to land on.
    var c = Canvas(100, 100, BG)
    draw_arc_aa(
        c, 50.0, 50.0, 30.0, 0.0, pi / 2.0, Color(200, 0, 0, 128), width=5.0
    )
    assert_equal(
        _max_red(c),
        100,
        "the arc blends exactly once everywhere along its length",
    )


def test_draw_arc_aa_keeps_sub_pixel_radius() raises:
    # Two arcs a third of a pixel apart in radius must lay down
    # different ink: a stroke over samples snapped to whole pixels
    # would round most of them onto the same pixels. Both arcs are
    # drawn on their own canvas and compared pixel by pixel.
    var a = Canvas(100, 100, BG)
    draw_arc_aa(a, 50.0, 50.0, 30.0, 0.0, pi / 2.0, FG)
    var b = Canvas(100, 100, BG)
    draw_arc_aa(b, 50.0, 50.0, 30.33, 0.0, pi / 2.0, FG)
    var differing = 0
    for y in range(100):
        for x in range(100):
            if a.get_pixel(x, y).r != b.get_pixel(x, y).r:
                differing += 1
    assert_true(differing > 20, "a sub-pixel radius change moves the stroke")


def test_draw_arc_aa_dashes_leave_gaps() raises:
    # A dashed arc draws strictly less ink than the solid one, and the
    # gap between dashes is a real gap: the pattern's off stretch has
    # at least one pixel on the arc left untouched.
    var solid = Canvas(100, 100, BG)
    draw_arc_aa(solid, 50.0, 50.0, 30.0, 0.0, pi / 2.0, FG, width=3.0)
    var dashed = Canvas(100, 100, BG)
    var dashes: List[Float64] = [8.0, 8.0]
    draw_arc_aa(
        dashed, 50.0, 50.0, 30.0, 0.0, pi / 2.0, FG, width=3.0, dashes=dashes
    )
    assert_true(_ink(dashed) < _ink(solid), "dashes remove ink")
    var gaps = 0
    for y in range(100):
        for x in range(100):
            if (
                solid.get_pixel(x, y).r == FG.r
                and dashed.get_pixel(x, y).r == BG.r
            ):
                gaps += 1
    assert_true(gaps > 0, "and leave pixels of the solid arc unpainted")


def test_draw_arc_aa_width_widens_the_stroke() raises:
    # `width` is forwarded to draw_polyline_aa rather than dropped: a
    # thicker stroke over the same arc lays down strictly more ink.
    var thin = Canvas(100, 100, BG)
    draw_arc_aa(thin, 50.0, 50.0, 30.0, 0.0, pi / 2.0, FG, width=1.0)
    var thick = Canvas(100, 100, BG)
    draw_arc_aa(thick, 50.0, 50.0, 30.0, 0.0, pi / 2.0, FG, width=4.0)
    assert_true(_ink(thick) > _ink(thin), "width=4 draws more ink than width=1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def test_angle_span_matches_the_atan2_form_everywhere() raises:
    # `_AngleSpan` replaces a per-sub-sample `atan2` with cross-product
    # sign tests. That is only worth doing if it agrees with the angle
    # form it replaced, so this sweeps the whole space the renderer can
    # hand it: start angles right around the atan2 discontinuity, spans
    # from negative through past a full turn, and sample directions at
    # half-degree steps -- which lands samples exactly on boundary rays,
    # the case where a cross product sits at zero and its sign is
    # whatever the rounding produced.
    #
    # ~390k combinations. Deliberately not a spot check: a mismatch
    # here is a wrongly lit or unlit sub-sample, and the cases most
    # likely to break are precisely the degenerate ones a hand-picked
    # set would skip.
    var mismatches = 0
    for si in range(-8, 9):
        var start = Float64(si) * 0.7853981633974483
        for spi in range(-2, 30):
            var end = start + Float64(spi) * 0.2617993877991494
            var span = _AngleSpan(start, end)
            for ai in range(0, 720):
                var a = Float64(ai) * 0.008726646259971648
                var fx = cos(a) * 7.0
                var fy = sin(a) * 7.0
                if span.contains(fx, fy) != _angle_in_span(
                    atan2(fy, fx), start, end
                ):
                    mismatches += 1
            # the center, where atan2(0, 0) is 0 and there is no
            # meaningful direction to take a cross product against
            if span.contains(0.0, 0.0) != _angle_in_span(
                atan2(0.0, 0.0), start, end
            ):
                mismatches += 1
    assert_equal(mismatches, 0)

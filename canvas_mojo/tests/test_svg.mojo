"""Tests for svg.mojo: SvgCanvas's own DrawTarget conformance and
draw_text() -- string-content assertions (the markup itself, hand-
derived the same rigor pixel-color assertions get elsewhere in this
workspace) rather than pixel colors, since there's no raster buffer
here to sample. No cairo needed -- SvgCanvas never touches
canvas_mojo.text (see its own docstring).
"""

from std.math import pi
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.path import Path
from canvas_mojo.svg import SvgCanvas
from canvas_mojo.text_align import TextAlign


def test_fill_rect_emits_expected_rect_element() raises:
    var svg = SvgCanvas(100, 80)
    svg.fill_rect(10, 20, 30, 40, Color(18, 52, 86))
    assert_true(
        '<rect x="10" y="20" width="30" height="40" fill="#123456"/>' in svg.to_string(),
        "fill_rect's own rect element, exact attributes",
    )


def test_draw_line_aa_emits_expected_line_element_with_default_width() raises:
    var svg = SvgCanvas(100, 80)
    svg.draw_line_aa(0, 0, 10, 10, Color(0, 0, 0))
    assert_true(
        '<line x1="0" y1="0" x2="10" y2="10" stroke="#000000" stroke-width="1.000"'
        ' stroke-linecap="round"/>' in svg.to_string(),
        "draw_line_aa's default width (1.0), matching draw_line_aa's own raster default",
    )


def test_draw_line_aa_respects_custom_width() raises:
    var svg = SvgCanvas(100, 80)
    svg.draw_line_aa(0, 0, 10, 10, Color(255, 255, 255), width=3.5)
    assert_true(
        'stroke-width="3.500"' in svg.to_string(), "custom width threaded through to stroke-width"
    )


def test_fill_circle_aa_emits_expected_circle_element() raises:
    var svg = SvgCanvas(100, 80)
    svg.fill_circle_aa(50, 40, 12, Color(255, 0, 0))
    assert_true(
        '<circle cx="50" cy="40" r="12" fill="#ff0000"/>' in svg.to_string(),
        "fill_circle_aa's own circle element, exact attributes",
    )


def test_fill_arc_aa_small_wedge_matches_hand_derived_endpoints() raises:
    # cx=50, cy=60, radius=20, start=0, end=pi/2 -- endpoints hand-
    # derived via python3 (cx + r*cos(theta), cy + r*sin(theta)):
    # start -> (70.0, 60.0), end -> (50.0, 80.0). Span (pi/2) < pi, so
    # large-arc-flag is 0; sweep-flag is always 1 (see fill_arc_aa's
    # own docstring for why no sign flip is needed).
    var svg = SvgCanvas(100, 100)
    svg.fill_arc_aa(50.0, 60.0, 20.0, 0.0, 1.5707963267948966, Color(0, 255, 0))
    assert_true(
        '<path d="M50.000,60.000 L70.000,60.000 A20.000,20.000 0 0,1 50.000,80.000'
        ' Z" fill="#00ff00"/>' in svg.to_string(),
        "small wedge (< pi span): hand-derived M/L/A/Z, large-arc-flag 0",
    )


def test_fill_arc_aa_wide_wedge_sets_large_arc_flag() raises:
    # Same center/radius, start=0, end=4.0 (span=4.0 > pi) -- endpoints
    # hand-derived via python3 (36.92712758272776, 44.86395009384144),
    # then rounded to _format_svg_float's own 3 decimal places (36.927,
    # 44.864) -- see svg.mojo's own _format_svg_float docstring for why
    # this rounding exists (a real 1-ULP cross-context float
    # discrepancy this fixes, not just cosmetic). large-arc-flag 1.
    var svg = SvgCanvas(100, 100)
    svg.fill_arc_aa(50.0, 60.0, 20.0, 0.0, 4.0, Color(0, 0, 255))
    assert_true(
        '<path d="M50.000,60.000 L70.000,60.000 A20.000,20.000 0 1,1 36.927,44.864'
        ' Z" fill="#0000ff"/>' in svg.to_string(),
        "wide wedge (> pi span): hand-derived endpoint, large-arc-flag 1",
    )


def test_fill_ring_sector_aa_quarter_wedge_matches_hand_derived_endpoints() raises:
    # cx=100, cy=100, inner=25, outer=50, start=0, end=pi/2 -- all four
    # corner points hand-derived via python3 (cx + r*cos(theta), cy +
    # r*sin(theta)): outer_start (150.0, 100.0), outer_end (100.0,
    # 150.0), inner_end (100.0, 125.0), inner_start (125.0, 100.0).
    # Span pi/2 < pi, so large-arc-flag is 0 for both arcs; outer arc
    # sweeps forward (1), inner arc sweeps backward (0) -- see this
    # method's own docstring for why that traces the ring boundary
    # correctly.
    var svg = SvgCanvas(200, 200)
    svg.fill_ring_sector_aa(100.0, 100.0, 25.0, 50.0, 0.0, 1.5707963267948966, Color(255, 128, 0))
    assert_true(
        '<path d="M150.000,100.000 A50.000,50.000 0 0,1 100.000,150.000 L100.000,125.000'
        ' A25.000,25.000 0 0,0 125.000,100.000 Z" fill="#ff8000"/>' in svg.to_string(),
        "quarter donut wedge: hand-derived M/A/L/A/Z, both large-arc-flags 0",
    )


def test_fill_ring_sector_aa_wide_wedge_sets_large_arc_flag() raises:
    # inner=15, outer=25 (inner < outer, a real ring), start=0, end=4.0
    # (span=4.0 > pi) -- every endpoint independently computed via
    # python3, cross-checked against a real Mojo run (an earlier draft
    # of this exact test had inner/outer swapped, plus guessed rather
    # than computed endpoint values -- caught by that cross-check, not
    # shipped), then rounded to _format_svg_float's own 3 decimal
    # places the same way the fill_arc_aa wide-wedge test's own
    # endpoint is (see that test's own comment for why).
    var svg = SvgCanvas(200, 200)
    svg.fill_ring_sector_aa(50.0, 60.0, 15.0, 25.0, 0.0, 4.0, Color(0, 200, 100))
    assert_true(
        '<path d="M75.000,60.000 A25.000,25.000 0 1,1 33.659,41.080'
        ' L40.195,48.648 A15.000,15.000 0 1,0 65.000,60.000'
        ' Z" fill="#00c864"/>' in svg.to_string(),
        "wide donut wedge: both endpoints hand-derived and cross-checked, large-arc-flag 1 on both arcs",
    )


def test_stroke_path_aa_emits_open_path_with_no_fill() raises:
    var path = Path()
    path.move_to(1.0, 2.0)
    path.line_to(3.0, 4.0)
    var svg = SvgCanvas(100, 100)
    svg.stroke_path_aa(path, Color(10, 20, 30), width=2.0)
    assert_true(
        '<path d="M1.000,2.000 L3.000,4.000" fill="none" stroke="#0a141e" stroke-width="2.000"'
        ' stroke-linecap="round" stroke-linejoin="round"/>' in svg.to_string(),
        "stroke_path_aa: open path, fill=none, exact d string",
    )


def test_fill_path_aa_emits_closed_path_with_fill_color() raises:
    var path = Path()
    path.move_to(0.0, 0.0)
    path.line_to(10.0, 0.0)
    path.line_to(10.0, 10.0)
    path.close()
    var svg = SvgCanvas(100, 100)
    svg.fill_path_aa(path, Color(200, 100, 0))
    assert_true(
        '<path d="M0.000,0.000 L10.000,0.000 L10.000,10.000 Z" fill="#c86400"/>' in svg.to_string(),
        "fill_path_aa: exact d string including the Z from Path.close()",
    )


def test_fill_path_aa_handles_quad_and_cubic_commands() raises:
    var path = Path()
    path.move_to(0.0, 0.0)
    path.quad_curve_to(5.0, 10.0, 10.0, 0.0)
    path.cubic_curve_to(12.0, 5.0, 14.0, 5.0, 16.0, 0.0)
    var svg = SvgCanvas(100, 100)
    svg.fill_path_aa(path, Color(0, 0, 0))
    assert_true(
        '<path d="M0.000,0.000 Q5.000,10.000 10.000,0.000 C12.000,5.000 14.000,5.000 16.000,0.000"'
        ' fill="#000000"/>' in svg.to_string(),
        "Q (quad) and C (cubic) commands map directly, same control-point order Path stores",
    )


def test_draw_text_left_align_maps_to_start_anchor() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.LEFT)
    assert_true(
        '<text x="10" y="20" font-size="12.000" fill="#000000" text-anchor="start">hi</text>'
        in svg.to_string(),
        "TextAlign.LEFT -> text-anchor=start, SVG's own default anchor",
    )


def test_draw_text_center_align_maps_to_middle_anchor() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.CENTER)
    assert_true('text-anchor="middle"' in svg.to_string(), "TextAlign.CENTER -> text-anchor=middle")


def test_draw_text_right_align_maps_to_end_anchor() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.RIGHT)
    assert_true('text-anchor="end"' in svg.to_string(), "TextAlign.RIGHT -> text-anchor=end")


def test_draw_text_escapes_xml_special_characters() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(0, 0, "5 < 10 & 10 > 5", Color(0, 0, 0), 12.0, TextAlign.LEFT)
    assert_true(
        ">5 &lt; 10 &amp; 10 &gt; 5<" in svg.to_string(),
        "<, &, > all escaped -- & escaped first so the other two don't get double-escaped",
    )


def test_draw_text_default_rotation_omits_transform_attribute() raises:
    # rotation's own default (0.0) must reproduce the exact pre-
    # existing no-transform output byte-for-byte -- the same "purely
    # additive" bar every optional parameter added to an existing,
    # already-depended-on method has to clear in this workspace.
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.LEFT)
    assert_true(
        '<text x="10" y="20" font-size="12.000" fill="#000000" text-anchor="start">hi</text>'
        in svg.to_string(),
        "rotation=0.0 (the default) -- no transform attribute at all",
    )


def test_draw_text_rotation_emits_hand_derived_rotate_transform() raises:
    # pi/2 radians -> exactly 90.0 degrees (90.000 through
    # _format_svg_float's own 3-decimal formatting) -- no sign flip
    # from canvas_mojo.text.draw_text's own Cairo-rotation convention,
    # since both Cairo's user space and SVG's viewport space put y
    # pointing down (see draw_text's own docstring).
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.LEFT, rotation=pi / 2.0)
    assert_true(
        '<text x="10" y="20" font-size="12.000" fill="#000000" text-anchor="start"'
        ' transform="rotate(90.000 10 20)">hi</text>' in svg.to_string(),
        "rotate(<degrees> <x> <y>), rotating around the text's own anchor point",
    )


def test_to_string_wraps_body_in_svg_root_with_correct_dimensions() raises:
    var svg = SvgCanvas(320, 240)
    var s = svg.to_string()
    assert_true(
        '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="240"'
        ' viewBox="0 0 320 240">' in s,
        "root <svg> element carries the exact constructor dimensions",
    )
    assert_true(s.strip().endswith("</svg>"), "document is properly closed")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

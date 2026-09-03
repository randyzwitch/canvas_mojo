"""Tests for svg.mojo: SvgCanvas's DrawTarget conformance and
draw_text(). Assertions are against the markup itself, hand-derived
with the rigor pixel-color assertions get elsewhere, since there's no
raster buffer to sample. No font machinery involved -- SvgCanvas
touches canvas.text only for FontWeight, a small struct that
reads no font files, never canvas.text.render.
"""

from std.math import pi
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from canvas.color import Color
from canvas.gradient import LinearGradient
from canvas.path import Path
from canvas.vector.svg import SvgCanvas
from canvas.text.font_discovery import FontWeight
from canvas.text.text_align import TextAlign


def test_fill_rect_emits_expected_rect_element() raises:
    var svg = SvgCanvas(100, 80)
    svg.fill_rect(10, 20, 30, 40, Color(18, 52, 86))
    assert_true(
        '<rect x="10" y="20" width="30" height="40" fill="#123456"/>'
        in svg.to_string(),
        "fill_rect's own rect element, exact attributes",
    )


def test_fill_rect_gradient_emits_expected_lineargradient_and_rect() raises:
    # x0/y0/x1/y1 pass through to the <linearGradient> element's
    # x1/y1/x2/y2 unchanged under userSpaceOnUse, and each stop's
    # offset/color/alpha map to offset/stop-color/stop-opacity. First
    # gradient in a fresh SvgCanvas, so its id is "grad1".
    var svg = SvgCanvas(100, 80)
    var g = LinearGradient(10.0, 0.0, 60.0, 0.0)
    g.add_stop(0.0, Color(255, 0, 0, 255))
    g.add_stop(1.0, Color(0, 0, 255, 128))
    svg.fill_rect_gradient(10, 20, 50, 30, g)
    var s = svg.to_string()
    assert_true(
        '<defs><linearGradient id="grad1" gradientUnits="userSpaceOnUse"'
        ' x1="10.000" y1="0.000" x2="60.000" y2="0.000">'
        '<stop offset="0.000" stop-color="#ff0000" stop-opacity="1.000"/>'
        '<stop offset="1.000" stop-color="#0000ff" stop-opacity="0.502"/>'
        "</linearGradient></defs>"
        in s,
        (
            "fill_rect_gradient: hand-derived <defs><linearGradient> markup,"
            " both stops, alpha as a 0-1 fraction"
        ),
    )
    assert_true(
        '<rect x="10" y="20" width="50" height="30" fill="url(#grad1)"/>' in s,
        (
            "fill_rect_gradient: the filled <rect> itself references the"
            " gradient's own id via url(#...)"
        ),
    )


def test_fill_rect_gradient_mints_a_fresh_id_per_call() raises:
    # Two gradients in one document must not collide over a <defs> id:
    # _gradient_count has to increment, not just look right on the
    # first call.
    var svg = SvgCanvas(100, 80)
    var g1 = LinearGradient(0.0, 0.0, 10.0, 0.0)
    g1.add_stop(0.0, Color(0, 0, 0))
    g1.add_stop(1.0, Color(255, 255, 255))
    svg.fill_rect_gradient(0, 0, 10, 10, g1)

    var g2 = LinearGradient(0.0, 0.0, 20.0, 0.0)
    g2.add_stop(0.0, Color(0, 0, 0))
    g2.add_stop(1.0, Color(255, 255, 255))
    svg.fill_rect_gradient(20, 0, 20, 10, g2)

    var s = svg.to_string()
    assert_true('id="grad1"' in s, "first gradient keeps id grad1")
    assert_true(
        'id="grad2"' in s,
        "second gradient gets its own id, grad2, not a repeat of grad1",
    )
    assert_true(
        'fill="url(#grad1)"' in s, "first rect references its own gradient"
    )
    assert_true(
        'fill="url(#grad2)"' in s,
        "second rect references its own gradient, not the first one's",
    )


def test_fill_rect_gradient_sorts_descending_stops_into_ascending_offset_order() raises:
    # add_stop guarantees insertion order doesn't matter, and the
    # raster color_at honors that, but the SVG spec clamps each
    # <stop>'s offset to be no less than the previous sibling's. So a
    # gradient built with descending offsets -- a continuous color
    # legend flipping each stop to 1.0 - offset -- collapses to one
    # flat color in every viewer unless the stops are sorted before
    # emission, while the identical raster fill renders correctly.
    # Three stops added 1.0, 0.5, 0.0, each a distinct color, so a
    # wrong sort shows up as a color at the wrong offset rather than
    # an ordering assertion that could pass by accident.
    var svg = SvgCanvas(100, 100)
    var g = LinearGradient(0.0, 0.0, 0.0, 100.0)
    g.add_stop(1.0, Color(60, 110, 200))
    g.add_stop(0.5, Color(235, 235, 235))
    g.add_stop(0.0, Color(220, 90, 40))
    svg.fill_rect_gradient(0, 0, 10, 100, g)
    assert_true(
        '<stop offset="0.000" stop-color="#dc5a28" stop-opacity="1.000"/>'
        '<stop offset="0.500" stop-color="#ebebeb" stop-opacity="1.000"/>'
        '<stop offset="1.000" stop-color="#3c6ec8" stop-opacity="1.000"/>'
        in svg.to_string(),
        (
            "stops added in descending offset order are emitted ascending, each"
            " still carrying its own original color"
        ),
    )


def test_fill_rect_gradient_preserves_relative_order_of_stops_at_an_equal_offset() raises:
    # A hard color transition is two stops at the same offset, which
    # the spec allows since offsets stay non-decreasing. Which one SVG
    # treats as before and after the seam depends on emission order, so
    # whichever was added first must stay first:
    # _stops_sorted_by_offset's insertion sort has to be stable, not
    # merely offset-correct. An unstable sort passes every
    # ascending-order assertion while swapping the seam's sides.
    var svg = SvgCanvas(100, 100)
    var g = LinearGradient(0.0, 0.0, 0.0, 100.0)
    g.add_stop(0.0, Color(255, 0, 0))
    g.add_stop(0.5, Color(0, 255, 0))  # added first at this offset
    g.add_stop(0.5, Color(0, 0, 255))  # added second at this offset
    g.add_stop(1.0, Color(0, 0, 0))
    svg.fill_rect_gradient(0, 0, 10, 100, g)
    assert_true(
        '<stop offset="0.500" stop-color="#00ff00" stop-opacity="1.000"/>'
        '<stop offset="0.500" stop-color="#0000ff" stop-opacity="1.000"/>'
        in svg.to_string(),
        (
            "the two offset=0.5 stops keep their own original relative order"
            " (green before blue)"
        ),
    )


def test_draw_line_aa_emits_expected_line_element_with_default_width() raises:
    var svg = SvgCanvas(100, 80)
    svg.draw_line_aa(0, 0, 10, 10, Color(0, 0, 0))
    assert_true(
        '<line x1="0" y1="0" x2="10" y2="10" stroke="#000000"'
        ' stroke-width="1.000" stroke-linecap="round"/>'
        in svg.to_string(),
        (
            "draw_line_aa's default width (1.0), matching draw_line_aa's own"
            " raster default"
        ),
    )


def test_draw_line_aa_respects_custom_width() raises:
    var svg = SvgCanvas(100, 80)
    svg.draw_line_aa(0, 0, 10, 10, Color(255, 255, 255), width=3.5)
    assert_true(
        'stroke-width="3.500"' in svg.to_string(),
        "custom width threaded through to stroke-width",
    )


def test_fill_circle_aa_emits_expected_circle_element() raises:
    var svg = SvgCanvas(100, 80)
    svg.fill_circle_aa(50, 40, 12, Color(255, 0, 0))
    assert_true(
        '<circle cx="50" cy="40" r="12" fill="#ff0000"/>' in svg.to_string(),
        "fill_circle_aa's own circle element, exact attributes",
    )


def test_fill_ellipse_aa_emits_expected_ellipse_element() raises:
    var svg = SvgCanvas(100, 80)
    svg.fill_ellipse_aa(50, 40, 20, 12, Color(0, 128, 255))
    assert_true(
        '<ellipse cx="50" cy="40" rx="20" ry="12" fill="#0080ff"/>'
        in svg.to_string(),
        "fill_ellipse_aa's ellipse element, exact attributes",
    )


def test_fill_ellipse_aa_with_equal_radii_is_not_emitted_as_a_circle() raises:
    # rx == ry is geometrically a circle, but the two methods stay
    # distinct on both backends: a caller that asked for an ellipse gets
    # <ellipse>, so round-tripping markup back to the call that made it
    # stays unambiguous.
    var svg = SvgCanvas(100, 80)
    svg.fill_ellipse_aa(50, 40, 15, 15, Color(0, 0, 0))
    var s = svg.to_string()
    assert_true(
        '<ellipse cx="50" cy="40" rx="15" ry="15"' in s,
        "stays an ellipse element",
    )
    assert_true("<circle" not in s, "not silently collapsed to a circle")


def test_translucent_fill_emits_fill_opacity() raises:
    # The vector backend has to carry alpha in a separate attribute:
    # #rrggbb has nowhere to put it. Without this the same DrawTarget
    # call renders translucent on Canvas and fully opaque here.
    # 128/255 = 0.50196..., which _format_svg_float rounds to 0.502.
    var svg = SvgCanvas(20, 20)
    svg.fill_rect(0, 0, 10, 10, Color(255, 0, 0, 128))
    assert_true(
        '<rect x="0" y="0" width="10" height="10" fill="#ff0000"'
        ' fill-opacity="0.502"/>'
        in svg.to_string(),
        "translucent fill carries fill-opacity as a 0-1 fraction",
    )


def test_translucent_stroke_emits_stroke_opacity() raises:
    # Strokes need stroke-opacity, not fill-opacity -- a stroked
    # element's fill is "none", so putting alpha on the wrong attribute
    # would silently do nothing.
    var svg = SvgCanvas(20, 20)
    svg.draw_line_aa(0, 0, 10, 10, Color(0, 0, 255, 64), 2.0)
    var s = svg.to_string()
    assert_true(
        'stroke-opacity="0.251"' in s, "64/255 = 0.251, on stroke-opacity"
    )
    assert_true(
        "fill-opacity" not in s, "not fill-opacity, which a stroke ignores"
    )


def test_opaque_color_emits_no_opacity_attribute() raises:
    # Omitted entirely at a == 255, the same omit-at-default convention
    # rotation and weight follow: opaque output is byte-identical to
    # what it was before alpha was carried at all.
    var svg = SvgCanvas(20, 20)
    svg.fill_rect(0, 0, 10, 10, Color(255, 0, 0))
    svg.draw_line_aa(0, 0, 10, 10, Color(0, 0, 255), 2.0)
    var s = svg.to_string()
    assert_true(
        "opacity" not in s, "no opacity attribute of any kind at full alpha"
    )


def test_every_color_taking_method_carries_alpha() raises:
    # One translucent call per Color-taking method on the trait, so a
    # method added later without an opacity attribute fails here rather
    # than silently rendering opaque. Counts occurrences instead of
    # asserting exact markup: the point is that none is missing.
    var c = Color(10, 20, 30, 128)
    var svg = SvgCanvas(200, 200)
    svg.fill_rect(0, 0, 10, 10, c)
    svg.draw_line_aa(0, 0, 10, 10, c, 2.0)
    svg.fill_circle_aa(50, 50, 10, c)
    svg.fill_ellipse_aa(50, 50, 12, 8, c)
    svg.fill_arc_aa(50.0, 50.0, 20.0, 0.0, 1.0, c)
    svg.fill_ring_sector_aa(50.0, 50.0, 10.0, 20.0, 0.0, 1.0, c)
    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(10.0, 10.0)
    svg.stroke_path_aa(p, c, 2.0)
    svg.fill_path_aa(p, c)
    svg.draw_text(10, 10, "hi", c, 12.0, TextAlign.LEFT)

    var s = svg.to_string()
    var opacity_attrs = 0
    for part in s.split("-opacity="):
        opacity_attrs += 1
    # 9 calls -> 9 attributes -> 10 pieces after splitting on the
    # attribute name.
    assert_equal(opacity_attrs, 10)


def test_draw_ellipse_aa_emits_a_stroked_ellipse() raises:
    # The outline half: fill="none" with the color on stroke, and
    # stroke-width 1 to match the raster primitive's fixed ~1px.
    var svg = SvgCanvas(100, 80)
    svg.draw_ellipse_aa(50, 40, 20, 12, Color(0, 128, 255))
    assert_true(
        '<ellipse cx="50" cy="40" rx="20" ry="12" fill="none"'
        ' stroke="#0080ff" stroke-width="1"/>'
        in svg.to_string(),
        "draw_ellipse_aa's stroked ellipse element, exact attributes",
    )


def test_fill_arc_aa_small_wedge_matches_hand_derived_endpoints() raises:
    # cx=50, cy=60, radius=20, start=0, end=pi/2. Endpoints derived
    # via python3 (cx + r*cos(theta), cy + r*sin(theta)): start ->
    # (70.0, 60.0), end -> (50.0, 80.0). Span pi/2 < pi, so
    # large-arc-flag is 0; sweep-flag is always 1.
    var svg = SvgCanvas(100, 100)
    svg.fill_arc_aa(50.0, 60.0, 20.0, 0.0, 1.5707963267948966, Color(0, 255, 0))
    assert_true(
        '<path d="M50.000,60.000 L70.000,60.000 A20.000,20.000 0 0,1'
        ' 50.000,80.000 Z" fill="#00ff00"/>'
        in svg.to_string(),
        "small wedge (< pi span): hand-derived M/L/A/Z, large-arc-flag 0",
    )


def test_fill_arc_aa_wide_wedge_sets_large_arc_flag() raises:
    # Same center/radius, start=0, end=4.0 (span > pi). Endpoints
    # derived via python3 (36.92712758272776, 44.86395009384144), then
    # rounded to _format_svg_float's 3 decimals (36.927, 44.864); see
    # that function for why the rounding exists. large-arc-flag 1.
    var svg = SvgCanvas(100, 100)
    svg.fill_arc_aa(50.0, 60.0, 20.0, 0.0, 4.0, Color(0, 0, 255))
    assert_true(
        '<path d="M50.000,60.000 L70.000,60.000 A20.000,20.000 0 1,1'
        ' 36.927,44.864 Z" fill="#0000ff"/>'
        in svg.to_string(),
        "wide wedge (> pi span): hand-derived endpoint, large-arc-flag 1",
    )


def test_fill_ring_sector_aa_quarter_wedge_matches_hand_derived_endpoints() raises:
    # cx=100, cy=100, inner=25, outer=50, start=0, end=pi/2. Four
    # corners derived via python3: outer_start (150.0, 100.0),
    # outer_end (100.0, 150.0), inner_end (100.0, 125.0), inner_start
    # (125.0, 100.0). Span < pi, so large-arc-flag is 0 for both arcs;
    # the outer sweeps forward (1), the inner backward (0).
    var svg = SvgCanvas(200, 200)
    svg.fill_ring_sector_aa(
        100.0, 100.0, 25.0, 50.0, 0.0, 1.5707963267948966, Color(255, 128, 0)
    )
    assert_true(
        '<path d="M150.000,100.000 A50.000,50.000 0 0,1 100.000,150.000'
        ' L100.000,125.000 A25.000,25.000 0 0,0 125.000,100.000 Z"'
        ' fill="#ff8000"/>'
        in svg.to_string(),
        "quarter donut wedge: hand-derived M/A/L/A/Z, both large-arc-flags 0",
    )


def test_fill_ring_sector_aa_wide_wedge_sets_large_arc_flag() raises:
    # inner=15, outer=25, start=0, end=4.0 (span > pi). Every endpoint
    # computed via python3 and cross-checked against a real run, then
    # rounded to _format_svg_float's 3 decimals as the fill_arc_aa
    # wide-wedge test's endpoints are.
    var svg = SvgCanvas(200, 200)
    svg.fill_ring_sector_aa(
        50.0, 60.0, 15.0, 25.0, 0.0, 4.0, Color(0, 200, 100)
    )
    assert_true(
        '<path d="M75.000,60.000 A25.000,25.000 0 1,1 33.659,41.080'
        " L40.195,48.648 A15.000,15.000 0 1,0 65.000,60.000"
        ' Z" fill="#00c864"/>'
        in svg.to_string(),
        (
            "wide donut wedge: both endpoints hand-derived and cross-checked,"
            " large-arc-flag 1 on both arcs"
        ),
    )


def test_stroke_path_aa_emits_open_path_with_no_fill() raises:
    var path = Path()
    path.move_to(1.0, 2.0)
    path.line_to(3.0, 4.0)
    var svg = SvgCanvas(100, 100)
    svg.stroke_path_aa(path, Color(10, 20, 30), width=2.0)
    assert_true(
        '<path d="M1.000,2.000 L3.000,4.000" fill="none" stroke="#0a141e"'
        ' stroke-width="2.000" stroke-linecap="round" stroke-linejoin="round"/>'
        in svg.to_string(),
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
        '<path d="M0.000,0.000 L10.000,0.000 L10.000,10.000 Z" fill="#c86400"/>'
        in svg.to_string(),
        "fill_path_aa: exact d string including the Z from Path.close()",
    )


def test_fill_path_aa_handles_arc_to_command() raises:
    # The small-wedge test's cx/cy/radius/start/end and endpoints.
    # arc_to is one segment inside a larger path, so unlike
    # fill_arc_aa's standalone wedge (M center L start A ... Z) there's
    # no leading M/L here -- just the A command, continuing from
    # move_to's point, which arc_to leaves to the caller.
    var path = Path()
    path.move_to(70.0, 60.0)
    path.arc_to(50.0, 60.0, 20.0, 0.0, 1.5707963267948966)
    var svg = SvgCanvas(100, 100)
    svg.fill_path_aa(path, Color(0, 255, 0))
    assert_true(
        '<path d="M70.000,60.000 A20.000,20.000 0 0,1 50.000,80.000"'
        ' fill="#00ff00"/>'
        in svg.to_string(),
        "arc_to: bare A command, hand-derived endpoint, large-arc-flag 0",
    )


def test_fill_path_aa_arc_to_wide_span_sets_large_arc_flag() raises:
    # test_fill_arc_aa_wide_wedge_sets_large_arc_flag's parameters and
    # endpoint.
    var path = Path()
    path.move_to(70.0, 60.0)
    path.arc_to(50.0, 60.0, 20.0, 0.0, 4.0)
    var svg = SvgCanvas(100, 100)
    svg.fill_path_aa(path, Color(0, 0, 255))
    assert_true(
        '<path d="M70.000,60.000 A20.000,20.000 0 1,1 36.927,44.864"'
        ' fill="#0000ff"/>'
        in svg.to_string(),
        (
            "arc_to: wide span (> pi) sets large-arc-flag 1, same hand-derived"
            " endpoint as fill_arc_aa's own"
        ),
    )


def test_fill_path_aa_handles_quad_and_cubic_commands() raises:
    var path = Path()
    path.move_to(0.0, 0.0)
    path.quad_curve_to(5.0, 10.0, 10.0, 0.0)
    path.cubic_curve_to(12.0, 5.0, 14.0, 5.0, 16.0, 0.0)
    var svg = SvgCanvas(100, 100)
    svg.fill_path_aa(path, Color(0, 0, 0))
    assert_true(
        '<path d="M0.000,0.000 Q5.000,10.000 10.000,0.000 C12.000,5.000'
        ' 14.000,5.000 16.000,0.000" fill="#000000"/>'
        in svg.to_string(),
        (
            "Q (quad) and C (cubic) commands map directly, same control-point"
            " order Path stores"
        ),
    )


def test_draw_text_left_align_maps_to_start_anchor() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.LEFT)
    assert_true(
        '<text x="10" y="20" font-size="12.000" font-family="sans-serif"'
        ' fill="#000000" text-anchor="start">hi</text>'
        in svg.to_string(),
        "TextAlign.LEFT -> text-anchor=start, SVG's own default anchor",
    )


def test_draw_text_center_align_maps_to_middle_anchor() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.CENTER)
    assert_true(
        'text-anchor="middle"' in svg.to_string(),
        "TextAlign.CENTER -> text-anchor=middle",
    )


def test_draw_text_right_align_maps_to_end_anchor() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.RIGHT)
    assert_true(
        'text-anchor="end"' in svg.to_string(),
        "TextAlign.RIGHT -> text-anchor=end",
    )


def test_draw_text_escapes_xml_special_characters() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(0, 0, "5 < 10 & 10 > 5", Color(0, 0, 0), 12.0, TextAlign.LEFT)
    assert_true(
        ">5 &lt; 10 &amp; 10 &gt; 5<" in svg.to_string(),
        (
            "<, &, > all escaped -- & escaped first so the other two don't get"
            " double-escaped"
        ),
    )


def test_draw_text_default_rotation_omits_transform_attribute() raises:
    # rotation's default (0.0) emits no transform attribute at all.
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.LEFT)
    assert_true(
        '<text x="10" y="20" font-size="12.000" font-family="sans-serif"'
        ' fill="#000000" text-anchor="start">hi</text>'
        in svg.to_string(),
        "rotation=0.0 (the default) -- no transform attribute at all",
    )


def test_draw_text_rotation_emits_hand_derived_rotate_transform() raises:
    # pi/2 radians -> exactly 90.0 degrees, 90.000 through
    # _format_svg_float. No sign flip relative to raster draw_text,
    # since raster space and SVG's viewport space both put y down.
    var svg = SvgCanvas(100, 100)
    svg.draw_text(
        10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.LEFT, rotation=pi / 2.0
    )
    assert_true(
        '<text x="10" y="20" font-size="12.000" font-family="sans-serif"'
        ' fill="#000000" text-anchor="start" transform="rotate(90.000 10'
        ' 20)">hi</text>'
        in svg.to_string(),
        (
            "rotate(<degrees> <x> <y>), rotating around the text's own anchor"
            " point"
        ),
    )


def test_draw_text_default_family_is_sans_serif() raises:
    # A call with no `family` argument still emits a real font-family
    # rather than leaving the viewer to its own undefined default.
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.LEFT)
    assert_true(
        'font-family="sans-serif"' in svg.to_string(),
        "default family is sans-serif",
    )


def test_draw_text_custom_family_is_emitted_verbatim() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(
        10,
        20,
        "hi",
        Color(0, 0, 0),
        12.0,
        TextAlign.LEFT,
        family="Georgia, serif",
    )
    assert_true(
        'font-family="Georgia, serif"' in svg.to_string(),
        (
            "a caller-supplied family value (a fallback stack here) is emitted"
            " as-is"
        ),
    )


def test_draw_text_family_containing_quotes_is_escaped() raises:
    # A real CSS font stack quotes any family name containing a space
    # (`"Helvetica Neue", Arial, sans-serif`), and `family` is the only
    # caller-supplied string this module puts inside a quoted
    # attribute -- everything else is internally generated, or goes
    # through _escape_xml_text into element content. An unescaped `"`
    # would close the attribute early and corrupt the markup, so this
    # checks _escape_xml_attr is actually wired in.
    var svg = SvgCanvas(100, 100)
    svg.draw_text(
        10,
        20,
        "hi",
        Color(0, 0, 0),
        12.0,
        TextAlign.LEFT,
        family='"Helvetica Neue", Arial',
    )
    assert_true(
        'font-family="&quot;Helvetica Neue&quot;, Arial"' in svg.to_string(),
        (
            "embedded double quotes in family are escaped, not left to corrupt"
            " the attribute"
        ),
    )


def test_draw_text_default_weight_omits_font_weight_attribute() raises:
    # weight's default (FontWeight.NORMAL) emits no font-weight
    # attribute, the same omit-at-default rotation gets above.
    var svg = SvgCanvas(100, 100)
    svg.draw_text(10, 20, "hi", Color(0, 0, 0), 12.0, TextAlign.LEFT)
    assert_true(
        "font-weight" not in svg.to_string(),
        (
            "weight=FontWeight.NORMAL (the default) -- no font-weight attribute"
            " at all"
        ),
    )


def test_draw_text_bold_weight_emits_font_weight_attribute() raises:
    var svg = SvgCanvas(100, 100)
    svg.draw_text(
        10,
        20,
        "hi",
        Color(0, 0, 0),
        12.0,
        TextAlign.LEFT,
        weight=FontWeight.BOLD,
    )
    assert_true(
        '<text x="10" y="20" font-size="12.000" font-family="sans-serif"'
        ' font-weight="bold" fill="#000000"'
        in svg.to_string(),
        (
            'weight=FontWeight.BOLD emits a literal font-weight="bold"'
            " attribute, positioned right after font-family"
        ),
    )


def test_to_string_wraps_body_in_svg_root_with_correct_dimensions() raises:
    var svg = SvgCanvas(320, 240)
    var s = svg.to_string()
    assert_true(
        '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="240"'
        ' viewBox="0 0 320 240">'
        in s,
        "root <svg> element carries the exact constructor dimensions",
    )
    assert_true(s.strip().endswith("</svg>"), "document is properly closed")


def test_annotated_group_wraps_elements_with_an_escaped_title() raises:
    # `<title>` as the first child of a `<g>` is what a browser shows
    # as a hover tooltip for everything in that group, which is the
    # point of the feature. The title is element content, so it takes
    # _escape_xml_text's escaping.
    var svg = SvgCanvas(100, 100)
    svg.begin_annotated_group("Q1 <profit> & loss")
    svg.fill_rect(0, 0, 10, 10, Color(1, 2, 3))
    svg.end_annotated_group()
    var s = svg.to_string()

    assert_true(
        "<g>\n<title>Q1 &lt;profit&gt; &amp; loss</title>\n" in s,
        "group opens with its escaped title",
    )
    assert_true(
        '<title>Q1 &lt;profit&gt; &amp; loss</title>\n<rect x="0"' in s,
        "the drawn element follows the title inside the group",
    )
    assert_true("</g>\n" in s, "the group is closed")


def test_drawing_after_end_annotated_group_is_outside_it() raises:
    # The scope has to actually end, or every later element inherits a
    # tooltip that does not belong to it.
    var svg = SvgCanvas(100, 100)
    svg.begin_annotated_group("inside")
    svg.fill_rect(0, 0, 10, 10, Color(1, 2, 3))
    svg.end_annotated_group()
    svg.fill_rect(20, 0, 10, 10, Color(4, 5, 6))
    var s = svg.to_string()

    assert_true(
        '</g>\n<rect x="20"' in s,
        "an element drawn after the group closes falls outside it",
    )
    assert_equal(s.count("<g>"), 1, "exactly one group was opened")
    assert_equal(s.count("</g>"), 1, "and exactly one was closed")


def test_opening_a_group_inside_one_closes_the_first() raises:
    # Groups do not nest. A second begin closes the first rather than
    # nesting, which keeps one flag as the whole state and keeps the
    # markup well formed however a caller pairs its calls.
    var svg = SvgCanvas(100, 100)
    svg.begin_annotated_group("first")
    svg.fill_rect(0, 0, 5, 5, Color(0, 0, 0))
    svg.begin_annotated_group("second")
    svg.fill_rect(10, 0, 5, 5, Color(0, 0, 0))
    svg.end_annotated_group()
    var s = svg.to_string()

    assert_true(
        '<rect x="0" y="0" width="5" height="5" fill="#000000"/>\n</g>' in s,
        "the first group closed before the second opened",
    )
    assert_equal(s.count("<g>"), 2, "two groups, not one nested in another")
    assert_equal(s.count("</g>"), 2, "both closed")


def test_an_unclosed_group_is_closed_by_to_string() raises:
    # A caller that forgets end_annotated_group would otherwise get a
    # document with an unbalanced <g>, which is malformed XML rather
    # than merely untidy -- so serializing closes it.
    var svg = SvgCanvas(100, 100)
    svg.begin_annotated_group("never closed")
    svg.fill_rect(0, 0, 10, 10, Color(1, 2, 3))
    var s = svg.to_string()

    assert_equal(s.count("<g>"), 1, "the group was opened")
    assert_equal(s.count("</g>"), 1, "and closed on serialization")
    assert_true("</g>\n</svg>" in s, "closed before the document ends")


def test_end_annotated_group_without_a_group_emits_nothing() raises:
    # A stray </g> is malformed, which is worse than ignoring an
    # unbalanced call -- and it matches Canvas.pop_clip treating an
    # unbalanced close as nothing to undo.
    var svg = SvgCanvas(100, 100)
    svg.end_annotated_group()
    svg.fill_rect(0, 0, 10, 10, Color(1, 2, 3))
    var s = svg.to_string()

    assert_equal(s.count("</g>"), 0, "no stray closing tag")
    assert_equal(s.count("<g>"), 0, "and no opening one either")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

"""Tests for draw_text_on_path (canvas/text/render.mojo) and the
arc-length parametrisation it places glyphs with
(`_ArcLengthPath` in canvas/path.mojo).

Most assertions here are on the *placements* rather than on pixels:
`_text_on_path_placements` is the whole of the feature that is layout,
and it reports each glyph's origin and the unit tangent it was turned
to, which are exactly the quantities to derive by hand. The pixel
assertions are the two properties placement alone cannot show -- that a
straight horizontal path renders what draw_text renders, byte for byte,
and that a curved one renders anything at all.

The exact numbers are DejaVu Sans at 64 px, as the kerning and ligature
tests in test_text.mojo use: 2048 units per em puts a design unit at
64/2048 = 1/32 px, so every advance and kerning adjustment below is an
exact binary fraction and the assertions are equalities.

Needs a "Sans"-resolvable system font, as test_text.mojo does.
"""

from std.math import pi
from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.path import Path
from canvas.text.font_cache import FontCache
from canvas.text.font_discovery import FontSlant, FontWeight
from canvas.text.render import (
    draw_text,
    draw_text_on_path,
    measure_text,
    TextAlign,
    _PlacedGlyph,
    _text_on_path_placements,
)

comptime BG = Color(255, 255, 255)
comptime FG = Color(200, 20, 20, 255)


def _placements(
    text: String,
    path: Path,
    size: Float64,
    offset: Float64,
    align: TextAlign,
    kerning: Bool,
    ligatures: Bool,
    mut cache: FontCache,
) raises -> List[_PlacedGlyph]:
    """`_text_on_path_placements` with this file's font choices filled
    in, so a call site reads as the four things it varies.
    """
    return _text_on_path_placements(
        text,
        path,
        size,
        offset,
        "Sans",
        FontSlant.NORMAL,
        FontWeight.NORMAL,
        align,
        kerning,
        ligatures,
        cache,
    )


def _horizontal(x0: Float64, x1: Float64, y: Float64) raises -> Path:
    var p = Path()
    p.move_to(x0, y)
    p.line_to(x1, y)
    return p^


def _assert_same_pixels(a: Canvas, b: Canvas, label: String) raises:
    assert_equal(a.width, b.width, label)
    assert_equal(a.height, b.height, label)
    for y in range(a.height):
        for x in range(a.width):
            var p = a.get_pixel(x, y)
            var q = b.get_pixel(x, y)
            if p.r != q.r or p.g != q.g or p.b != q.b or p.a != q.a:
                var at = label + " at " + String(x) + "," + String(y)
                assert_equal(p.r, q.r, at)
                assert_equal(p.g, q.g, at)
                assert_equal(p.b, q.b, at)
                assert_equal(p.a, q.a, at)


def _ink_count(c: Canvas, bg: Color) -> Int:
    var count = 0
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            if p.r != bg.r or p.g != bg.g or p.b != bg.b:
                count += 1
    return count


def test_horizontal_path_reproduces_draw_text_exactly() raises:
    # The equivalence the placement math is built to hold: a LEFT
    # string at offset 0 on the path (x0, y) -> (x1, y) is the same
    # string drawn by draw_text at (x0, y), pixel for pixel.
    #
    # It reduces exactly rather than nearly. The segment's unit tangent
    # is (1, 0) bit for bit -- dx/sqrt(dx*dx) with dy zero -- so the
    # sample at arc length d is (x0 + d, y) with no rounding, and
    # backing the glyph origin off half an advance recovers x0 + pen:
    # pen, the advance and the halved advance are all multiples of
    # 1/64 px here, small enough that adding and subtracting them is
    # exact. A tangent of exactly (1, 0) is an unrotated glyph, so it
    # goes through the same glyph mask cache draw_text uses, which is
    # the other half of "byte for byte" -- a cached composite and a
    # direct fill of one outline agree within a coverage step, not
    # exactly.
    var text = String("AVATAR ffi 42")

    var straight_cache = FontCache()
    var straight = Canvas(700, 140, BG)
    draw_text(straight, 20.0, 90.0, text, FG, 64.0, cache=straight_cache)

    var on_path_cache = FontCache()
    var on_path = Canvas(700, 140, BG)
    draw_text_on_path(
        on_path,
        _horizontal(20.0, 660.0, 90.0),
        text,
        FG,
        64.0,
        cache=on_path_cache,
    )

    assert_true(_ink_count(straight, BG) > 0, "the reference drew something")
    _assert_same_pixels(straight, on_path, "horizontal path vs draw_text")


def test_horizontal_path_under_a_translation_matches_draw_text() raises:
    # A pure canvas translation moves the anchor and leaves every glyph
    # at its size and orientation, so it folds into the placement and
    # the cache still applies -- the rule draw_text follows.
    var text = String("Shifted")

    var reference = Canvas(400, 140, BG)
    draw_text(reference, 55.0, 110.0, text, FG, 48.0)

    var shifted = Canvas(400, 140, BG)
    shifted.translate(35.0, 20.0)
    draw_text_on_path(shifted, _horizontal(20.0, 380.0, 90.0), text, FG, 48.0)
    shifted.reset_transform()

    assert_true(_ink_count(reference, BG) > 0, "the reference drew something")
    _assert_same_pixels(reference, shifted, "translated path vs draw_text")


def test_vertical_path_turns_every_glyph_a_quarter_turn() raises:
    # A path running straight down has unit tangent (0, 1) exactly:
    # dx is 0.0, so tx is 0.0/len and ty is len/len. Every glyph's
    # baseline runs down the page, a quarter turn clockwise on this
    # y-down canvas.
    var cache = FontCache()
    var down = Path()
    down.move_to(60.0, 20.0)
    down.line_to(60.0, 400.0)
    var placed = _placements(
        "Hello", down, 64.0, 0.0, TextAlign.LEFT, True, True, cache
    )
    assert_equal(len(placed), 5, "five inked glyphs")
    for i in range(len(placed)):
        assert_equal(placed[i].tx, 0.0, "tangent x is exactly zero")
        assert_equal(placed[i].ty, 1.0, "tangent y is exactly one")
        assert_equal(placed[i].x, 60.0, "every origin sits on the line")

    # And each origin is its pen position down the line, since the
    # tangent points that way: the first glyph's origin is the path's
    # start, the second is one "H" advance below it. DejaVu Sans's "H"
    # advance is 1540 units = 48.125 px.
    assert_equal(placed[0].y, 20.0)
    assert_equal(measure_text("H", 64.0, cache=cache).advance, 48.125)
    assert_equal(placed[1].y, 68.125)

    # Rendered, the block is taller than it is wide, which the same
    # string drawn straight is not.
    var turned = Canvas(160, 440, BG)
    draw_text_on_path(turned, down, "Hello", FG, 64.0, cache=cache)
    assert_true(_ink_count(turned, BG) > 0, "a turned string still renders")


def test_semicircle_puts_the_middle_glyph_on_the_apex() raises:
    # A semicircle from angle pi to 2*pi, center (300, 320), radius
    # 200: it starts at (100, 320), rises over the apex (300, 120) --
    # y is down, so 3*pi/2 is the top -- and ends at (500, 320).
    #
    # "OOO" centered at half the path's length puts the middle "O"
    # exactly on the string's center, since all three glyphs have the
    # same advance, and the string's center is the apex. The glyph
    # origin is backed off half an advance along the tangent, which is
    # horizontal there, so it sits half an advance to the left of the
    # apex.
    var cache = FontCache()
    var advance = measure_text("O", 64.0, cache=cache).advance
    var half = advance / 2.0

    var arc = Path()
    arc.move_to(100.0, 320.0)
    arc.arc_to(300.0, 320.0, 200.0, pi, 2.0 * pi)

    # The flattened semicircle is a chord polygon inscribed in the true
    # circle at about 1 px spacing (628 steps at this radius), so its
    # length is a shade under pi * 200 = 628.3 and its apex a shade
    # below the true one. Both are well inside a tenth of a pixel.
    var length = pi * 200.0
    var placed = _placements(
        "OOO", arc, 64.0, length / 2.0, TextAlign.CENTER, True, True, cache
    )
    assert_equal(len(placed), 3, "three inked glyphs")

    ref middle = placed[1]
    assert_true(
        middle.ty > -0.01 and middle.ty < 0.01,
        "the tangent at the apex is horizontal",
    )
    assert_true(middle.tx > 0.999, "and points along +x")
    assert_true(
        middle.x > 300.0 - half - 0.5 and middle.x < 300.0 - half + 0.5,
        (
            "the middle glyph's center is on the apex, its origin half an"
            " advance left of it"
        ),
    )
    assert_true(
        middle.y > 120.0 - 0.5 and middle.y < 120.0 + 0.5,
        "and its baseline is on the apex",
    )

    # The outer two lean the opposite ways: the first climbs (its
    # tangent points up the page, ty negative) and the last descends.
    assert_true(placed[0].ty < -0.1, "the first glyph is on the rising side")
    assert_true(placed[2].ty > 0.1, "the last is on the falling side")

    var c = Canvas(600, 400, BG)
    draw_text_on_path(
        c,
        arc,
        "OOO",
        FG,
        64.0,
        length / 2.0,
        align=TextAlign.CENTER,
        cache=cache,
    )
    assert_true(_ink_count(c, BG) > 0, "text on an arc renders")


def test_glyphs_past_the_end_of_the_path_are_dropped() raises:
    # SVG's textPath rule: a glyph whose center falls past either end
    # of the path is not drawn, rather than clamped to the end where it
    # would pile up on its neighbors.
    var cache = FontCache()

    # "AAAAAAAA" at 64 px: a 1401-unit "A" advances 43.78125 px and the
    # AA pair kerns +57 units = +1.78125 px, so the pen steps 45.5625
    # px per glyph and glyph i's center is at 45.5625 * i + 21.890625.
    # On a 100 px path that is on the path for i = 0 (21.89) and i = 1
    # (67.45) and past it for i = 2 (113.02).
    assert_equal(measure_text("A", 64.0, cache=cache).advance, 43.78125)
    assert_equal(measure_text("AA", 64.0, cache=cache).advance, 89.34375)
    var short = _horizontal(20.0, 120.0, 90.0)
    var placed = _placements(
        "AAAAAAAA", short, 64.0, 0.0, TextAlign.LEFT, True, True, cache
    )
    assert_equal(len(placed), 2, "two centers land on a 100 px path")
    assert_equal(placed[0].x, 20.0)
    assert_equal(placed[1].x, 65.5625)

    # A negative offset drops from the front by the same rule: at
    # offset -50 the first glyph's center is at -28.11, off the front,
    # and the string starts at its second glyph, whose center is at
    # 17.45.
    var from_front = _placements(
        "AAAAAAAA", short, 64.0, -50.0, TextAlign.LEFT, True, True, cache
    )
    assert_equal(len(from_front), 2, "one dropped in front, the rest past")
    assert_equal(from_front[0].x, 15.5625, "20 - 50 + 45.5625")

    # Pushed past the end entirely, nothing is drawn at all.
    var empty = Canvas(200, 140, BG)
    draw_text_on_path(empty, short, "AAAAAAAA", FG, 64.0, 500.0, cache=cache)
    assert_equal(_ink_count(empty, BG), 0, "everything past the end")


def test_kerning_applies_on_a_curve() raises:
    # The same pair adjustment straight text gets: DejaVu Sans kerns
    # "AV" by -131 units = -4.09375 px, so on a horizontal path the
    # "V" origin is that much left of the plain sum of advances.
    # A 1401-unit "A" advances 43.78125 px, so the unkerned "V" origin
    # is at 20 + 43.78125 and the kerned one at 20 + 39.6875.
    var cache = FontCache()
    var line = _horizontal(20.0, 400.0, 90.0)

    var kerned = _placements(
        "AV", line, 64.0, 0.0, TextAlign.LEFT, True, True, cache
    )
    var plain = _placements(
        "AV", line, 64.0, 0.0, TextAlign.LEFT, False, True, cache
    )
    assert_equal(len(kerned), 2)
    assert_equal(plain[1].x, 63.78125, "unkerned: 20 + 1401 units")
    assert_equal(kerned[1].x, 59.6875, "kerned: 20 + (1401 - 131) units")


def test_ligatures_apply_on_a_curve() raises:
    # "ffi" is one glyph where the font has the ligature, so the same
    # string places three glyphs on the path unligated and one
    # ligated -- the substitution runs in `_shape_line`, before
    # anything is placed, exactly as it does for straight text.
    var cache = FontCache()
    var line = _horizontal(20.0, 400.0, 90.0)

    var ligated = _placements(
        "ffi", line, 64.0, 0.0, TextAlign.LEFT, True, True, cache
    )
    var apart = _placements(
        "ffi", line, 64.0, 0.0, TextAlign.LEFT, True, False, cache
    )
    assert_equal(len(ligated), 1, "one ligature glyph")
    assert_equal(len(apart), 3, "three characters")

    # Both start at the path's start, and the ligated one is narrower:
    # the "ffi" glyph advances 1980 units = 61.875 px against the
    # 2011 units = 62.84375 px its three characters do.
    assert_equal(ligated[0].x, 20.0)
    assert_equal(apart[0].x, 20.0)
    assert_equal(measure_text("ffi", 64.0, cache=cache).advance, 61.875)
    assert_equal(
        measure_text("ffi", 64.0, ligatures=False, cache=cache).advance,
        62.84375,
    )


def test_align_places_the_whole_string_against_the_offset() raises:
    # LEFT starts the string at `offset`, CENTER centers its total
    # advance about it, RIGHT ends it there. "AV" kerns to 83.46875 px
    # of advance (test_text.mojo derives it), so against offset 200 on
    # a horizontal path starting at x = 20 the three first-glyph
    # origins are 220, 220 - 41.734375 = 178.265625, and
    # 220 - 83.46875 = 136.53125.
    var cache = FontCache()
    var line = _horizontal(20.0, 500.0, 90.0)
    assert_equal(measure_text("AV", 64.0, cache=cache).advance, 83.46875)

    var left = _placements(
        "AV", line, 64.0, 200.0, TextAlign.LEFT, True, True, cache
    )
    var center = _placements(
        "AV", line, 64.0, 200.0, TextAlign.CENTER, True, True, cache
    )
    var right = _placements(
        "AV", line, 64.0, 200.0, TextAlign.RIGHT, True, True, cache
    )
    assert_equal(left[0].x, 220.0)
    assert_equal(center[0].x, 178.265625)
    assert_equal(right[0].x, 136.53125)


def test_empty_and_whitespace_only_strings_draw_nothing() raises:
    var cache = FontCache()
    var line = _horizontal(20.0, 400.0, 90.0)

    var blank = Canvas(420, 140, BG)
    draw_text_on_path(blank, line, "", FG, 64.0, cache=cache)
    assert_equal(_ink_count(blank, BG), 0, "empty string")

    draw_text_on_path(blank, line, "   ", FG, 64.0, cache=cache)
    assert_equal(_ink_count(blank, BG), 0, "whitespace has no ink to place")


def test_zero_length_path_draws_nothing() raises:
    # Every segment is dropped as having no direction, so the path has
    # no length and no glyph center can land on it.
    var cache = FontCache()
    var degenerate = Path()
    degenerate.move_to(50.0, 50.0)
    degenerate.line_to(50.0, 50.0)

    var c = Canvas(200, 100, BG)
    draw_text_on_path(c, degenerate, "text", FG, 32.0, cache=cache)
    assert_equal(_ink_count(c, BG), 0, "a path with no length")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

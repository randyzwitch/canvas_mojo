"""`fill_mesh`: adjacent faces drawn as one shape, seam-free along
shared edges, anti-aliased at the silhouette, in painter's order, on
every backend, and byte-identical whether drawn now, through a batch
or through a supersampled region.

The seam is the reason the primitive exists, so the first test
measures it the way #425 did -- count the interior pixels off the fill
color -- and requires zero where two per-face fills gave 52.
"""

from std.math import cos, pi, sin
from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.geometry import FPoint
from canvas.path import Path
from canvas.resize import downsample
from canvas.color import ColorSpace
from canvas.shapes.mesh import fill_mesh, fill_mesh_shaded
from canvas.shapes.polygon_fill import fill_polygon_aa
from canvas.vector.pdf import PdfCanvas
from canvas.vector.svg import SvgCanvas

comptime BG = Color(255, 255, 255)
comptime INK = Color(40, 90, 160)


def _square(x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> List[FPoint]:
    """Four corners; `_two_faces` splits them along the diagonal."""
    var pts: List[FPoint] = [
        FPoint(x0, y0),
        FPoint(x1, y0),
        FPoint(x1, y1),
        FPoint(x0, y1),
    ]
    return pts^


def _two_faces() -> List[Int]:
    var f: List[Int] = [0, 1, 2, 0, 2, 3]
    return f^


def _grid(
    nx: Int, ny: Int, x0: Float64, y0: Float64, cell: Float64
) -> Tuple[List[FPoint], List[Int]]:
    """An nx by ny grid of cells, each split into two triangles: the
    shape of a surface plot, with a shared edge between every pair of
    neighbours and a diagonal through every cell."""
    var pts = List[FPoint]()
    for j in range(ny + 1):
        for i in range(nx + 1):
            pts.append(FPoint(x0 + Float64(i) * cell, y0 + Float64(j) * cell))
    var faces = List[Int]()
    for j in range(ny):
        for i in range(nx):
            var a = j * (nx + 1) + i
            var b = a + 1
            var c = a + nx + 1
            var d = c + 1
            faces.append(a)
            faces.append(b)
            faces.append(d)
            faces.append(a)
            faces.append(d)
            faces.append(c)
    return (pts^, faces^)


def _same_color(n: Int, color: Color) -> List[Color]:
    var cols = List[Color]()
    for _ in range(n):
        cols.append(color)
    return cols^


def _off_fill(
    c: Canvas, x0: Int, y0: Int, x1: Int, y1: Int, ink: Color
) -> Tuple[Int, Int]:
    """Pixels in [x0, x1) x [y0, y1) whose red channel is not the
    fill's, and the worst difference: the #425 measurement."""
    var off = 0
    var worst = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            var d = abs(Int(c.get_pixel(x, y).r) - Int(ink.r))
            if d > 0:
                off += 1
                if d > worst:
                    worst = d
    return (off, worst)


def _assert_same(a: Canvas, b: Canvas, label: String) raises:
    assert_equal(a.width, b.width, label + " (width)")
    assert_equal(a.height, b.height, label + " (height)")
    for y in range(a.height):
        for x in range(a.width):
            var p = a.get_pixel(x, y)
            var q = b.get_pixel(x, y)
            var at = label + " at (" + String(x) + ", " + String(y) + ")"
            assert_equal(p.r, q.r, at + " (r)")
            assert_equal(p.g, q.g, at + " (g)")
            assert_equal(p.b, q.b, at + " (b)")
            assert_equal(p.a, q.a, at + " (a)")


def test_two_faces_sharing_a_diagonal_have_no_seam() raises:
    """The measurement from #425: two per-face fills left 52 interior
    pixels off the fill color along the shared diagonal, the worst by
    53 levels. The mesh must leave none."""
    var c = Canvas(100, 100, BG)
    fill_mesh(c, _square(20, 20, 80, 80), _two_faces(), _same_color(2, INK))
    var r = _off_fill(c, 24, 24, 76, 76, INK)
    assert_equal(r[0], 0, "interior pixels off the fill color")
    assert_equal(r[1], 0, "worst channel error")
    # And it is still a shape with an anti-aliased outline: outside is
    # untouched, the edge column is partly covered.
    assert_equal(c.get_pixel(10, 10).r, 255, "outside the mesh")
    var edge = Int(c.get_pixel(20, 50).r)
    assert_true(
        edge > Int(INK.r) and edge < 255, "the silhouette is anti-aliased"
    )


def test_a_surface_grid_has_no_seam_anywhere() raises:
    """A 12x9 grid of cells, two triangles each: 216 faces, a shared
    edge between every neighbour and a diagonal through every cell.
    Nothing inside may differ from the fill."""
    var g = _grid(12, 9, 10.5, 10.25, 7.3)
    var c = Canvas(120, 100, BG)
    fill_mesh(c, g[0], g[1], _same_color(len(g[1]) // 3, INK))
    var r = _off_fill(c, 13, 13, 96, 74, INK)
    assert_equal(r[0], 0, "interior pixels off the fill color")


def test_translucent_faces_do_not_double_blend_along_a_shared_edge() raises:
    """A shared edge gives each sub-sample to one face, so a
    translucent mesh is one translucent layer: the value along the
    diagonal is the same as anywhere inside."""
    var ink = Color(40, 90, 160, 110)
    var c = Canvas(100, 100, BG)
    fill_mesh(c, _square(20, 20, 80, 80), _two_faces(), _same_color(2, ink))
    var inside = c.get_pixel(30, 60)
    for k in range(25, 75):
        var on_diag = c.get_pixel(k, k)
        assert_equal(on_diag.r, inside.r, "diagonal r at " + String(k))
        assert_equal(on_diag.g, inside.g, "diagonal g at " + String(k))
        assert_equal(on_diag.b, inside.b, "diagonal b at " + String(k))


def test_one_face_agrees_with_the_polygon_fill_along_its_outline() raises:
    """A mesh of one triangle is an anti-aliased triangle. The mesh
    samples a 4x4 grid per pixel and the polygon fill's sweep is its
    own algorithm, so along the outline they agree to within one
    coverage level, and they must agree exactly everywhere else: a
    pixel the polygon fill calls fully inside or fully outside is one
    the mesh calls the same."""
    var tri: List[FPoint] = [
        FPoint(12.3, 8.7),
        FPoint(71.1, 20.4),
        FPoint(33.6, 66.9),
    ]
    var one: List[Int] = [0, 1, 2]
    var a = Canvas(80, 80, BG)
    fill_mesh(a, tri, one, _same_color(1, INK))
    var b = Canvas(80, 80, BG)
    fill_polygon_aa(b, tri, INK)
    var worst = 0
    var off_outline = 0
    var differing = 0
    for y in range(80):
        for x in range(80):
            var got = Int(a.get_pixel(x, y).r)
            var want = Int(b.get_pixel(x, y).r)
            var d = abs(got - want)
            if d == 0:
                continue
            differing += 1
            if d > worst:
                worst = d
            # A difference is only allowed where the reference is
            # itself partially covered.
            if want == Int(INK.r) or want == 255:
                off_outline += 1
    assert_equal(off_outline, 0, "differences away from the outline")
    # One sub-sample of sixteen is one alpha step of about 255 / 16,
    # which after the blend's rounding is at most 16 levels of red.
    assert_true(worst <= 16, "worst difference " + String(worst))
    assert_true(
        differing > 0, "the outline is where the two sample differently"
    )


def test_later_faces_cover_earlier_ones() raises:
    """Painter's order: a depth-sorted mesh relies on a later face
    replacing what an earlier one drew where they overlap."""
    var pts: List[FPoint] = [
        FPoint(10, 10),
        FPoint(60, 10),
        FPoint(60, 60),
        FPoint(10, 60),
        FPoint(30, 30),
        FPoint(90, 30),
        FPoint(90, 90),
        FPoint(30, 90),
    ]
    var faces: List[Int] = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
    var red = Color(200, 30, 30)
    var blue = Color(30, 30, 200)
    var cols: List[Color] = [red, red, blue, blue]
    var c = Canvas(100, 100, BG)
    fill_mesh(c, pts, faces, cols)
    assert_equal(c.get_pixel(20, 20).r, red.r, "only the first square")
    assert_equal(
        c.get_pixel(45, 45).b, blue.b, "overlap goes to the later face"
    )
    assert_equal(c.get_pixel(80, 80).b, blue.b, "only the second square")


def test_winding_and_degenerate_faces() raises:
    """A face wound the other way draws the same; a face of zero area
    draws nothing and does not disturb its neighbours."""
    var fwd = Canvas(60, 60, BG)
    fill_mesh(fwd, _square(10, 10, 50, 50), _two_faces(), _same_color(2, INK))
    var rev_faces: List[Int] = [2, 1, 0, 3, 2, 0]
    var rev = Canvas(60, 60, BG)
    fill_mesh(rev, _square(10, 10, 50, 50), rev_faces, _same_color(2, INK))
    _assert_same(fwd, rev, "reversed winding")
    var degenerate: List[Int] = [0, 1, 2, 0, 2, 3, 1, 1, 1]
    var deg = Canvas(60, 60, BG)
    fill_mesh(deg, _square(10, 10, 50, 50), degenerate, _same_color(3, INK))
    _assert_same(fwd, deg, "a zero-area face")


def test_clip_and_transform_apply() raises:
    """The mesh lands under the clip and through the transform like
    any primitive: a translate-and-scale on the canvas must equal the
    same vertices pre-transformed, and a clip must cut it."""
    var direct = Canvas(100, 100, BG)
    fill_mesh(
        direct, _square(30, 20, 90, 80), _two_faces(), _same_color(2, INK)
    )
    var xf = Canvas(100, 100, BG)
    xf.save()
    xf.translate(30.0, 20.0)
    xf.scale(2.0, 2.0)
    fill_mesh(xf, _square(0, 0, 30, 30), _two_faces(), _same_color(2, INK))
    xf.restore()
    _assert_same(direct, xf, "translate and scale")

    var clipped = Canvas(100, 100, BG)
    clipped.push_clip(40, 40, 30, 30)
    fill_mesh(
        clipped, _square(30, 20, 90, 80), _two_faces(), _same_color(2, INK)
    )
    clipped.pop_clip()
    assert_equal(
        clipped.get_pixel(35, 25).r, 255, "outside the clip is untouched"
    )
    assert_equal(clipped.get_pixel(50, 50).r, INK.r, "inside the clip is drawn")

    # A rotation turns the clip into a mask and the mesh through the
    # matrix; the pixels must equal the rotated vertices drawn plain.
    var rot = Canvas(100, 100, BG)
    rot.save()
    rot.translate(50.0, 50.0)
    rot.rotate(pi / 6.0)
    fill_mesh(rot, _square(-20, -20, 20, 20), _two_faces(), _same_color(2, INK))
    rot.restore()
    var pre = List[FPoint]()
    var sq = _square(-20, -20, 20, 20)
    for i in range(4):
        var x = sq[i].x
        var y = sq[i].y
        pre.append(
            FPoint(
                50.0 + x * cos(pi / 6.0) - y * sin(pi / 6.0),
                50.0 + x * sin(pi / 6.0) + y * cos(pi / 6.0),
            )
        )
    var plain = Canvas(100, 100, BG)
    fill_mesh(plain, pre, _two_faces(), _same_color(2, INK))
    _assert_same(rot, plain, "rotation")


def test_a_batch_draws_the_same_bytes() raises:
    """Inside `begin_batch` the call records as one op and replays
    per band; the bytes must match drawing it now, at one worker and
    at every worker the machine offers."""
    var g = _grid(10, 8, 5.5, 4.25, 9.1)
    var cols = List[Color]()
    for i in range(len(g[1]) // 3):
        cols.append(
            Color(
                UInt8(40 + (i * 7) % 180),
                90,
                UInt8(60 + (i * 11) % 150),
                UInt8(150 + (i * 5) % 105),
            )
        )
    var now = Canvas(110, 90, BG)
    fill_mesh(now, g[0], g[1], cols)
    for workers in range(0, 3):
        var batched = Canvas(110, 90, BG)
        batched.set_max_workers(workers)
        batched.begin_batch()
        batched.fill_rect(0, 0, 40, 40, Color(230, 230, 230))
        fill_mesh(batched, g[0], g[1], cols)
        batched.fill_circle_aa(80.0, 70.0, 6.0, Color(200, 40, 40, 120))
        batched.end_batch()
        var direct = Canvas(110, 90, BG)
        direct.set_max_workers(workers)
        direct.fill_rect(0, 0, 40, 40, Color(230, 230, 230))
        fill_mesh(direct, g[0], g[1], cols)
        direct.fill_circle_aa(80.0, 70.0, 6.0, Color(200, 40, 40, 120))
        _assert_same(
            direct, batched, "batch at " + String(workers) + " workers"
        )
    _ = len(now.pixels)


def test_a_supersampled_region_matches_the_two_step_recipe() raises:
    """Through a region the mesh records in the enlarged space and
    replays a band at a time; the bytes must equal drawing it into a
    three-times canvas and downsampling, the recipe the region
    replaces."""
    comptime W = 90
    comptime H = 70
    comptime F = 3
    var g = _grid(8, 6, 6.5, 5.25, 9.7)
    var cols = _same_color(len(g[1]) // 3, Color(40, 90, 160, 200))
    var big = Canvas(W * F, H * F, BG)
    big.save()
    big.translate(Float64(F - 1) / 2.0, Float64(F - 1) / 2.0)
    big.scale(Float64(F), Float64(F))
    big.push_clip(8, 8, 70, 50)
    fill_mesh(big, g[0], g[1], cols)
    big.pop_clip()
    big.restore()
    var want = downsample(big, F)
    var got = Canvas(W, H, BG)
    got.begin_supersampled(F, BG)
    got.push_clip(8, 8, 70, 50)
    fill_mesh(got, g[0], g[1], cols)
    got.pop_clip()
    got.end_supersampled()
    _assert_same(want, got, "region")


def test_validation_raises_on_every_backend() raises:
    """A face silently dropped from a surface is a hole nobody
    reported, so a bad mesh raises everywhere rather than drawing the
    part that checks out."""
    var pts = _square(0, 0, 10, 10)
    var short_faces: List[Int] = [0, 1]
    var bad_index: List[Int] = [0, 1, 7]
    var good: List[Int] = [0, 1, 2]
    var two = _same_color(2, INK)
    var one = _same_color(1, INK)
    var raised = 0
    var c = Canvas(20, 20, BG)
    var s = SvgCanvas(20, 20)
    var p = PdfCanvas(20, 20)
    try:
        fill_mesh(c, pts, short_faces, one)
    except:
        raised += 1
    try:
        fill_mesh(c, pts, bad_index, one)
    except:
        raised += 1
    try:
        fill_mesh(c, pts, good, two)
    except:
        raised += 1
    try:
        s.fill_mesh(pts, bad_index, one)
    except:
        raised += 1
    try:
        s.fill_mesh(pts, good, two)
    except:
        raised += 1
    try:
        p.fill_mesh(pts, bad_index, one)
    except:
        raised += 1
    try:
        p.fill_mesh(pts, good, two)
    except:
        raised += 1
    assert_equal(raised, 7, "every bad mesh raises on every backend")
    # And a good one still draws after the failures.
    fill_mesh(c, pts, good, one)
    assert_equal(c.get_pixel(3, 2).r, INK.r, "drawn after a rejected call")


def test_vector_backends_emit_one_element_per_face() raises:
    """SVG: a `<path>` per face, stroked in its own color when opaque
    and unstroked when translucent. PDF: a fill-and-stroke per opaque
    face and a fill per translucent one."""
    var pts = _square(10, 10, 50, 50)
    var s = SvgCanvas(60, 60)
    s.fill_mesh(pts, _two_faces(), _same_color(2, INK))
    var svg = s.to_string()
    assert_equal(svg.count("<path"), 2, "one path per face")
    assert_equal(svg.count('stroke="#285aa0"'), 2, "stroked in the face color")
    var t = SvgCanvas(60, 60)
    t.fill_mesh(pts, _two_faces(), _same_color(2, Color(40, 90, 160, 120)))
    var tsvg = t.to_string()
    assert_equal(tsvg.count("<path"), 2, "one path per translucent face")
    assert_equal(
        tsvg.count("stroke-width"), 0, "a translucent face is not stroked"
    )
    assert_equal(tsvg.count("fill-opacity"), 2, "its alpha is written")

    var p = PdfCanvas(60, 60)
    p.fill_mesh(pts, _two_faces(), _same_color(2, INK))
    var pdf = p.content()
    assert_equal(pdf.count("h B Q"), 2, "opaque faces fill and stroke")
    assert_equal(pdf.count("RG 0 w"), 2, "in their own color, hairline")
    var q = PdfCanvas(60, 60)
    q.fill_mesh(pts, _two_faces(), _same_color(2, Color(40, 90, 160, 120)))
    var qpdf = q.content()
    assert_equal(qpdf.count("h f Q"), 2, "translucent faces fill only")
    assert_equal(qpdf.count("h B Q"), 0, "and do not stroke")


def test_repeated_renders_agree() raises:
    """Twelve renders of the same mesh through a region must agree
    with each other: a band that reads another's rows shows up here
    as a nondeterministic pixel, not as a wrong one (#412)."""
    var g = _grid(9, 7, 4.5, 3.25, 8.3)
    var cols = _same_color(len(g[1]) // 3, Color(40, 90, 160, 180))
    var first = Canvas(90, 70, BG)
    first.begin_supersampled(2, BG)
    fill_mesh(first, g[0], g[1], cols)
    first.end_supersampled()
    for k in range(12):
        var again = Canvas(90, 70, BG)
        again.begin_supersampled(2, BG)
        fill_mesh(again, g[0], g[1], cols)
        again.end_supersampled()
        _assert_same(first, again, "render " + String(k))


def test_shaded_interpolates_to_the_scalar_reference() raises:
    """A triangle with a red, a green and a blue corner: every fully
    covered interior pixel must hold the barycentric mix of the three
    at the pixel's centre, computed here outside the rasterizer. The
    mean of sixteen sub-samples of an affine function is its value at
    the centre, so the only slack is per-sub-sample rounding."""
    var a = FPoint(8.0, 10.0)
    var b = FPoint(88.0, 18.0)
    var c = FPoint(40.0, 86.0)
    var pts: List[FPoint] = [a, b, c]
    var one: List[Int] = [0, 1, 2]
    var cols: List[Color] = [
        Color(255, 0, 0),
        Color(0, 255, 0),
        Color(0, 0, 255),
    ]
    var cv = Canvas(100, 100, BG)
    fill_mesh_shaded(cv, pts, one, cols)
    var area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    var checked = 0
    var worst = 0
    for y in range(100):
        for x in range(100):
            var p = cv.get_pixel(x, y)
            if p.a != 255:
                continue
            var px = Float64(x)
            var py = Float64(y)
            var wa = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) / area
            var wb = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) / area
            var wc = 1.0 - wa - wb
            # Only pixels whose whole square is inside: the reference
            # is the interior mix, not a partially covered edge.
            if wa < 0.02 or wb < 0.02 or wc < 0.02:
                continue
            if p.r == 255 and p.g == 255 and p.b == 255:
                continue
            var er = Int(wa * 255.0 + 0.5)
            var eg = Int(wb * 255.0 + 0.5)
            var eb = Int(wc * 255.0 + 0.5)
            var d = max(
                abs(Int(p.r) - er), max(abs(Int(p.g) - eg), abs(Int(p.b) - eb))
            )
            if d > worst:
                worst = d
            checked += 1
    assert_true(checked > 1500, "interior pixels checked: " + String(checked))
    assert_true(worst <= 2, "worst channel error " + String(worst))


def test_shaded_with_equal_corners_is_the_flat_mesh() raises:
    """A face whose three corners share a color must come out exactly
    as `fill_mesh` draws it: same pixels, same silhouette."""
    var g = _grid(6, 5, 7.5, 6.25, 11.3)
    var per_vertex = _same_color(len(g[0]), Color(40, 90, 160, 210))
    var per_face = _same_color(len(g[1]) // 3, Color(40, 90, 160, 210))
    var flat = Canvas(90, 80, BG)
    fill_mesh(flat, g[0], g[1], per_face)
    var shaded = Canvas(90, 80, BG)
    fill_mesh_shaded(shaded, g[0], g[1], per_vertex)
    _assert_same(flat, shaded, "equal corners")


def test_shaded_interpolates_in_the_canvas_color_space() raises:
    """Black to white across a face: halfway is 128 when the canvas
    mixes bytes and 188 when it mixes linear light, the same rule
    source-over follows on the same canvas."""
    var pts: List[FPoint] = [
        FPoint(0, 0),
        FPoint(100, 0),
        FPoint(100, 60),
        FPoint(0, 60),
    ]
    var cols: List[Color] = [
        Color(0, 0, 0),
        Color(255, 255, 255),
        Color(255, 255, 255),
        Color(0, 0, 0),
    ]
    var srgb = Canvas(100, 60, BG)
    fill_mesh_shaded(srgb, pts, _two_faces(), cols)
    var mid_srgb = Int(srgb.get_pixel(50, 30).r)
    assert_true(abs(mid_srgb - 128) <= 2, "sRGB midpoint " + String(mid_srgb))
    var lin = Canvas(100, 60, BG)
    lin.set_color_space(ColorSpace.LINEAR)
    fill_mesh_shaded(lin, pts, _two_faces(), cols)
    var mid_lin = Int(lin.get_pixel(50, 30).r)
    assert_true(abs(mid_lin - 188) <= 2, "linear midpoint " + String(mid_lin))


def test_shaded_faces_are_continuous_across_a_shared_edge() raises:
    """Blue on the left corners, red on the right: the mix is linear
    in x on both triangles of the square, so every row reads the same
    and nothing changes where the diagonal crosses it."""
    var pts = _square(10, 10, 90, 70)
    var cols: List[Color] = [
        Color(0, 0, 255),
        Color(255, 0, 0),
        Color(255, 0, 0),
        Color(0, 0, 255),
    ]
    var c = Canvas(100, 80, BG)
    fill_mesh_shaded(c, pts, _two_faces(), cols)
    for x in range(14, 86):
        var top = c.get_pixel(x, 20)
        var bottom = c.get_pixel(x, 60)
        assert_true(
            abs(Int(top.r) - Int(bottom.r)) <= 1,
            "r differs between rows at " + String(x),
        )
        assert_true(
            abs(Int(top.b) - Int(bottom.b)) <= 1,
            "b differs between rows at " + String(x),
        )
        if x > 14:
            var left = c.get_pixel(x - 1, 20)
            assert_true(
                Int(top.r) >= Int(left.r),
                "red must not decrease at " + String(x),
            )


def test_shaded_batch_and_region_match_drawing_now() raises:
    var g = _grid(8, 6, 6.5, 5.25, 9.7)
    var cols = List[Color]()
    for i in range(len(g[0])):
        cols.append(
            Color(
                UInt8((i * 37) % 256),
                UInt8((i * 91) % 256),
                UInt8(80 + (i * 13) % 170),
            )
        )
    var now = Canvas(90, 70, BG)
    fill_mesh_shaded(now, g[0], g[1], cols)
    var batched = Canvas(90, 70, BG)
    batched.begin_batch()
    fill_mesh_shaded(batched, g[0], g[1], cols)
    batched.end_batch()
    _assert_same(now, batched, "batch")

    comptime F = 3
    var big = Canvas(90 * F, 70 * F, BG)
    big.save()
    big.translate(Float64(F - 1) / 2.0, Float64(F - 1) / 2.0)
    big.scale(Float64(F), Float64(F))
    fill_mesh_shaded(big, g[0], g[1], cols)
    big.restore()
    var want = downsample(big, F)
    var got = Canvas(90, 70, BG)
    got.begin_supersampled(F, BG)
    fill_mesh_shaded(got, g[0], g[1], cols)
    got.end_supersampled()
    _assert_same(want, got, "region")


def test_shaded_validation_and_vector_backends() raises:
    """A color count that is not one per vertex raises everywhere.
    SVG emits each face flat at the mean of its corners, documented as
    the backend's limit; PDF emits a Type 4 shading stream, twelve
    bytes per vertex entry, and paints it with `sh`."""
    var pts = _square(10, 10, 50, 50)
    var cols: List[Color] = [
        Color(0, 0, 255),
        Color(255, 0, 0),
        Color(255, 0, 0),
        Color(0, 0, 255),
    ]
    var wrong = _same_color(2, INK)
    var raised = 0
    var c = Canvas(60, 60, BG)
    var s = SvgCanvas(60, 60)
    var p = PdfCanvas(60, 60)
    try:
        fill_mesh_shaded(c, pts, _two_faces(), wrong)
    except:
        raised += 1
    try:
        s.fill_mesh_shaded(pts, _two_faces(), wrong)
    except:
        raised += 1
    try:
        p.fill_mesh_shaded(pts, _two_faces(), wrong)
    except:
        raised += 1
    assert_equal(raised, 3, "one color per vertex, on every backend")

    s.fill_mesh_shaded(pts, _two_faces(), cols)
    var svg = s.to_string()
    assert_equal(svg.count("<path"), 2, "one path per face")
    # Face (0, 1, 2) is blue, red, red: (170, 0, 85). Face (0, 2, 3)
    # is blue, red, blue: (85, 0, 170).
    assert_equal(
        svg.count('fill="#aa0055"'),
        1,
        "the first face at the mean of its corners",
    )
    assert_equal(
        svg.count('fill="#5500aa"'),
        1,
        "the second face at the mean of its corners",
    )

    p.fill_mesh_shaded(pts, _two_faces(), cols)
    assert_equal(p.content().count("/Msh1 sh"), 1, "painted with sh")
    var file = String(unsafe_from_utf8=Span(p.to_bytes(compress=False)))
    assert_equal(file.count("/ShadingType 4"), 1, "a Type 4 shading object")
    assert_true(file.count("/Msh1 ") >= 1, "referenced from the resources")
    # Two faces, three vertices each, twelve bytes per vertex entry.
    assert_equal(file.count("/Length 72"), 1, "the packed vertex stream")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

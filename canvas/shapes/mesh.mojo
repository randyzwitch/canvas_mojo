"""A mesh of adjacent faces drawn as one shape: full coverage wherever
two faces meet, anti-aliasing only at the outer silhouette.

Why a separate rasterizer. Two anti-aliased fills sharing an edge each
blend their partial coverage of the edge pixels against the
*background* rather than against each other, so a pixel both faces
half-cover comes out half fill and half background. Measured on two
same-colored triangles sharing a diagonal: 52 interior pixels off the
fill color along a 60-pixel edge, the worst by 53 levels (#425). A
surface plot has an edge between every pair of faces, so it renders
with a light mesh drawn through it. No sequence of per-face fills can
fix that, because the fix needs to know that the other face is there.

How this one works. Each face is rasterized hard-edged at
`_SUBSAMPLE` times the canvas resolution, in draw order, into a
scratch that starts fully transparent; a sub-sample's centre belongs
to exactly one face under the top-left rule, so shared edges have no
gap and no double cover, and a later face covering a sub-sample simply
replaces or blends over the earlier one, which is the painter's
algorithm a depth-sorted mesh relies on. Each output pixel is then the
premultiplied mean of its sub-samples composited over what the canvas
holds: opaque inside the mesh, a coverage fraction at the silhouette,
and untouched outside it. The silhouette gets `_SUBSAMPLE`-squared
coverage levels, the same as the sampled anti-aliased fills.

The scratch is a band's worth of sub-sample rows, not the whole
canvas, and the band body is the unit a batch or a supersampled region
replays: a mesh records as one op holding a range into the batch's
side lists (#415), and each band rasterizes every face reaching its
rows. Bands write disjoint rows, which is the whole safety argument.
"""

from std.math import ceil, floor
from std.runtime._asyncrt import TaskGroup

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color
from canvas.geometry import FPoint
from canvas.workers import _bands_for

# Sub-samples per pixel along each axis: 4 gives 16 per pixel, the
# same 17 coverage levels the sampled AA fills use at their default.
comptime _SUBSAMPLE = 4

# Fixed-point bits for the edge functions: vertices are snapped to
# 1/256 of a pixel. Every sub-sample centre is a multiple of 1/16, so
# it is exact at this precision, which is what makes edge ownership a
# strict test rather than a rounding one; and the snap itself moves an
# edge by at most 1/512 of a pixel, so against the sampled polygon
# fill, which does not snap, a single triangle differs by one
# sub-sample on a handful of edge pixels rather than on most of them
# (at 1/16 it was 193 of them). An edge function of three such points
# fits an Int64 for any canvas this package will see.
comptime _FIX_BITS = 8
comptime _FIX_ONE = 1 << _FIX_BITS

# Rows of the canvas per band, chosen so a band's scratch --
# `width * _SUBSAMPLE * rows * _SUBSAMPLE * 4` bytes -- stays a few
# hundred kilobytes at chart widths.
comptime _MESH_BAND_ROWS = 16


def _check_mesh(
    points: List[FPoint], faces: List[Int], color_count: Int, per_face: Bool
) raises:
    """Every index in `faces` names a point, `faces` is whole
    triangles, and there is a color per face or per vertex as the
    overload requires. Raises rather than drawing the subset that
    checks out, since a face silently dropped from a surface is a
    hole nobody reported.

    Args:
        points: The vertices.
        faces: Index triples into `points`.
        color_count: How many colors the caller supplied.
        per_face: Whether colors are per face (else per vertex).
    """
    if len(faces) % 3 != 0:
        raise Error(
            String(
                "fill_mesh: ",
                len(faces),
                " face indices is not a whole number of triangles",
            )
        )
    var n = len(points)
    for i in range(len(faces)):
        var k = faces[i]
        if k < 0 or k >= n:
            raise Error(
                String("fill_mesh: face index ", k, " outside ", n, " points")
            )
    var need = len(faces) // 3 if per_face else n
    if color_count != need:
        raise Error(
            String(
                "fill_mesh: ",
                color_count,
                " colors for ",
                need,
                " faces" if per_face else " vertices",
            )
        )


def _mean_color(a: Color, b: Color, c: Color) -> Color:
    """The flat color a vector backend without per-vertex shading
    gives a face: the mean of its corners, channel by channel."""
    return Color(
        UInt8((Int(a.r) + Int(b.r) + Int(c.r) + 1) // 3),
        UInt8((Int(a.g) + Int(b.g) + Int(c.g) + 1) // 3),
        UInt8((Int(a.b) + Int(b.b) + Int(c.b) + 1) // 3),
        UInt8((Int(a.a) + Int(b.a) + Int(c.a) + 1) // 3),
    )


def _mesh_rows(points: List[FPoint], faces: List[Int]) -> Tuple[Int, Int]:
    """The canvas rows any face can touch, padded a row each way: what
    a band rejects the whole mesh on, and what the batch's op records
    as its row range.

    Args:
        points: Device-space vertices.
        faces: Index triples.

    Returns:
        (first_row, last_row), last exclusive; (0, 0) for no faces.
    """
    if len(faces) == 0:
        return (0, 0)
    var lo = points[faces[0]].y
    var hi = lo
    for i in range(len(faces)):
        var y = points[faces[i]].y
        if y < lo:
            lo = y
        if y > hi:
            hi = y
    return (Int(floor(lo)) - 1, Int(ceil(hi)) + 2)


@always_inline
def _fix(v: Float64) -> Int:
    """`v` in fixed point, rounded to the nearest sub-unit."""
    return Int(floor(v * Float64(_FIX_ONE) + 0.5))


@always_inline
def _channels(canvas: Canvas, color: Color, linear: Bool) -> SIMD[.float64, 4]:
    """A vertex color as four lanes to interpolate: r, g, b as bytes
    in SRGB or as linear light in LINEAR, and alpha as a byte either
    way."""
    if linear:
        return SIMD[.float64, 4](
            Float64(canvas._transfer.linear(color.r)),
            Float64(canvas._transfer.linear(color.g)),
            Float64(canvas._transfer.linear(color.b)),
            Float64(color.a),
        )
    return SIMD[.float64, 4](
        Float64(color.r), Float64(color.g), Float64(color.b), Float64(color.a)
    )


@always_inline
def _encode(canvas: Canvas, ch: SIMD[.float64, 4], linear: Bool) -> Color:
    """`_channels` back to a color at one sub-sample, rounded and
    clamped."""
    var a = Int(ch[3] + 0.5)
    if a < 0:
        a = 0
    elif a > 255:
        a = 255
    if linear:
        return Color(
            canvas._transfer.byte(Float32(ch[0])),
            canvas._transfer.byte(Float32(ch[1])),
            canvas._transfer.byte(Float32(ch[2])),
            UInt8(a),
        )
    var r = Int(ch[0] + 0.5)
    var g = Int(ch[1] + 0.5)
    var b = Int(ch[2] + 0.5)
    return Color(
        UInt8(min(max(r, 0), 255)),
        UInt8(min(max(g, 0), 255)),
        UInt8(min(max(b, 0), 255)),
        UInt8(a),
    )


def _mesh_band(
    mut canvas: Canvas,
    points: List[FPoint],
    faces: List[Int],
    colors: List[Color],
    row_lo: Int,
    row_hi: Int,
    first_point: Int = 0,
    first_face: Int = 0,
    face_count: Int = -1,
    first_color: Int = 0,
    per_vertex: Bool = False,
):
    """Every face reaching rows [row_lo, row_hi), in draw order, as
    one anti-aliased shape. `points`, `faces` and `colors` are a
    batch's shared lists and the ranges select this mesh's slice; a
    direct call passes whole lists and the defaults. Vertices are in
    device space. Bands own disjoint rows.

    The rows are taken `_MESH_BAND_ROWS` at a time whatever the
    caller's band is, so the sub-sample scratch stays a few hundred
    kilobytes: a batch hands a band whatever share of the canvas its
    own split chose, which can be hundreds of rows.

    Args:
        canvas: Where the rows land, under its clip and blend mode.
        points: Device-space vertices, `first_point` on.
        faces: Index triples, relative to `first_point`.
        colors: One color per face, `first_color` on.
        row_lo: First canvas row this band writes.
        row_hi: One past the last.
        first_point: Where this mesh's vertices start in `points`.
        first_face: Where its first index triple starts in `faces`.
        face_count: How many triples, -1 for the rest of the list.
        first_color: Where its colors start in `colors`.
        per_vertex: Whether `colors` holds one per vertex, interpolated
            across each face (`fill_mesh_shaded`), rather than one per
            face.
    """
    var stop = len(faces) if face_count < 0 else first_face + face_count * 3
    if stop <= first_face:
        return
    var bounds = canvas.row_bounds()
    var lo = max(row_lo, bounds[0])
    var hi = min(row_hi, bounds[1])
    var y = lo
    while y < hi:
        var y1 = min(y + _MESH_BAND_ROWS, hi)
        _mesh_chunk(
            canvas,
            points,
            faces,
            colors,
            y,
            y1,
            first_point,
            first_face,
            stop,
            first_color,
            per_vertex,
        )
        y = y1


def _mesh_chunk(
    mut canvas: Canvas,
    points: List[FPoint],
    faces: List[Int],
    colors: List[Color],
    y0: Int,
    y1: Int,
    first_point: Int,
    first_face: Int,
    stop: Int,
    first_color: Int,
    per_vertex: Bool,
):
    """`_mesh_band`'s body for rows [y0, y1), already clamped to the
    canvas: rasterize every face into a sub-sample scratch of those
    rows, then average each pixel down onto the canvas.

    With `per_vertex` each face's color is interpolated from its three
    corners: the edge functions are barycentric weights up to the
    face's area, and each is affine in (x, y), so a channel is a value
    at the box corner stepped by a constant per sub-sample, the same
    way the edge functions themselves are walked. In the LINEAR color
    space the corners are taken to linear light first and each
    sub-sample encoded back, so a smooth face agrees with the same face
    drawn as many flat ones with intermediate colors; alpha is not
    gamma-encoded and interpolates as it is in either space."""
    var linear = per_vertex and canvas._space.is_linear()
    # The columns any face reaches, so the scratch is the mesh's width
    # rather than the canvas's, and the composite walks only those.
    var min_x = points[first_point + faces[first_face]].x
    var max_x = min_x
    for i in range(first_face, stop):
        var x = points[first_point + faces[i]].x
        if x < min_x:
            min_x = x
        if x > max_x:
            max_x = x
    var x0 = max(Int(floor(min_x)) - 1, 0)
    var x1 = min(Int(ceil(max_x)) + 2, canvas.width)
    if x1 <= x0:
        return

    var cols = x1 - x0
    var rows = y1 - y0
    var sw = cols * _SUBSAMPLE
    var sh = rows * _SUBSAMPLE
    # Straight-alpha RGBA per sub-sample, transparent black to start:
    # a sub-sample no face reaches contributes nothing to its pixel.
    var scratch = List[UInt8](length=sw * sh * BYTES_PER_PIXEL, fill=0)
    var sp = scratch.unsafe_ptr()

    # Pixel (px, py) is the square [px - 0.5, px + 0.5], the convention
    # every rasterizer here shares, so sub-sample (i, j) of the scratch
    # has its centre at (x0 - 0.5 + (i + 0.5) / S, y0 - 0.5 + (j + 0.5)
    # / S): the same positions the sampled AA fills test. In fixed
    # point with S = 4 that is (4i + 2 - 8) / 16 of a pixel, a whole
    # number of 1/256ths, so every centre is exactly representable and
    # the ownership test below is strict rather than a rounding one.
    comptime STEP = _FIX_ONE // _SUBSAMPLE
    comptime HALF_STEP = STEP // 2
    var ox = x0 * _FIX_ONE - _FIX_ONE // 2
    var oy = y0 * _FIX_ONE - _FIX_ONE // 2

    for f in range(first_face, stop, 3):
        var a = points[first_point + faces[f]]
        var b = points[first_point + faces[f + 1]]
        var c = points[first_point + faces[f + 2]]
        var color = Color(0, 0, 0)
        var col_a = Color(0, 0, 0)
        var col_b = Color(0, 0, 0)
        var col_c = Color(0, 0, 0)
        if per_vertex:
            col_a = colors[first_color + faces[f]]
            col_b = colors[first_color + faces[f + 1]]
            col_c = colors[first_color + faces[f + 2]]
            if col_a.a == 0 and col_b.a == 0 and col_c.a == 0:
                continue
        else:
            color = colors[first_color + (f - first_face) // 3]
            if color.a == 0:
                continue
        # Fixed-point vertices relative to the scratch origin.
        var ax = _fix(a.x) - ox
        var ay = _fix(a.y) - oy
        var bx = _fix(b.x) - ox
        var by = _fix(b.y) - oy
        var cx = _fix(c.x) - ox
        var cy = _fix(c.y) - oy
        # Twice the signed area. Zero is a degenerate face with
        # nothing inside it; a negative one is wound the other way,
        # and flipping two vertices makes every edge function below
        # positive inside without the caller having to care.
        var area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        if area == 0:
            continue
        if area < 0:
            var tx = bx
            var ty = by
            bx = cx
            by = cy
            cx = tx
            cy = ty
            area = -area
            # The colors travel with their vertices.
            var tc = col_b
            col_b = col_c
            col_c = tc
        # The face's sub-sample box, clamped to the scratch.
        var fy_lo = min(ay, min(by, cy))
        var fy_hi = max(ay, max(by, cy))
        var fx_lo = min(ax, min(bx, cx))
        var fx_hi = max(ax, max(bx, cx))
        var j_lo = max((fy_lo - HALF_STEP + STEP - 1) // STEP, 0)
        var j_hi = min((fy_hi - HALF_STEP) // STEP + 1, sh)
        var i_lo = max((fx_lo - HALF_STEP + STEP - 1) // STEP, 0)
        var i_hi = min((fx_hi - HALF_STEP) // STEP + 1, sw)
        if j_hi <= j_lo or i_hi <= i_lo:
            continue
        # Edge functions E(p) = (q - p_start) x (p_end - p_start) for
        # the three edges, positive inside with the winding fixed
        # above. Each is affine in (x, y), so it is evaluated at the
        # box corner and stepped by its gradients.
        var e0_dx = by - cy
        var e0_dy = cx - bx
        var e1_dx = cy - ay
        var e1_dy = ax - cx
        var e2_dx = ay - by
        var e2_dy = bx - ax
        # Edge ownership, the top-left rule's mechanism. A sub-sample
        # centre exactly on an edge is inside only when a fixed test
        # on the edge's direction passes: gradient in x positive, or
        # zero with the gradient in y negative. Two faces sharing an
        # edge traverse it in opposite directions once both are wound
        # the same way (done above), so their gradients along it are
        # negatives of each other and exactly one of the two passes.
        # A centre on a shared edge therefore belongs to one face and
        # not the other: no gap, no double cover, which is the whole
        # reason shared edges come out seam-free. Which edges the test
        # happens to call "top" or "left" does not matter; that it
        # splits every opposite pair does.
        var bias0 = 0 if (e0_dx > 0 or (e0_dx == 0 and e0_dy < 0)) else 1
        var bias1 = 0 if (e1_dx > 0 or (e1_dx == 0 and e1_dy < 0)) else 1
        var bias2 = 0 if (e2_dx > 0 or (e2_dx == 0 and e2_dy < 0)) else 1
        var px0 = i_lo * STEP + HALF_STEP
        var py0 = j_lo * STEP + HALF_STEP
        var row0 = (px0 - bx) * e0_dx + (py0 - by) * e0_dy - bias0
        var row1 = (px0 - cx) * e1_dx + (py0 - cy) * e1_dy - bias1
        var row2 = (px0 - ax) * e2_dx + (py0 - ay) * e2_dy - bias2
        var step_x0 = e0_dx * STEP
        var step_x1 = e1_dx * STEP
        var step_x2 = e2_dx * STEP
        var step_y0 = e0_dy * STEP
        var step_y1 = e1_dy * STEP
        var step_y2 = e2_dy * STEP
        var opaque = color.a == 255
        # Per-vertex shading: each channel as an affine function of
        # the sub-sample position, from its value at the box corner
        # and its step per sub-sample in x and y. E0 weights vertex a
        # (it is the edge opposite a), E1 weights b, E2 weights c; the
        # ownership biases are put back so the weights sum to the
        # area exactly.
        var inv_area = 1.0 / Float64(area)
        # Converted per face whether or not they are used: three
        # lookups against a per-sub-sample loop, and the flat path's
        # corners are the zero color.
        var ch_a = _channels(canvas, col_a, linear)
        var ch_b = _channels(canvas, col_b, linear)
        var ch_c = _channels(canvas, col_c, linear)
        var ch_row = SIMD[.float64, 4](0.0)
        var ch_dx = SIMD[.float64, 4](0.0)
        var ch_dy = SIMD[.float64, 4](0.0)
        if per_vertex:
            ch_row = (
                ch_a * Float64(row0 + bias0)
                + ch_b * Float64(row1 + bias1)
                + ch_c * Float64(row2 + bias2)
            ) * inv_area
            ch_dx = (
                ch_a * Float64(step_x0)
                + ch_b * Float64(step_x1)
                + ch_c * Float64(step_x2)
            ) * inv_area
            ch_dy = (
                ch_a * Float64(step_y0)
                + ch_b * Float64(step_y1)
                + ch_c * Float64(step_y2)
            ) * inv_area
            opaque = col_a.a == 255 and col_b.a == 255 and col_c.a == 255
        for j in range(j_lo, j_hi):
            var w0 = row0
            var w1 = row1
            var w2 = row2
            var ch = ch_row
            var idx = (j * sw + i_lo) * BYTES_PER_PIXEL
            for _ in range(i_lo, i_hi):
                if w0 >= 0 and w1 >= 0 and w2 >= 0:
                    if per_vertex:
                        color = _encode(canvas, ch, linear)
                    if opaque:
                        sp[unsafe_offset=idx] = color.r
                        sp[unsafe_offset=idx + 1] = color.g
                        sp[unsafe_offset=idx + 2] = color.b
                        sp[unsafe_offset=idx + 3] = 255
                    else:
                        # A translucent face over what an earlier face
                        # left: source-over per sub-sample, which is
                        # what drawing the faces one at a time does
                        # where they overlap and, since a shared edge
                        # gives each sub-sample to one face only, is
                        # applied once along it.
                        var under = Color(
                            sp[unsafe_offset=idx],
                            sp[unsafe_offset=idx + 1],
                            sp[unsafe_offset=idx + 2],
                            sp[unsafe_offset=idx + 3],
                        )
                        var over = color.blend_over(under)
                        sp[unsafe_offset=idx] = over.r
                        sp[unsafe_offset=idx + 1] = over.g
                        sp[unsafe_offset=idx + 2] = over.b
                        sp[unsafe_offset=idx + 3] = over.a
                w0 += step_x0
                w1 += step_x1
                w2 += step_x2
                ch += ch_dx
                idx += BYTES_PER_PIXEL
            row0 += step_y0
            row1 += step_y1
            row2 += step_y2
            ch_row += ch_dy

    # Each pixel is the premultiplied mean of its sub-samples, then
    # composited over the canvas through `set_pixel`, which applies
    # the clip, the blend mode and the color space as any primitive's
    # pixel does. Premultiplied, because averaging straight-alpha
    # values would pull a covered sub-sample's color toward the
    # transparent black of an uncovered neighbour and fringe the
    # silhouette dark.
    comptime N = _SUBSAMPLE * _SUBSAMPLE
    for py in range(rows):
        for px in range(cols):
            var sum_r = 0
            var sum_g = 0
            var sum_b = 0
            var sum_a = 0
            for j in range(_SUBSAMPLE):
                var idx = (
                    (py * _SUBSAMPLE + j) * sw + px * _SUBSAMPLE
                ) * BYTES_PER_PIXEL
                for _ in range(_SUBSAMPLE):
                    var a = Int(sp[unsafe_offset=idx + 3])
                    if a != 0:
                        sum_r += Int(sp[unsafe_offset=idx]) * a
                        sum_g += Int(sp[unsafe_offset=idx + 1]) * a
                        sum_b += Int(sp[unsafe_offset=idx + 2]) * a
                        sum_a += a
                    idx += BYTES_PER_PIXEL
            if sum_a == 0:
                continue
            # Un-premultiply by the summed alpha, which divides the
            # color by the coverage-weighted alpha and leaves the
            # alpha itself as the mean over all N sub-samples.
            var r = (sum_r + sum_a // 2) // sum_a
            var g = (sum_g + sum_a // 2) // sum_a
            var b = (sum_b + sum_a // 2) // sum_a
            var alpha = (sum_a + N // 2) // N
            if alpha == 0:
                continue
            canvas.set_pixel(
                x0 + px,
                y0 + py,
                Color(UInt8(r), UInt8(g), UInt8(b), UInt8(alpha)),
            )


async def _mesh_band_async(
    mut canvas: Canvas,
    points: List[FPoint],
    faces: List[Int],
    colors: List[Color],
    row_lo: Int,
    row_hi: Int,
    per_vertex: Bool,
):
    """`_mesh_band` as a task. The lists are borrowed, never owned: a
    heap-backed aggregate handed to `create_task` by value is
    canvas_mojo#97.
    """
    _mesh_band(
        canvas, points, faces, colors, row_lo, row_hi, per_vertex=per_vertex
    )


def _fill_mesh_device(
    mut canvas: Canvas,
    points: List[FPoint],
    faces: List[Int],
    colors: List[Color],
    per_vertex: Bool = False,
) raises:
    """Draw a device-space mesh now, banded across cores when there is
    enough of it. What `fill_mesh` reaches once the transform is
    applied and nothing is recording."""
    var rows = _mesh_rows(points, faces)
    if rows[1] <= rows[0]:
        return
    var bounds = canvas.row_bounds()
    var lo = max(rows[0], bounds[0])
    var hi = min(rows[1], bounds[1])
    if hi <= lo:
        return
    # About the pixels the mesh covers: its box. What `_bands_for`
    # weighs against the parallel threshold, times the sub-samples
    # each costs.
    var work = (hi - lo) * canvas.width * _SUBSAMPLE * _SUBSAMPLE
    var bands = _bands_for(work, hi - lo, canvas.max_workers())
    if bands <= 1:
        _mesh_band(canvas, points, faces, colors, lo, hi, per_vertex=per_vertex)
        return
    var per_band = (hi - lo + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var row_lo = lo + b * per_band
        var row_hi = min(row_lo + per_band, hi)
        if row_lo >= row_hi:
            continue
        tg.create_task(
            _mesh_band_async(
                canvas, points, faces, colors, row_lo, row_hi, per_vertex
            )
        )
    tg.wait()
    # Named past the tasks: a task's borrow is not a use the compiler
    # counts, so without this the lists are freed while bands still
    # read them (#263).
    _ = len(points)
    _ = len(faces)
    _ = len(colors)


def fill_mesh(
    mut canvas: Canvas,
    points: List[FPoint],
    faces: List[Int],
    colors: List[Color],
) raises:
    """Many adjacent triangles in one call, drawn as one anti-aliased
    shape: no seam along an edge two faces share, and anti-aliasing
    only at the outline of the whole. Faces are drawn in the order
    given, so a mesh sorted back to front composites the way the
    painter's algorithm expects where faces overlap.

    This is what a surface plot draws. Filling each face on its own
    with `fill_path_aa` leaves a light line along every shared edge,
    because each face's edge coverage blends against the background
    rather than against its neighbour (#425).

    Under a transform the vertices map to device space first, as every
    batched primitive's geometry does. Inside a batch or a supersampled
    region the whole call records as one op. A degenerate face (zero
    area) draws nothing; a face wound either way draws the same.

    Args:
        canvas: Canvas to draw on.
        points: The vertices, in the canvas's coordinates.
        faces: Index triples into `points`, one triangle each, in
            draw order.
        colors: One color per triangle, same count as triples.

    Raises:
        Error: `faces` is not whole triples, an index is out of range,
            or `colors` is not one per triangle.
    """
    _check_mesh(points, faces, len(colors), True)
    if len(faces) == 0:
        return
    var device = points.copy()
    if canvas.has_transform():
        var m = canvas.current_transform()
        for i in range(len(points)):
            ref p = points[i]
            device[i] = m.apply(p.x, p.y)
    if canvas._batching():
        canvas._record_mesh(device, faces, colors, False)
        return
    _fill_mesh_device(canvas, device, faces, colors)


def fill_mesh_shaded(
    mut canvas: Canvas,
    points: List[FPoint],
    faces: List[Int],
    vertex_colors: List[Color],
) raises:
    """`fill_mesh` with a color per vertex, interpolated across each
    face: a smoothly shaded surface rather than a faceted one (#426).
    Everything else is `fill_mesh`'s -- seam-free shared edges,
    painter's order, the transform, recording as one op -- and a face
    whose three corners share a color draws exactly as `fill_mesh`
    draws it.

    Interpolation is barycentric, in the canvas's color space: SRGB
    mixes the stored bytes, LINEAR mixes linear light and encodes back,
    the same rule source-over follows, so a smooth face agrees with the
    same face drawn as many flat faces at intermediate colors. A
    different name rather than an overload, because a color per vertex
    and a color per face are the same type and only their counts
    differ, and a call whose meaning depends on a count is a call that
    changes meaning when the mesh does.

    Args:
        canvas: Canvas to draw on.
        points: The vertices, in the canvas's coordinates.
        faces: Index triples into `points`, one triangle each, in
            draw order.
        vertex_colors: One color per vertex, same count as `points`.

    Raises:
        Error: `faces` is not whole triples, an index is out of range,
            or `vertex_colors` is not one per vertex.
    """
    _check_mesh(points, faces, len(vertex_colors), False)
    if len(faces) == 0:
        return
    var device = points.copy()
    if canvas.has_transform():
        var m = canvas.current_transform()
        for i in range(len(points)):
            ref p = points[i]
            device[i] = m.apply(p.x, p.y)
    if canvas._batching():
        canvas._record_mesh(device, faces, vertex_colors, True)
        return
    _fill_mesh_device(canvas, device, faces, vertex_colors, True)

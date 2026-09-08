"""Coverage-inclusive floors for the shape rows (#355).

`benchmarks/roofline.md` prices most shape rows at blend cost times
the pixels that changed, and marks them loose because computing
anti-aliased coverage is real work the floor leaves out. This measures
that work.

Each kernel does the least arithmetic any correct implementation of
its shape must do -- locate the pixel relative to the shape, turn that
into a coverage fraction, scale the alpha, blend -- over the pixels
the rasterizer has to visit. It is a lower bound, not a
reimplementation: exact-area coverage cannot cost less than deciding
where each pixel sits relative to the edge.

Two counts matter and they are not the same. `visits` is the pixels a
shape's bounding box makes the rasterizer look at, summed over every
shape; `changed` is the distinct pixels whose value ends up different.
Overlapping markers change a pixel once but visit it several times,
so a floor built on `changed` prices work that was never optional.

Run on a quiet machine; see benchmarks/roofline.md.
"""
from std.math import cos, sin, sqrt
from std.time import perf_counter_ns

from canvas.color import _DIV255_MUL, _DIV255_SHIFT

comptime W = 800
comptime H = 600
comptime N = W * H * 4


def _median(var xs: List[Float64]) -> Float64:
    for i in range(1, len(xs)):
        var v = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > v:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = v
    return xs[len(xs) // 2]


def _blend_px(mut dst: List[UInt8], o: Int, r: Int, g: Int, b: Int, a: Int):
    """Source-over onto an opaque destination, the arithmetic every
    coverage-weighted write ends in."""
    var p = dst.unsafe_ptr()
    var inv = 255 - a
    p[unsafe_offset=o] = UInt8(
        ((r * a + Int(p[unsafe_offset=o]) * inv) * _DIV255_MUL) >> _DIV255_SHIFT
    )
    p[unsafe_offset=o + 1] = UInt8(
        ((g * a + Int(p[unsafe_offset=o + 1]) * inv) * _DIV255_MUL)
        >> _DIV255_SHIFT
    )
    p[unsafe_offset=o + 2] = UInt8(
        ((b * a + Int(p[unsafe_offset=o + 2]) * inv) * _DIV255_MUL)
        >> _DIV255_SHIFT
    )


def _circles(mut dst: List[UInt8], n: Int, radius: Float64, tint: Int) -> Int:
    """`n` disks: visit each pixel of the bounding box, turn its
    distance from the centre into coverage, blend."""
    var visits = 0
    for i in range(n):
        var cx = 20.0 + Float64((i * 37) % 760)
        var cy = 20.0 + Float64((i * 53) % 560)
        var x0 = Int(cx - radius - 1.0)
        var x1 = Int(cx + radius + 1.0)
        var y0 = Int(cy - radius - 1.0)
        var y1 = Int(cy + radius + 1.0)
        for y in range(max(y0, 0), min(y1 + 1, H)):
            var dy = Float64(y) - cy
            for x in range(max(x0, 0), min(x1 + 1, W)):
                visits += 1
                var dx = Float64(x) - cx
                var d = sqrt(dx * dx + dy * dy)
                var cov = radius + 0.5 - d
                if cov <= 0.0:
                    continue
                if cov > 1.0:
                    cov = 1.0
                var a = Int(cov * 255.0 + 0.5)
                _blend_px(dst, (y * W + x) * 4, tint, 40, 60, a)
    return visits


def _ellipses(
    mut dst: List[UInt8], n: Int, rx: Float64, ry: Float64, tint: Int
) -> Int:
    """`n` ellipses: the same, with the normalized radius an ellipse
    needs instead of a distance."""
    var visits = 0
    for i in range(n):
        var cx = 20.0 + Float64((i * 37) % 760)
        var cy = 20.0 + Float64((i * 53) % 560)
        var x0 = Int(cx - rx - 1.0)
        var x1 = Int(cx + rx + 1.0)
        var y0 = Int(cy - ry - 1.0)
        var y1 = Int(cy + ry + 1.0)
        for y in range(max(y0, 0), min(y1 + 1, H)):
            var dy = (Float64(y) - cy) / ry
            for x in range(max(x0, 0), min(x1 + 1, W)):
                visits += 1
                var dx = (Float64(x) - cx) / rx
                var d = sqrt(dx * dx + dy * dy)
                var cov = (1.0 - d) * rx + 0.5
                if cov <= 0.0:
                    continue
                if cov > 1.0:
                    cov = 1.0
                var a = Int(cov * 255.0 + 0.5)
                _blend_px(dst, (y * W + x) * 4, tint, 40, 60, a)
    return visits


def _wedges(mut dst: List[UInt8], n: Int, radius: Float64, tint: Int) -> Int:
    """`n` wedges: a disk's coverage plus the two half-plane tests a
    sweep needs, done with cross products rather than an angle."""
    var visits = 0
    var c0 = -0.6
    var c1 = 1.1
    var sx0 = Float64(0.8253)
    var sy0 = Float64(-0.5646)
    var sx1 = Float64(0.4536)
    var sy1 = Float64(0.8912)
    for i in range(n):
        var cx = 20.0 + Float64((i * 37) % 760)
        var cy = 20.0 + Float64((i * 53) % 560)
        var x0 = Int(cx - radius - 1.0)
        var x1 = Int(cx + radius + 1.0)
        var y0 = Int(cy - radius - 1.0)
        var y1 = Int(cy + radius + 1.0)
        for y in range(max(y0, 0), min(y1 + 1, H)):
            var dy = Float64(y) - cy
            for x in range(max(x0, 0), min(x1 + 1, W)):
                visits += 1
                var dx = Float64(x) - cx
                var d = sqrt(dx * dx + dy * dy)
                var cov = radius + 0.5 - d
                if cov <= 0.0:
                    continue
                if dx * sy0 - dy * sx0 < 0.0:
                    continue
                if dx * sy1 - dy * sx1 > 0.0:
                    continue
                if cov > 1.0:
                    cov = 1.0
                var a = Int(cov * 255.0 + 0.5)
                _blend_px(dst, (y * W + x) * 4, tint, 40, 60, a)
    _ = c0
    _ = c1
    return visits


def _circle_spans(
    mut dst: List[UInt8], cx: Float64, cy: Float64, radius: Float64, tint: Int
) -> Tuple[Int, Int]:
    """One large disk, the way a scanline rasterizer must do it: solve
    the row's span analytically, fill its interior without touching
    coverage, and compute coverage only at the two ends.

    A per-pixel distance test is not a floor for a shape this size --
    it costs more than the real implementation, because it prices the
    interior at edge rates. Returns (interior, edge) pixels.
    """
    var interior = 0
    var edge = 0
    var p = dst.unsafe_ptr()
    var y0 = max(Int(cy - radius - 1.0), 0)
    var y1 = min(Int(cy + radius + 1.0) + 1, H)
    for y in range(y0, y1):
        var dy = Float64(y) - cy
        var under = radius * radius - dy * dy
        if under <= 0.0:
            continue
        var half = sqrt(under)
        var xl = cx - half
        var xr = cx + half
        var il = Int(xl) + 1
        var ir = Int(xr)
        # Interior: a solid run, no coverage arithmetic at all.
        var lo = max(il, 0)
        var hi = min(ir, W)
        if hi > lo:
            interior += hi - lo
            for x in range(lo, hi):
                var o = (y * W + x) * 4
                p[unsafe_offset=o] = UInt8(tint)
                p[unsafe_offset=o + 1] = 40
                p[unsafe_offset=o + 2] = 60
        # The two boundary pixels, which do need coverage.
        for x in [il - 1, ir]:
            if x < 0 or x >= W:
                continue
            edge += 1
            var cov = 1.0 - abs(Float64(x) + 0.5 - (xl if x < il else xr))
            if cov <= 0.0:
                continue
            if cov > 1.0:
                cov = 1.0
            _blend_px(
                dst, (y * W + x) * 4, tint, 40, 60, Int(cov * 255.0 + 0.5)
            )
    return (interior, edge)


def _polygon_spans(
    mut dst: List[UInt8], xs: List[Float64], ys: List[Float64], tint: Int
) -> Tuple[Int, Int]:
    """A closed polygon by scanline, which is the shape of the work any
    path fill must do: for each row find where the edges cross it, sort
    the crossings, fill between them, and pay coverage only at the
    span ends.

    This is the floor for `fill_polygon_aa` and the nearest measured
    stand-in for a flattened path fill: a real path adds flattening
    curves to line segments, which this does not price, so it bounds
    the sweep rather than the whole call.

    Returns (interior, edge) pixels.
    """
    var n = len(xs)
    var interior = 0
    var edge = 0
    var p = dst.unsafe_ptr()
    var lo_y = 1 << 30
    var hi_y = -(1 << 30)
    for i in range(n):
        var yi = Int(ys[i])
        if yi < lo_y:
            lo_y = yi
        if yi > hi_y:
            hi_y = yi
    lo_y = max(lo_y, 0)
    hi_y = min(hi_y + 1, H)

    var cross = List[Float64](capacity=16)
    for y in range(lo_y, hi_y):
        cross.clear()
        var fy = Float64(y) + 0.5
        for i in range(n):
            var j = i + 1 if i + 1 < n else 0
            var y0 = ys[i]
            var y1 = ys[j]
            if (y0 <= fy) == (y1 <= fy):
                continue
            var tpar = (fy - y0) / (y1 - y0)
            cross.append(xs[i] + tpar * (xs[j] - xs[i]))
        if len(cross) < 2:
            continue
        for a in range(1, len(cross)):
            var v = cross[a]
            var b = a - 1
            while b >= 0 and cross[b] > v:
                cross[b + 1] = cross[b]
                b -= 1
            cross[b + 1] = v
        var k = 0
        while k + 1 < len(cross):
            var xl = cross[k]
            var xr = cross[k + 1]
            var il = max(Int(xl) + 1, 0)
            var ir = min(Int(xr), W)
            if ir > il:
                interior += ir - il
                for x in range(il, ir):
                    var o = (y * W + x) * 4
                    p[unsafe_offset=o] = UInt8(tint)
                    p[unsafe_offset=o + 1] = 40
                    p[unsafe_offset=o + 2] = 60
            for x in [il - 1, ir]:
                if x < 0 or x >= W:
                    continue
                edge += 1
                var ref_x = xl if x < il else xr
                var cov = 1.0 - abs(Float64(x) + 0.5 - ref_x)
                if cov <= 0.0:
                    continue
                if cov > 1.0:
                    cov = 1.0
                _blend_px(
                    dst, (y * W + x) * 4, tint, 40, 60, Int(cov * 255.0 + 0.5)
                )
            k += 2
    return (interior, edge)


def _time(name: String, visits: Int, us: Float64, actual: Float64):
    var ns_per = us * 1000.0 / Float64(visits)
    print(
        "  ",
        name,
        "\n     visits ",
        visits,
        " floor ",
        String(round(us, 1)),
        "us (",
        String(round(ns_per, 3)),
        "ns/visit )  bench ",
        String(round(actual, 1)),
        "us  -> ",
        String(round(us / actual * 100.0, 1)) + "% of it",
    )


def main() raises:
    var dst = List[UInt8](length=N, fill=255)
    var sink = 0
    print("coverage-inclusive floors, 800x600, serial\n")

    var v = 0
    var ts = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        v = _circles(dst, 2000, 3.5, 30 + (k & 7))
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[17])
    _time("fill_circle_aa x2000 markers (r=3.5)", v, _median(ts^), 2921.0)

    ts = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        v = _ellipses(dst, 2000, 5.0, 3.0, 30 + (k & 7))
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[19])
    _time("fill_ellipse_aa x2000 small (5x3)", v, _median(ts^), 3482.5)

    ts = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        v = _wedges(dst, 2000, 4.0, 30 + (k & 7))
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[23])
    _time("fill_arc_aa x2000 small (r=4)", v, _median(ts^), 2766.3)

    # A large disk, where the interior is a run and only the rim needs
    # coverage. Centred where the bench centres it.
    var parts = (0, 0)
    ts = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        parts = _circle_spans(dst, 400.0, 300.0, 250.0, 30 + (k & 7))
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[29])
    var us = _median(ts^)
    print(
        "   fill_circle_aa one large (r=250)",
        "\n     interior ",
        parts[0],
        " rim ",
        parts[1],
        " floor ",
        String(round(us, 1)),
        "us  bench  140.2 us  -> ",
        String(round(us / 140.2 * 100.0, 1)) + "% of it",
    )

    # The 64-gon the bench fills, as a scanline sweep.
    var px = List[Float64](capacity=64)
    var py = List[Float64](capacity=64)
    for i in range(64):
        var ang = Float64(i) / 64.0 * 6.283185307179586
        px.append(400.0 + 250.0 * cos(ang))
        py.append(300.0 + 200.0 * sin(ang))
    var poly = (0, 0)
    ts = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        poly = _polygon_spans(dst, px, py, 30 + (k & 7))
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[31])
    var pus = _median(ts^)
    print(
        "   fill_polygon_aa 64-gon",
        "\n     interior ",
        poly[0],
        " edge ",
        poly[1],
        " floor ",
        String(round(pus, 1)),
        "us  bench  442.9 us  -> ",
        String(round(pus / 442.9 * 100.0, 1)) + "% of it",
    )

    print("\nsink", sink != 0)

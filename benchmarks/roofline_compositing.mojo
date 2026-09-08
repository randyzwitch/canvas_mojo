"""Compositing floors that price the arithmetic actually performed
(#350).

`roofline.md`'s source-over yardstick is 0.12 ns/px, measured with
uint16 lanes, a `>>8` approximation and no alpha broadcast. The kernel
the library runs widens to uint32, broadcasts each pixel's alpha
across its four lanes with a shuffle, and divides by 255 exactly --
about six times the arithmetic. Every compositing floor built on the
cheap figure is understated by that factor.

A multiply blend is further off again: it computes `div255(dst*src)`
and *then* composites the result, roughly twice source-over's
multiplies per channel, so pricing it with the source-over kernel is
the wrong operation entirely.

Run on a quiet machine; see benchmarks/roofline.md.
"""
from std.time import perf_counter_ns

comptime PXC = 800 * 600
comptime NC = PXC * 4
comptime PXR = 600 * 400
comptime NR = PXR * 4
comptime W = 32
comptime MUL = 32897
comptime SH = 23


def _median(var xs: List[Float64]) -> Float64:
    for i in range(1, len(xs)):
        var v = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > v:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = v
    return xs[len(xs) // 2]


def _cheap(src: List[UInt8], mut dst: List[UInt8], n: Int):
    """The published yardstick: uint16 lanes, `>>8`, no broadcast."""
    var s = src.unsafe_ptr()
    var d = dst.unsafe_ptr()
    var i = 0
    while i + W <= n:
        var sv = s.unsafe_offset(i).unsafe_load[width=W]().cast[DType.uint16]()
        var dv = d.unsafe_offset(i).unsafe_load[width=W]().cast[DType.uint16]()
        d.unsafe_offset(i).unsafe_store(
            (sv + ((dv * (255 - sv)) >> 8)).cast[DType.uint8]()
        )
        i += W


def _exact(src: List[UInt8], mut dst: List[UInt8], n: Int):
    """What `_blend_group_opaque` does: broadcast the alpha across each
    pixel's lanes, widen to uint32, divide by 255 exactly."""
    var s = src.unsafe_ptr()
    var d = dst.unsafe_ptr()
    var i = 0
    while i + W <= n:
        var v = s.unsafe_offset(i).unsafe_load[width=W]()
        var dv = d.unsafe_offset(i).unsafe_load[width=W]()
        var a32 = v.shuffle[
            3,
            3,
            3,
            3,
            7,
            7,
            7,
            7,
            11,
            11,
            11,
            11,
            15,
            15,
            15,
            15,
            19,
            19,
            19,
            19,
            23,
            23,
            23,
            23,
            27,
            27,
            27,
            27,
            31,
            31,
            31,
            31,
        ]().cast[DType.uint32]()
        var num = v.cast[DType.uint32]() * a32 + dv.cast[DType.uint32]() * (
            SIMD[DType.uint32, W](255) - a32
        )
        d.unsafe_offset(i).unsafe_store(
            ((num * UInt32(MUL)) >> UInt32(SH)).cast[DType.uint8]()
        )
        i += W


def _lanes[
    LW: Int
](sr: Int, sg: Int, sb: Int) -> Tuple[
    SIMD[DType.uint32, LW], SIMD[DType.uint32, LW], SIMD[DType.uint32, LW]
]:
    """Source colour, the keep mask and the alpha mask, laid out for a
    span of `LW / 4` pixels."""
    var cs = SIMD[DType.uint32, LW]()
    var keep = SIMD[DType.uint32, LW]()
    var alpha = SIMD[DType.uint32, LW]()
    for k in range(LW):
        var ch = k % 4
        if ch == 0:
            cs[k] = UInt32(sr)
        elif ch == 1:
            cs[k] = UInt32(sg)
        elif ch == 2:
            cs[k] = UInt32(sb)
        keep[k] = UInt32(0) if ch == 3 else UInt32(0xFFFFFFFF)
        alpha[k] = UInt32(255) if ch == 3 else UInt32(0)
    return (cs, keep, alpha)


def _flat[
    LW: Int
](mut dst: List[UInt8], n: Int, sa: Int, sr: Int, sg: Int, sb: Int):
    """A flat translucent colour over an opaque destination: what
    `Canvas.fill translucent` does, source terms hoisted."""
    var d = dst.unsafe_ptr()
    var parts = _lanes[LW](sr, sg, sb)
    var sa_v = SIMD[DType.uint32, LW](UInt32(sa))
    var inv_v = SIMD[DType.uint32, LW](UInt32(255 - sa))
    var i = 0
    while i + LW <= n:
        var cb = d.unsafe_offset(i).unsafe_load[width=LW]().cast[DType.uint32]()
        var out = ((sa_v * parts[0] + inv_v * cb) * UInt32(MUL)) >> UInt32(SH)
        out = (out & parts[1]) | parts[2]
        d.unsafe_offset(i).unsafe_store(out.cast[DType.uint8]())
        i += LW


def _mul_span[
    LW: Int
](mut dst: List[UInt8], n: Int, sa: Int, sr: Int, sg: Int, sb: Int):
    """`div255(sa * div255(dst*src) + (255-sa) * dst)` per channel --
    the arithmetic a multiply span performs, destination opaque."""
    var d = dst.unsafe_ptr()
    var parts = _lanes[LW](sr, sg, sb)
    var sa_v = SIMD[DType.uint32, LW](UInt32(sa))
    var inv_v = SIMD[DType.uint32, LW](UInt32(255 - sa))
    var i = 0
    while i + LW <= n:
        var cb = d.unsafe_offset(i).unsafe_load[width=LW]().cast[DType.uint32]()
        var b = (cb * parts[0] * UInt32(MUL)) >> UInt32(SH)
        var out = ((sa_v * b + inv_v * cb) * UInt32(MUL)) >> UInt32(SH)
        out = (out & parts[1]) | parts[2]
        d.unsafe_offset(i).unsafe_store(out.cast[DType.uint8]())
        i += LW


def main() raises:
    var src = List[UInt8](length=NC, fill=170)
    var dst = List[UInt8](length=NC, fill=200)
    var sink = 0

    var a = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        _cheap(src, dst, NC)
        a.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[17 + (k & 3)])
    var cheap = _median(a^)

    var b = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        _exact(src, dst, NC)
        b.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[19 + (k & 3)])
    var exact = _median(b^)

    print("source-over over 800x600 (480,000 px):")
    print(
        "  published yardstick (uint16, >>8) ",
        String(round(cheap, 1)),
        "us =",
        String(round(cheap * 1000.0 / Float64(PXC), 3)),
        "ns/px",
    )
    print(
        "  the kernel's real arithmetic      ",
        String(round(exact, 1)),
        "us =",
        String(round(exact * 1000.0 / Float64(PXC), 3)),
        "ns/px",
    )
    print("  the yardstick is low by", String(round(exact / cheap, 2)) + "x")

    var c = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        _flat[W](dst, NR, 128, 30 + (k & 7), 40, 60)
        c.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[23 + (k & 3)])
    print("\nflat translucent over 600x400 (240,000 px):")
    print("  hoisted-source floor", String(round(_median(c^), 1)), "us")

    var m = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        _mul_span[16](dst, NR, 200, 30 + (k & 7), 40, 60)
        m.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[29 + (k & 3)])
    var m16 = _median(m^)
    m = List[Float64]()
    for k in range(9):
        var t0 = perf_counter_ns()
        _mul_span[32](dst, NR, 200, 30 + (k & 7), 40, 60)
        m.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += Int(dst[31 + (k & 3)])
    var m32 = _median(m^)
    print("\nmultiply over 600x400 (240,000 px), destination opaque:")
    print("  4 px/iter ", String(round(m16, 1)), "us")
    print("  8 px/iter ", String(round(m32, 1)), "us")
    print("  published floor (source-over arithmetic): 30.96 us")
    print("\nsink", sink != 0)

"""Machine constants for the roofline: every rate a floor is built
from, measured rather than quoted. See benchmarks/roofline.md.

Buffer is an 800x600 RGBA canvas (1.92 MB) unless a kernel says
otherwise, so the numbers drop straight into the bench rows.
"""
from std.time import perf_counter_ns
from std.runtime.asyncrt import TaskGroup


comptime N = 800 * 600 * 4
comptime PX = 800 * 600
comptime W = 32
comptime L1N = 16 * 1024


def _pad(s: String, n: Int, left: Bool = False) -> String:
    var out = s
    while out.byte_length() < n:
        if left:
            out = " " + out
        else:
            out = out + " "
    return out


def _median(var xs: List[Float64]) -> Float64:
    for i in range(1, len(xs)):
        var v = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > v:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = v
    return xs[len(xs) // 2]


# --- streaming ---------------------------------------------------
# `val` changes every iteration at the call site. Filling with a
# constant is loop-invariant and gets hoisted out of the timing loop,
# which reports an impossible 17 TB/s.
def _fill(mut dst: List[UInt8], n: Int, val: UInt8):
    var d = dst.unsafe_ptr()
    var v = SIMD[DType.uint8, W](val)
    var i = 0
    while i + W <= n:
        d.unsafe_offset(i).unsafe_store(v)
        i += W


def _copy(src: List[UInt8], mut dst: List[UInt8], n: Int):
    var s = src.unsafe_ptr()
    var d = dst.unsafe_ptr()
    var i = 0
    while i + W <= n:
        d.unsafe_offset(i).unsafe_store(
            s.unsafe_offset(i).unsafe_load[width=W]()
        )
        i += W


def _read(src: List[UInt8], n: Int) -> Int:
    var s = src.unsafe_ptr()
    var acc = SIMD[DType.uint8, W](0)
    var i = 0
    while i + W <= n:
        acc += s.unsafe_offset(i).unsafe_load[width=W]()
        i += W
    return Int(acc.reduce_add())


# --- per-pixel arithmetic ----------------------------------------
# Source-over as the library performs it: each pixel's alpha
# broadcast across its four lanes, widened to uint32, and an exact
# division by 255.
#
# An earlier version of this kernel used uint16 lanes, a `>>8`
# approximation and no broadcast. That is cheaper arithmetic than any
# correct implementation can use, and it under-priced every floor
# built on it by 6.3x (#350). Measure what the code must do, not the
# nearest convenient thing.
def _blend(src: List[UInt8], mut dst: List[UInt8], n: Int):
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
            ((num * UInt32(32897)) >> UInt32(23)).cast[DType.uint8]()
        )
        i += W


# The same arithmetic with no per-pixel branch removed -- a scalar
# loop, which is the floor for anything that cannot vectorize.
def _blend_scalar(src: List[UInt8], mut dst: List[UInt8], n: Int):
    var s = src.unsafe_ptr()
    var d = dst.unsafe_ptr()
    for i in range(n):
        var sv = UInt32(s[unsafe_offset=i])
        var dv = UInt32(d[unsafe_offset=i])
        var sa = UInt32(s[unsafe_offset=(i & ~3) + 3])
        if sv != 0:
            d[unsafe_offset=i] = UInt8(
                ((sv * sa + dv * (255 - sa)) * 32897) >> 23
            )


# --- Float64, the shape resize's two passes run in ---------------
def _f64_axpy(mut xs: List[Float64], k: Float64, n: Int):
    var p = xs.unsafe_ptr()
    var i = 0
    while i + 8 <= n:
        var v = p.unsafe_offset(i).unsafe_load[width=8]()
        p.unsafe_offset(i).unsafe_store(v * k + 1.0)
        i += 8


# --- scattered access, the shape a transform sample runs in ------
def _gather(src: List[UInt8], mut dst: List[UInt8], px: Int) -> Int:
    var s = src.unsafe_ptr()
    var d = dst.unsafe_ptr()
    var acc = 0
    var h = 12345
    for i in range(px):
        h = (h * 1103515245 + 12345) & 0x7FFFFFFF
        var off = (h % px) * 4
        acc += Int(s[unsafe_offset=off])
        d[unsafe_offset=(i * 4) % (px * 4)] = s[unsafe_offset=off]
    return acc


async def _nop_task():
    pass


async def _fill_band_async(mut dst: List[UInt8], lo: Int, hi: Int):
    var d = dst.unsafe_ptr()
    var v = SIMD[DType.uint8, W](7)
    var i = lo
    while i + W <= hi:
        d.unsafe_offset(i).unsafe_store(v)
        i += W


def _t(name: String, us: Float64, bytes: Float64, unit: String):
    var gbs = bytes / us * 1000.0
    print(
        "  ",
        _pad(name, 34),
        _pad(String(round(us, 2)), 9, True),
        " us  ",
        _pad(String(round(gbs, 1)), 7, True),
        unit,
    )


def main() raises:
    var src = List[UInt8](length=N, fill=200)
    var dst = List[UInt8](length=N, fill=100)
    var mb = Float64(N) / 1.0e6
    var iters = 200

    print("buffer:", String(round(mb, 2)), "MB =", PX, "px, serial\n")

    var sink0 = 0
    var ts = List[Float64]()
    for _ in range(9):
        var t0 = perf_counter_ns()
        for k in range(iters):
            _fill(dst, N, UInt8(k & 0xFF))
            sink0 += Int(dst[17])
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
    _t("fill (write only)", _median(ts^), mb, "GB/s")

    ts = List[Float64]()
    for _ in range(9):
        var t0 = perf_counter_ns()
        for _ in range(iters):
            _copy(src, dst, N)
            sink0 += Int(dst[19])
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
    _t("copy (read+write)", _median(ts^), 2.0 * mb, "GB/s")

    ts = List[Float64]()
    var sink = 0
    for _ in range(9):
        var t0 = perf_counter_ns()
        for _ in range(iters):
            sink += _read(src, N)
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
    _t("read (sum)", _median(ts^), mb, "GB/s")

    ts = List[Float64]()
    for _ in range(9):
        var t0 = perf_counter_ns()
        for _ in range(iters):
            _blend(src, dst, N)
            sink0 += Int(dst[23])
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
    var blend_us = _median(ts^)
    _t("blend SIMD (mul-add/byte)", blend_us, 2.0 * mb, "GB/s")
    print(
        "        = ",
        String(round(blend_us * 1000.0 / Float64(PX), 2)),
        "ns/px",
    )

    ts = List[Float64]()
    for _ in range(5):
        var t0 = perf_counter_ns()
        for _ in range(20):
            _blend_scalar(src, dst, N)
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / 20.0)
    var scal_us = _median(ts^)
    _t("blend scalar (branchy)", scal_us, 2.0 * mb, "GB/s")
    print(
        "        = ",
        String(round(scal_us * 1000.0 / Float64(PX), 2)),
        "ns/px  <- the cost of not vectorizing",
    )

    # L1-resident: ALU ceiling with memory removed.
    var s1 = List[UInt8](length=L1N, fill=200)
    var d1 = List[UInt8](length=L1N, fill=100)
    ts = List[Float64]()
    for _ in range(9):
        var t0 = perf_counter_ns()
        for _ in range(2000):
            _blend(s1, d1, L1N)
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / 2000.0)
    var l1 = _median(ts^)
    print(
        "   blend SIMD in L1                    ",
        String(round(l1 * 1000.0 / Float64(L1N // 4), 2)),
        "ns/px  <- ALU ceiling, no memory",
    )

    var f = List[Float64](length=PX, fill=1.5)
    ts = List[Float64]()
    for _ in range(9):
        var t0 = perf_counter_ns()
        for _ in range(iters):
            _f64_axpy(f, 1.000001, PX)
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
    var fus = _median(ts^)
    print(
        "   f64 axpy over",
        PX,
        "doubles          ",
        String(round(fus, 1)),
        "us  <- resize's intermediate shape",
    )

    ts = List[Float64]()
    for _ in range(5):
        var t0 = perf_counter_ns()
        for _ in range(20):
            sink += _gather(src, dst, PX)
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / 20.0)
    var g = _median(ts^)
    print(
        "   scattered 1px sample x",
        PX,
        "  ",
        String(round(g, 1)),
        "us =",
        String(round(g * 1000.0 / Float64(PX), 2)),
        "ns/px",
    )

    # Dispatch: what a TaskGroup costs before any work happens.
    print("\ndispatch (empty tasks):")
    for bands in [1, 2, 4, 8, 16, 32, 64, 128]:
        ts = List[Float64]()
        for _ in range(9):
            var t0 = perf_counter_ns()
            for _ in range(iters):
                var tg = TaskGroup()
                for _ in range(bands):
                    tg.create_task(_nop_task())
                tg.wait()
            ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
        print(
            "  ",
            _pad(String(bands), 4, True),
            "tasks ",
            _pad(String(round(_median(ts^), 1)), 7, True),
            "us",
        )

    # Banded fill: dispatch plus real work, the shape a banded op runs.
    print("\nbanded fill 1.92 MB (dispatch + work):")
    for bands in [1, 2, 4, 8, 16, 32, 64]:
        var per = (N + bands - 1) // bands
        ts = List[Float64]()
        for _ in range(9):
            var t0 = perf_counter_ns()
            for _ in range(iters):
                var tg = TaskGroup()
                for b in range(bands):
                    var lo = b * per
                    var hi = min(lo + per, N)
                    if lo < hi:
                        tg.create_task(_fill_band_async(dst, lo, hi))
                tg.wait()
                _ = len(dst)
            ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
        var v = _median(ts^)
        print(
            "  ",
            _pad(String(bands), 4, True),
            "bands ",
            _pad(String(round(v, 1)), 7, True),
            "us  =",
            _pad(String(round(mb / v * 1000.0, 1)), 7, True),
            "GB/s",
        )
    print("\nsink", sink != 0, sink0 != 0)

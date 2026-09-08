"""Does the same loop run at the same speed inside an async task?

Every variant fills the whole buffer with a value that changes each
iteration, so none of it is loop-invariant and none can be hoisted.
"""
from std.time import perf_counter_ns
from std.runtime.asyncrt import TaskGroup

comptime N = 800 * 600 * 4
comptime W = 32


def _median(var xs: List[Float64]) -> Float64:
    for i in range(1, len(xs)):
        var v = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > v:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = v
    return xs[len(xs) // 2]


def _fill_range(mut dst: List[UInt8], lo: Int, hi: Int, val: UInt8):
    var d = dst.unsafe_ptr()
    var v = SIMD[DType.uint8, W](val)
    var i = lo
    while i + W <= hi:
        d.unsafe_offset(i).unsafe_store(v)
        i += W
    while i < hi:
        d[unsafe_offset=i] = val
        i += 1


async def _fill_range_async(mut dst: List[UInt8], lo: Int, hi: Int, val: UInt8):
    _fill_range(dst, lo, hi, val)


# A second async variant with the loop written inline rather than
# delegating, in case the call is what differs.
async def _fill_inline_async(
    mut dst: List[UInt8], lo: Int, hi: Int, val: UInt8
):
    var d = dst.unsafe_ptr()
    var v = SIMD[DType.uint8, W](val)
    var i = lo
    while i + W <= hi:
        d.unsafe_offset(i).unsafe_store(v)
        i += W
    while i < hi:
        d[unsafe_offset=i] = val
        i += 1


def main() raises:
    var dst = List[UInt8](length=N, fill=0)
    var iters = 200
    var sink = 0
    var mb = Float64(N) / 1.0e6

    var ts = List[Float64]()
    for _ in range(9):
        var t0 = perf_counter_ns()
        for k in range(iters):
            _fill_range(dst, 0, N, UInt8(k & 0xFF))
            sink += Int(dst[17])
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
    var direct = _median(ts^)
    print(
        "  direct call, whole buffer   ",
        String(round(direct, 1)),
        "us =",
        String(round(mb / direct * 1000.0, 1)),
        "GB/s",
    )

    ts = List[Float64]()
    for _ in range(9):
        var t0 = perf_counter_ns()
        for k in range(iters):
            var tg = TaskGroup()
            tg.create_task(_fill_range_async(dst, 0, N, UInt8(k & 0xFF)))
            tg.wait()
            sink += Int(dst[17])
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
    var one = _median(ts^)
    print(
        "  1 async task, whole buffer  ",
        String(round(one, 1)),
        "us =",
        String(round(mb / one * 1000.0, 1)),
        "GB/s",
    )

    ts = List[Float64]()
    for _ in range(9):
        var t0 = perf_counter_ns()
        for k in range(iters):
            var tg = TaskGroup()
            tg.create_task(_fill_inline_async(dst, 0, N, UInt8(k & 0xFF)))
            tg.wait()
            sink += Int(dst[17])
        ts.append(Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters))
    var inl = _median(ts^)
    print(
        "  1 async task, inline loop   ",
        String(round(inl, 1)),
        "us =",
        String(round(mb / inl * 1000.0, 1)),
        "GB/s",
    )

    print("\n  bands (async), whole buffer split:")
    for bands in [1, 2, 4, 8, 16, 32, 64]:
        var per = (N + bands - 1) // bands
        ts = List[Float64]()
        for _ in range(9):
            var t0 = perf_counter_ns()
            for k in range(iters):
                var tg = TaskGroup()
                for b in range(bands):
                    var lo = b * per
                    var hi = min(lo + per, N)
                    if lo < hi:
                        tg.create_task(
                            _fill_range_async(dst, lo, hi, UInt8(k & 0xFF))
                        )
                tg.wait()
                sink += Int(dst[17])
            ts.append(
                Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters)
            )
        var v = _median(ts^)
        print(
            "   ", bands, "bands ", String(round(v, 1)),
            "us =", String(round(mb / v * 1000.0, 1)), "GB/s",
        )

    # Serial loop over the same band split, no tasks at all: isolates
    # the split from the dispatch.
    print("\n  bands (serial loop over the same split):")
    for bands in [1, 8, 64]:
        var per = (N + bands - 1) // bands
        ts = List[Float64]()
        for _ in range(9):
            var t0 = perf_counter_ns()
            for k in range(iters):
                for b in range(bands):
                    var lo = b * per
                    var hi = min(lo + per, N)
                    if lo < hi:
                        _fill_range(dst, lo, hi, UInt8(k & 0xFF))
                sink += Int(dst[17])
            ts.append(
                Float64(perf_counter_ns() - t0) / 1000.0 / Float64(iters)
            )
        var v = _median(ts^)
        print(
            "   ", bands, "bands ", String(round(v, 1)),
            "us =", String(round(mb / v * 1000.0, 1)), "GB/s",
        )
    print("\nsink", sink != 0)

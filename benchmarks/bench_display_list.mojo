"""Record/storage cost and paired direct/replay timing for retained scenes.

Run on the release compiler on a quiet machine. The arms are paired inside
one process, reversing their order each round; quote the median of their
ratios. Recording allocations differ from playback, so recording is timed
separately. Set CANVAS_DISPLAY_LIST_ARM=direct or replay for separate-process timing
when comparing arms that differ in allocation work. Storage estimates exclude allocator metadata/string spare
capacity; list-buffer counts are live allocations, not malloc-call counts.
"""

from std.os import getenv
from std.time import perf_counter_ns
from std.math import sin
from canvas import (
    Canvas,
    Color,
    DrawTarget,
    DisplayList,
    FontCache,
    TextRun,
    Path,
    LineCap,
    SvgCanvas,
)
from canvas.geometry import FPoint
from canvas.io.png import write_png

comptime PAPER = Color(250, 250, 250)
comptime INK = Color(30, 70, 150)
comptime ROUNDS = 200


def _icon[T: DrawTarget](mut t: T, mut cache: FontCache) raises:
    t.save()
    t.begin_batch()
    t.fill_circle_aa(16.0, 16.0, 12.0, INK)
    t.draw_line_aa(9.0, 16.0, 14.0, 21.0, PAPER, width=2.5, cap=LineCap.ROUND)
    t.draw_line_aa(14.0, 21.0, 23.0, 11.0, PAPER, width=2.5, cap=LineCap.ROUND)
    t.end_batch()
    t.restore()


def _chart[T: DrawTarget](mut t: T, mut cache: FontCache) raises:
    t.save()
    t.draw_text(40.0, 25.0, "Retained chart", INK, 18.0, cache=cache)
    t.push_clip(40, 40, 440, 250)
    t.begin_batch()
    for i in range(32):
        var h = 70.0 + 45.0 * sin(Float64(i) * 0.5)
        t.fill_rect(45.0 + Float64(i) * 13.0, 270.0 - h, 8.0, h, INK)
    t.end_batch()
    var series = Path()
    series.move_to(45.0, 130.0)
    var centers = List[FPoint]()
    for i in range(200):
        var x = 45.0 + Float64(i) * 2.0
        var y = 110.0 + 35.0 * sin(Float64(i) * 0.05)
        series.line_to(x, y)
        centers.append(FPoint(x, y))
    t.stroke_path_aa(series, Color(210, 80, 40), width=2.0)
    t.fill_circles_aa(centers, 2.0, Color(210, 80, 40))
    t.pop_clip()
    var image = Canvas(8, 8, Color(40, 130, 80))
    var runs: List[TextRun] = [TextRun("x", 12.0), TextRun("2", 8.0, dy=-4.0)]
    for i in range(8):
        t.draw_image(image, 45.0 + Float64(i) * 50.0, 300.0)
        t.draw_text_runs(
            58.0 + Float64(i) * 50.0, 310.0, runs, INK, cache=cache
        )
    t.restore()


def _draw[T: DrawTarget](mut t: T, kind: Int, mut cache: FontCache) raises:
    if kind == 0:
        _icon(t, cache)
    else:
        _chart(t, cache)


def _median(values: List[Float64]) -> Float64:
    var sorted = values.copy()
    for i in range(1, len(sorted)):
        var v = sorted[i]
        var j = i
        while j > 0 and sorted[j - 1] > v:
            sorted[j] = sorted[j - 1]
            j -= 1
        sorted[j] = v
    return (sorted[len(sorted) // 2 - 1] + sorted[len(sorted) // 2]) * 0.5


def _measure(kind: Int, mut sink: Int) raises:
    var cache = FontCache()
    var list = DisplayList()
    _draw(list, kind, cache)
    var width = 32 if kind == 0 else 520
    var height = 32 if kind == 0 else 340
    var direct = Canvas(width, height, PAPER)
    var replayed = Canvas(width, height, PAPER)
    _draw(direct, kind, cache)
    list.replay(replayed, cache=cache)
    if direct.pixels != replayed.pixels:
        raise Error("bench_display_list: direct/replay buffers differ")
    write_png(
        replayed,
        "/tmp/display_list_icon.png" if kind
        == 0 else "/tmp/display_list_chart.png",
    )
    var svg = SvgCanvas(width, height)
    list.replay(svg, cache=cache)
    if "<circle" not in svg.to_string() and kind == 0:
        raise Error("bench_display_list: native SVG shape missing")
    var record_times = List[Float64]()
    var direct_times = List[Float64]()
    var replay_times = List[Float64]()
    var ratios = List[Float64]()
    var mode = getenv("CANVAS_DISPLAY_LIST_ARM", "paired")
    if mode != "paired" and mode != "direct" and mode != "replay":
        raise Error("CANVAS_DISPLAY_LIST_ARM must be paired, direct or replay")
    for _ in range(ROUNDS):
        var t0 = perf_counter_ns()
        var recorded = DisplayList()
        _draw(recorded, kind, cache)
        record_times.append(Float64(perf_counter_ns() - t0) / 1000.0)
        sink += recorded.command_count() + recorded.resource_count()
    for round_index in range(ROUNDS):
        var direct_us = 0.0
        var replay_us = 0.0
        for arm in range(2):
            var replay_arm = (round_index + arm) % 2 == 1
            if (mode == "direct" and replay_arm) or (
                mode == "replay" and not replay_arm
            ):
                continue
            if replay_arm:
                replayed.fill(PAPER)
                var t0 = perf_counter_ns()
                list.replay(replayed, cache=cache)
                replay_us = Float64(perf_counter_ns() - t0) / 1000.0
            else:
                direct.fill(PAPER)
                var t0 = perf_counter_ns()
                _draw(direct, kind, cache)
                direct_us = Float64(perf_counter_ns() - t0) / 1000.0
        if mode != "replay":
            direct_times.append(direct_us)
        if mode != "direct":
            replay_times.append(replay_us)
        if mode == "paired":
            ratios.append(replay_us / direct_us)
        # Verify real output each round, outside timing; no sampled checksum.
        if direct.pixels != replayed.pixels:
            raise Error("bench_display_list: paired outputs differ")
        sink += Int(replayed.pixels[round_index % len(replayed.pixels)])
    print("icon" if kind == 0 else "chart")
    print(
        "  commands/resources/list_buffers/storage_estimate_bytes:",
        list.command_count(),
        list.resource_count(),
        list.list_buffer_count(),
        list.storage_bytes(),
    )
    if mode != "paired":
        print("  isolated arm:", mode)
        print(
            "  median record/arm us:",
            _median(record_times),
            _median(direct_times) if mode
            == "direct" else _median(replay_times),
        )
        return
    print(
        "  median record/direct/replay us:",
        _median(record_times),
        _median(direct_times),
        _median(replay_times),
    )
    print("  median paired replay/direct:", _median(ratios))
    var lo = ratios[0]
    var hi = ratios[0]
    for value in ratios:
        lo = min(lo, value)
        hi = max(hi, value)
    print("  paired ratio range:", lo, hi)


def main() raises:
    var sink = 0
    _measure(0, sink)
    _measure(1, sink)
    print("sink:", sink)

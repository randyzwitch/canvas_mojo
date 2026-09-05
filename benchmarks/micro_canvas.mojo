"""Interleaved micro-benchmarks for one primitive at a time, run with
`pixi run micro`. The companion to bench_canvas.mojo: that file is the
survey, this one is the gate for a change to a single primitive.

## Why a second harness

bench_canvas.mojo times each case once, in a fixed order, after a
warm-up. On a shared machine the parallel sweeps vary by 20% or more
between runs, which is wider than most single optimizations move a
number. Two things bring that down:

- Rounds. Each case is timed `rounds` times, `iters` iterations per
  round, and the median is reported with the interquartile range. A
  slow round from another process lands in the tail and not in the
  number.
- Interleaving. `compare` alternates two cases round by round, so
  both see the same machine state, thermal and otherwise, and their
  ratio is stable even when their absolute times drift together.

## Reading the table

`median` is nanoseconds per iteration; `iqr` is the spread of the
middle half of the rounds as a fraction of the median. Quote the
median; treat a change smaller than the larger of the two iqr values
as noise. A `compare` block prints the ratio of medians last.

## Adding a case

A case is a struct conforming to `MicroCase`: `name` and a `run` that
does one iteration and folds a pixel into `sink`, so the optimizer
cannot delete the drawing. Then call `measure` on it, or `compare` on
it and a second case. Cases that hold a canvas draw into it
repeatedly; that is fine, the cost being measured is the primitive,
not a fresh surface.
"""

from std.time import perf_counter_ns

from canvas.blend import BlendMode
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.path import Path, fill_path_aa
from canvas.shapes.lines import draw_line, draw_line_aa
from canvas.shapes.rects import fill_rect
from canvas.text.font_cache import FontCache
from canvas.text.render import draw_text

comptime W = 800
comptime H = 600
comptime WHITE = Color(255, 255, 255)
comptime INK = Color(30, 60, 120)


trait MicroCase:
    def name(self) -> String:
        ...

    def run(mut self, mut sink: Int) raises:
        ...


struct _Stats(ImplicitlyCopyable, Movable):
    """The median and interquartile range of a case's rounds, in
    nanoseconds per iteration.
    """

    var median: Float64
    var iqr: Float64

    def __init__(out self, median: Float64, iqr: Float64):
        self.median = median
        self.iqr = iqr


def _sorted(values: List[Float64]) -> List[Float64]:
    var out = values.copy()
    for i in range(1, len(out)):
        var v = out[i]
        var j = i
        while j > 0 and out[j - 1] > v:
            out[j] = out[j - 1]
            j -= 1
        out[j] = v
    return out^


def _quantile(sorted_values: List[Float64], q: Float64) -> Float64:
    """Linear interpolation between the two ranks `q` falls between."""
    var n = len(sorted_values)
    if n == 1:
        return sorted_values[0]
    var pos = q * Float64(n - 1)
    var lo = Int(pos)
    var hi = lo + 1 if lo + 1 < n else lo
    var frac = pos - Float64(lo)
    return sorted_values[lo] + frac * (sorted_values[hi] - sorted_values[lo])


def _stats(rounds_ns: List[Float64]) -> _Stats:
    var s = _sorted(rounds_ns)
    var median = _quantile(s, 0.5)
    var iqr = _quantile(s, 0.75) - _quantile(s, 0.25)
    return _Stats(median, iqr / median if median > 0.0 else 0.0)


def _time_round[C: MicroCase](mut subject: C, iters: Int, mut sink: Int) raises -> Float64:
    var t0 = perf_counter_ns()
    for _ in range(iters):
        subject.run(sink)
    return Float64(perf_counter_ns() - t0) / Float64(iters)


def _fixed(value: Float64, places: Int) -> String:
    var scale = 1.0
    for _ in range(places):
        scale *= 10.0
    var scaled = Int(value * scale + 0.5)
    var whole = scaled // Int(scale)
    var frac = scaled % Int(scale)
    var frac_text = String(frac)
    while frac_text.byte_length() < places:
        frac_text = "0" + frac_text
    return String(whole) + "." + frac_text


def _pad(text: String, width: Int) -> String:
    var out = text
    while out.byte_length() < width:
        out += " "
    return out


def _lpad(text: String, width: Int) -> String:
    var out = text
    while out.byte_length() < width:
        out = " " + out
    return out


def _print_row(name: String, s: _Stats, rounds: Int, iters: Int):
    print(
        _pad(name, 44),
        _lpad(String(rounds) + "x" + String(iters), 9),
        _lpad(_fixed(s.median / 1000.0, 3) + " us", 14),
        _lpad("iqr " + _fixed(s.iqr * 100.0, 1) + "%", 12),
    )


def measure[
    C: MicroCase
](mut subject: C, mut sink: Int, rounds: Int = 9, iters: Int = 200) raises -> _Stats:
    """Time `case` for `rounds` rounds of `iters` iterations, after one
    warm-up round, and print its median and spread.

    Args:
        subject: The primitive to time.
        sink: Accumulates a pixel per iteration so the work survives.
        rounds: Timed rounds; the median is over these.
        iters: Iterations per round.

    Returns:
        The median and interquartile range.
    """
    _ = _time_round(subject, iters, sink)
    var samples = List[Float64]()
    for _ in range(rounds):
        samples.append(_time_round(subject, iters, sink))
    var s = _stats(samples)
    _print_row(subject.name(), s, rounds, iters)
    return s


def compare[
    A: MicroCase, B: MicroCase
](mut a: A, mut b: B, mut sink: Int, rounds: Int = 9, iters: Int = 200) raises:
    """Time `a` and `b` interleaved, one round of each in turn, after a
    warm-up round of each, and print both with the ratio of medians
    (`b` over `a`).

    Args:
        a: The baseline.
        b: The variant.
        sink: Accumulates a pixel per iteration so the work survives.
        rounds: Timed rounds per case.
        iters: Iterations per round.
    """
    _ = _time_round(a, iters, sink)
    _ = _time_round(b, iters, sink)
    var sa = List[Float64]()
    var sb = List[Float64]()
    for _ in range(rounds):
        sa.append(_time_round(a, iters, sink))
        sb.append(_time_round(b, iters, sink))
    var ra = _stats(sa)
    var rb = _stats(sb)
    _print_row(a.name(), ra, rounds, iters)
    _print_row(b.name(), rb, rounds, iters)
    print(
        _pad("  ratio, second over first", 44),
        _lpad("", 9),
        _lpad(_fixed(rb.median / ra.median, 2) + "x", 14),
    )
    print("")


# --- cases ----------------------------------------------------------


struct FillRectOpaque(Movable, MicroCase):
    var canvas: Canvas

    def __init__(out self) raises:
        self.canvas = Canvas(W, H, WHITE)

    def name(self) -> String:
        return "fill_rect 600x400 opaque"

    def run(mut self, mut sink: Int) raises:
        fill_rect(self.canvas, 40, 40, 600, 400, INK)
        sink += Int(self.canvas.get_pixel(50, 50).r)


struct FillRectMultiply(Movable, MicroCase):
    var canvas: Canvas

    def __init__(out self) raises:
        self.canvas = Canvas(W, H, WHITE)
        self.canvas.set_blend_mode(BlendMode.MULTIPLY)

    def name(self) -> String:
        return "fill_rect 600x400 multiply"

    def run(mut self, mut sink: Int) raises:
        fill_rect(self.canvas, 40, 40, 600, 400, INK)
        sink += Int(self.canvas.get_pixel(50, 50).r)


struct LineHairline(Movable, MicroCase):
    var canvas: Canvas

    def __init__(out self) raises:
        self.canvas = Canvas(W, H, WHITE)

    def name(self) -> String:
        return "draw_line diagonal (Bresenham)"

    def run(mut self, mut sink: Int) raises:
        draw_line(self.canvas, 30, 30, 770, 570, INK)
        sink += Int(self.canvas.get_pixel(400, 300).r)


struct LineAaDiagonal(Movable, MicroCase):
    var canvas: Canvas

    def __init__(out self) raises:
        self.canvas = Canvas(W, H, WHITE)

    def name(self) -> String:
        return "draw_line_aa diagonal w=2"

    def run(mut self, mut sink: Int) raises:
        draw_line_aa(self.canvas, 30.0, 30.0, 770.0, 570.0, INK, width=2.0)
        sink += Int(self.canvas.get_pixel(400, 300).r)


struct LineAaHorizontal(Movable, MicroCase):
    """The same length as the diagonal, along one row band: if the
    sweep is sized to the bounding box, this is much cheaper.
    """

    var canvas: Canvas

    def __init__(out self) raises:
        self.canvas = Canvas(W, H, WHITE)

    def name(self) -> String:
        return "draw_line_aa horizontal w=2, same length"

    def run(mut self, mut sink: Int) raises:
        # sqrt(740^2 + 540^2) = 916: the diagonal's length, laid flat.
        draw_line_aa(self.canvas, 0.0, 300.0, 916.0, 300.0, INK, width=2.0)
        sink += Int(self.canvas.get_pixel(400, 300).r)


struct FillPathGlyphSized(Movable, MicroCase):
    """A quadrilateral the size of a glyph, filled through the
    exact-area path: the small-shape end of the rasterizer, where
    per-call overhead is most of the cost.
    """

    var canvas: Canvas
    var path: Path

    def __init__(out self) raises:
        self.canvas = Canvas(W, H, WHITE)
        self.path = Path()
        self.path.move_to(50.3, 40.2)
        self.path.line_to(62.7, 41.0)
        self.path.line_to(66.1, 70.4)
        self.path.line_to(48.9, 68.8)
        self.path.close()

    def name(self) -> String:
        return "fill_path_aa glyph-sized quad"

    def run(mut self, mut sink: Int) raises:
        fill_path_aa(self.canvas, self.path, INK, FillRule.NONZERO)
        sink += Int(self.canvas.get_pixel(55, 55).r)


struct TextCached(Movable, MicroCase):
    var canvas: Canvas
    var cache: FontCache

    def __init__(out self) raises:
        self.canvas = Canvas(W, H, WHITE)
        self.cache = FontCache()

    def name(self) -> String:
        return "draw_text 'Revenue 2024' cached"

    def run(mut self, mut sink: Int) raises:
        draw_text(
            self.canvas, 100, 100, "Revenue 2024", INK, 14.0, cache=self.cache
        )
        sink += Int(self.canvas.get_pixel(104, 96).r)


struct TextScaled(Movable, MicroCase):
    """The same label under scale(3, 3), which today takes the direct
    outline fill rather than the glyph mask cache (#240).
    """

    var canvas: Canvas
    var cache: FontCache

    def __init__(out self) raises:
        self.canvas = Canvas(W, H, WHITE)
        self.cache = FontCache()
        self.canvas.scale(3.0, 3.0)

    def name(self) -> String:
        return "draw_text same label under scale(3)"

    def run(mut self, mut sink: Int) raises:
        draw_text(
            self.canvas, 33, 33, "Revenue 2024", INK, 14.0, cache=self.cache
        )
        sink += Int(self.canvas.get_pixel(104, 96).r)


struct TextLarge(Movable, MicroCase):
    """The scaled label's size drawn unscaled: what the cached path
    costs for the same ink, the target #240 aims at.
    """

    var canvas: Canvas
    var cache: FontCache

    def __init__(out self) raises:
        self.canvas = Canvas(W, H, WHITE)
        self.cache = FontCache()

    def name(self) -> String:
        return "draw_text same label at 42px, unscaled"

    def run(mut self, mut sink: Int) raises:
        draw_text(
            self.canvas, 100, 100, "Revenue 2024", INK, 42.0, cache=self.cache
        )
        sink += Int(self.canvas.get_pixel(104, 96).r)


def main() raises:
    var sink = 0
    print("")
    print(
        _pad("case", 44),
        _lpad("rounds", 9),
        _lpad("median", 14),
        _lpad("spread", 12),
    )
    print("")

    var rect_a = FillRectOpaque()
    var rect_b = FillRectMultiply()
    compare(rect_a, rect_b, sink, rounds=9, iters=50)

    var line_a = LineHairline()
    var line_b = LineAaDiagonal()
    compare(line_a, line_b, sink, rounds=9, iters=200)

    var line_h = LineAaHorizontal()
    var line_d = LineAaDiagonal()
    compare(line_h, line_d, sink, rounds=9, iters=200)

    var small = FillPathGlyphSized()
    _ = measure(small, sink, rounds=9, iters=2000)
    print("")

    var text_a = TextCached()
    var text_b = TextScaled()
    compare(text_a, text_b, sink, rounds=9, iters=100)

    var text_l = TextLarge()
    _ = measure(text_l, sink, rounds=9, iters=100)

    print("")
    print("sink", sink)

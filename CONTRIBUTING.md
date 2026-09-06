# Contributing to canvas_mojo

Thanks for looking. This document covers how the package is put
together, the Mojo language features you will meet in it, and the
conventions a change is expected to hold to.

If you only read one section, read [The DrawTarget trait, and why the
package works](#the-drawtarget-trait-and-why-the-package-works).

## Getting set up

Everything runs through [pixi](https://pixi.sh); there is no other build
step.

```sh
pixi run test      # every file in tests/, in parallel
pixi run example   # every file in examples/, writes examples/out_*.{bmp,png}
pixi run docs      # regenerates and serves docs/ -- run `example` first
```

Both `test` and `example` fan out through `scripts/run_parallel.sh`,
capped at the machine's real core count. Each test and example file has
its own `main()` and runs standalone, so you can also run one directly:

```sh
pixi run mojo run -I . tests/test_circles.mojo
```

There are no external library dependencies — nothing is linked, and
nothing is dlopen'd. There is still an external *data* dependency:
installed font files. Text tests need a `Sans`-resolvable system font,
and the font-fallback tests additionally need the `Ubuntu` and `DejaVu
Sans` families installed, since they turn on one having a glyph the
other lacks. See `.github/workflows/ci.yml` for the exact font packages
CI installs. Point `CANVAS_MOJO_FONT_PATH` (colon-separated
directories) at a font tree in a nonstandard prefix if the platform
defaults in `text/font_discovery.mojo` do not cover yours.

## The DrawTarget trait, and why the package works

`DrawTarget` (`canvas/vector/draw_target.mojo`) is the load-bearing
idea in this package. It declares ten drawing primitives, plus two
methods that label rather than draw:

```mojo
trait DrawTarget:
    def fill_rect(mut self, x: Int, y: Int, width: Int, height: Int, color: Color): ...
    def fill_rect_gradient(mut self, ..., gradient: LinearGradient): ...
    def draw_line_aa(mut self, ..., width: Float64 = 1.0): ...
    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color): ...
    def draw_circle_aa(mut self, cx: Float64, cy: Float64, radius: Float64, color: Color, width: Float64 = 1.0): ...
    def fill_ellipse_aa(mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color): ...
    def draw_ellipse_aa(mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color): ...
    def draw_ellipse_aa(mut self, cx: Float64, cy: Float64, rx: Float64, ry: Float64, color: Color, width: Float64 = 1.0): ...
    def fill_arc_aa(mut self, ...): ...
    def fill_ring_sector_aa(mut self, ...): ...
    def stroke_path_aa(mut self, path: Path, color: Color, width: Float64 = 1.0): ...
    def fill_path_aa(mut self, path: Path, color: Color): ...
    def begin_annotated_group(mut self, title: String): ...
    def end_annotated_group(mut self): ...
```

Two backends implement it, and they work in completely different ways:

- **`Canvas`** (`canvas/buffer.mojo`) owns an RGB pixel buffer.
  Its methods delegate to the free functions in `canvas.shapes`
  and `canvas.path`, which rasterize with supersampled coverage
  math.
- **`SvgCanvas`** (`canvas/vector/svg.mojo`) owns a string. Its
  methods append markup. There is no anti-aliasing math anywhere in it,
  because an SVG renderer does that itself, at whatever resolution it
  displays at.

A caller written against the trait — a chart library's rendering core,
say — targets either without knowing which it holds. That is the whole
payoff, and it constrains what may join the trait:

**Only operations both backends can express belong in `DrawTarget`.**
Text is the instructive exclusion. `Canvas` rasterizes glyph outlines
through `fill_path_aa`; `SvgCanvas` emits a `<text>` element and never
touches an outline. There is no shared operation to generalize, so
`draw_text` is a free function for raster and a method on `SvgCanvas`
for vector, and a generic caller collects text as plain data (position,
string, color, size, alignment) and lets each backend draw it outside
the generic path.

`begin_annotated_group`/`end_annotated_group` look like a violation of
that and are not, for a reason worth stating precisely. `SvgCanvas`
emits `<g><title>`; `Canvas` does nothing at all. The line is whether a
backend's *inability* is lossy:

- Text is lossy to drop, and each backend has to do something
  different, so there is nothing to generalize — it stays off the
  trait.
- A group label is lossless to drop. A raster image has no per-shape
  metadata for a reader to lose, so ignoring the label costs nothing
  that existed. The caller gets tooltips where tooltips are possible
  and identical pixels where they are not, without branching on the
  backend.

So a no-op implementation is acceptable when the operation adds
*metadata* a backend has no place for, and is not acceptable when it
adds *drawing* a backend would then silently omit. If you are proposing
a trait method one backend would no-op, that is the question to answer
first.

Two further consequences worth knowing before you propose an addition:

- **The trait is deliberately narrow.** No `fill_polygon`, no dashes,
  clipping, radial gradients, or path-shaped gradients. Each exists in
  the package as a free function or `Canvas` method; none has a
  concrete caller *through the trait*. Add to the trait when something
  concrete needs it, not before — every addition is a method both
  backends must implement forever.
- **The ellipse is where "use `fill_path_aa`/`stroke_path_aa`" stops
  being the answer.** Every other shape left off the trait is left off
  because one of those two covers it. An ellipse is the case where
  that fails: `Path.arc_to` takes a single `radius`, so it builds
  circular arcs only, and an ellipse can only be *approximated*
  through `Path`, with cubics. "Use `fill_path_aa`" is the right
  answer for a triangle or a star; it is not for an ellipse.
  `draw_circle_aa` has no such gap -- a stroked circular `Path` is
  exact -- and joined the trait instead for parity with
  `fill_circle_aa` and with the sub-pixel, width-taking overloads
  `Canvas` already had as free functions (#194). Circle and ellipse
  are the two shapes here carrying both a fill and an outline.
- **Trait parameters are trimmed.** No `supersample`, `dashes`, or
  `fill_rule`. A raster implementation picks its own supersample factor
  internally; a vector one has no equivalent knob to expose.

Conformance in Mojo is **nominal, not structural**: `Canvas` and
`SvgCanvas` each name `DrawTarget` in their struct signature
(`struct Canvas(Copyable, DrawTarget, Movable)`). Implementing the
methods is not enough; the declaration is what makes it conform.

## Mojo features you will meet here

This package is written in plain Mojo with no macros or metaprogramming
beyond what's listed here.

### Argument conventions

Mojo makes ownership explicit in the signature. Reading it correctly is
most of understanding a function here.

| Form | Meaning | Example in this repo |
|---|---|---|
| `x: Int` (bare) | immutable borrow, the default | every coordinate parameter |
| `mut canvas: Canvas` | mutable borrow — the caller keeps it | every drawing primitive |
| `var pixels: List[UInt8]` | transfers ownership into the function | `Canvas.__init__`, `inflate()` |
| `out self` | the value being constructed | every `__init__` |
| `ref span = spans[i]` | a reference to an element, no copy | `_spans_from_crossings` |
| `value^` | transfer sigil, moves rather than copies | `return out^`, `self.lines = lines^` |

`raises` is part of the signature too, and propagates: a function
calling a `raises` function must itself be `raises`.

### Value-semantics traits on structs

Structs declare how they copy and move:

- `ImplicitlyCopyable, Movable` — small value types (`Color`, `Point`,
  `_Crossing`). The common case.
- `Movable` alone — anything owning a heap buffer that should not be
  copied silently (`Path`, `TTFFace`, `RawGlyphOutline`, `_BlockLayout`).
- `Copyable` added — when an explicit `.copy()` is wanted.

**`List[T]` is not implicitly copyable.** This shapes real code: you
either move it (`^`), borrow it, or call `.copy()` explicitly. When you
see `out.extend(cur_row.copy())` in `io/png.mojo`, that `.copy()` is
load-bearing, and the bulk copy is deliberately chosen over a per-byte
append loop.

### `comptime` for constants and enum-like types

Mojo has no `enum`. The package uses a consistent stand-in: a struct
wrapping a private `Int`, with `comptime` constants, `__eq__`, and a
`write_to` that prints the constant's name -- the last so that
`assert_equal(x, FillRule.NONZERO)` compiles and says what it found.

```mojo
struct FillRule(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    var _value: Int

    comptime EVEN_ODD = Self(0)
    comptime NONZERO = Self(1)

    def __init__(out self, value: Int):
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def write_to[W: Writer](self, mut writer: W):
        if self._value == Self.EVEN_ODD._value:
            writer.write("EVEN_ODD")
        elif self._value == Self.NONZERO._value:
            writer.write("NONZERO")
        else:
            writer.write("FillRule(", self._value, ")")

    def __str__(self) -> String:
        var out = String()
        out.write(self)
        return out
```

`FillRule`, `TextAlign`, `FontSlant`, `FontWeight`, `LineCap`,
`LineJoin`, `BlendMode`, `Extend`, `Hatch`, `Filter` and `PathOp` all
follow this exactly. New enum-like types should too.

`comptime` also carries file-scope constants (`_SVG_DECIMALS`,
`_FC_WEIGHT_BOLD`, `_MIN_MATCH`). One limitation to know:
**`comptime List[Int]` does not materialize to a usable runtime value**
in the current Mojo version. `io/deflate.mojo` and `text/bidi.mojo` both
rebuild small lists per call because of it, with a comment saying so.

### `ArcPointer` for shared ownership

`text/font_cache.mojo` caches parsed fonts as `ArcPointer[TTFFace]`
rather than `TTFFace`, because `TTFFace` owns the whole font file's
bytes and is `Movable` only. A cache hit bumps an atomic refcount and
copies a pointer; call sites dereference with `[]` (`face[]`). Reach for
this when you need shared ownership of something expensive — not as a
general-purpose escape from the ownership rules.

### No mutable global state

Declaring one raises `global variables are not supported`. This is why
`FontCache` is threaded explicitly through a keyword-only `cache=`
parameter instead of living behind the scenes:

```mojo
def measure_text(..., *, mut cache: FontCache) raises -> TextMetrics:
```

Anything that would be a module-level singleton elsewhere has to be
constructed by the caller and passed down here.

### Tasks borrow; the compiler does not count it

Mojo destroys a value right after its last use. A `TaskGroup` task
that borrows a local (`tg.create_task(work(acc, ...))`) is not a use
the compiler tracks, so a value named for the last time inside the
task-creation loop is freed before `tg.wait()` returns, while the
tasks still read it. It shows up as rare wrong output on two to four
cores, not as a crash: the freed block's first bytes take allocator
bookkeeping, so whatever lived there (row 0 of an accumulator, #263)
goes wrong. Name the value again after `tg.wait()`:

```mojo
tg.wait()
_ = acc.rows  # last use past the tasks
```

Parameters of the function that waits are safe, since the caller's
frame owns them for the whole call. Locals are not.

### No FFI anywhere

Nothing in this package links or dlopens a library. `text/
font_discovery.mojo` turns a family name into a font file path by
reading the installed fonts' own `name`/`OS/2`/`head`/`post` tables,
the job `libfontconfig` would otherwise do. Keep it that way: a new
external dependency needs a reason that survives "could this be a few
hundred lines of table parsing instead?".

If you work in `font_discovery.mojo`, the two things worth knowing are
that matching is a score, never a filter (an unmatched family falls
through the default sans list rather than raising, so a typo renders in
the default font), and that every scoring term is packed into one Int
as the digits of a mixed-radix number, so comparing two candidates with
`<` is a lexicographic comparison of the terms in fontconfig's own
priority order.

### String indexing

Mojo `String` has no positional `s[i]`. Index explicitly by
`[byte=]`, `[codepoint=]`, or `[grapheme=]` — they differ for non-ASCII
text, and picking the right one is the point.

## Conventions

### Hard-edged and anti-aliased stay separate functions

`draw_circle` and `draw_circle_aa` are two functions, never one behind
an `antialias: Bool`. Every file in `canvas/shapes/` follows this.
The reasons are concrete: a shared name invites parameters meaningful in
only one branch (`draw_line_aa`'s `width` has no hard-edged equivalent —
Bresenham is definitionally 1px), and it hides a complexity-class jump
(hard-edged circle drawing is O(radius); AA is O(radius² ×
supersample²)) behind what looks like a toggle. The `_aa` suffix keeps
that visible at the call site. Apply the same split to anything new.

### One convention for pixel centers

Pixel `(px, py)` is centered **at** the point `(px, py)`, never treated
as a unit square with `(px, py)` at a corner. This is what makes
`supersample=1` degenerate to exactly the hard-edged decision, pixel for
pixel. Getting it wrong shifts a shape half a pixel relative to its
hard-edged twin, which is subtle enough to survive casual review — so
new AA primitives should assert agreement with their hard-edged
counterpart on deep-interior pixels, as `test_circles.mojo` does.

The same convention decides what an `Int` argument means. An `Int` is a
pixel index: `fill_rect(20, 5, 40, 30)` covers pixels 20 through 59,
whose geometric edges are 19.5 and 59.5. A `Float64` is geometry: an
edge at 19.5. Under a transform a primitive maps its geometry, never
its indices — an `Int` rectangle maps `x - 0.5`, not `x` — and a
rectangle snaps to whole pixels afterwards, in device space. The
`DrawTarget` docstring states the rule in full; `_snap_rect` and
`_mapped_rect` in `geometry.mojo` implement it, and any new primitive
taking a rectangle goes through them.

### Every pixel gets exactly one `set_pixel`

Translucent colors make double-blending visible, and several algorithms
here exist in their current shape specifically to avoid it: hard-edged
polyline joints skip a shared endpoint, `draw_circle` guards its
degenerate symmetry points, `_spans_from_crossings` merges touching
spans, and `_draw_polyline_core_aa` takes a per-sample minimum across
every segment rather than drawing segment by segment. If you add a
primitive that can touch a pixel twice, that's a bug — test it with a
translucent color, since opaque colors hide it completely.

### Scope discipline

The package does not grow speculative API surface. Several modules
document a deliberate limit — `ttf.mojo` rejects CFF outlines and
implements no hinting, `png.mojo` rejects indexed color and interlacing,
`bidi.mojo` implements a documented subset of UAX #9, gradients support
"pad" extend only. Each raises a clear, specific error rather than
silently misreading input. Widening one of these is welcome when
something concrete needs it; widening it speculatively is the thing to
avoid.

### Comments and docstrings

Comments describe **what the code does now**, and stay compact. Build
history — past versions, removed dependencies, why an alternative was
rejected — belongs in the
[wiki Changelog](https://github.com/randyzwitch/canvas_mojo/wiki/Changelog),
not in source.

Specifically, don't write:

- the argument against an approach that wasn't taken
- epistemic framing (`confirmed via probe, not assumed`) — the test file
  is the evidence
- `X's own` as a possessive tic
- chains of cross-references to other docstrings
- a restatement of the algorithm directly below

Do keep: scope limits, spec deviations, hand-derived values *with the
arithmetic behind them*, and any rule a reader would otherwise break
(`fill_polygon`'s half-open Y-extent is the standing example — skip it
and you write a bug).

### Tuned constants

A constant whose value came from a benchmark says so, and points at the
pull request that measured it — the PR body has the before/after table,
so the source doesn't repeat it:

```mojo
# Below this radius the interior span is not worth solving for: the
# sqrt, the endpoint nudging and the bulk-fill call cost more per row
# than testing the handful of pixels the row contains. Set by benchmark
# (#83, which has the numbers) -- re-benchmark the small-marker and
# large-disk cases before changing it.
comptime _MIN_SPAN_RADIUS = 8.0
```

That marker is the whole convention, and it cuts both ways: **a
threshold, ordering or inlining choice carrying no such note has not
been measured, and is fair game to change on judgement alone.** Don't
add the note without measuring first, and don't argue in a comment for
a faster approach nobody benchmarked — either measure it or leave the
observation out.

Which harness to measure with: `pixi run bench` is the survey, one
pass per primitive, and its rows vary by 10–20% between runs. For a
change to one primitive use `pixi run micro` (`benchmarks/
micro_canvas.mojo`), which times a case in interleaved rounds and
reports a median with its spread; add a case for the primitive if
there isn't one, and quote its median and ratio in the pull request.

Docstrings are rendered into the docs site by `mojo doc` + modo, so
public ones are user-facing documentation, not just internal notes.

### Formatting

```sh
pixi run fmt   # mojo format over canvas/ tests/ examples/ scripts/
```

Default 80 columns, so a bare `mojo format` and an editor formatting on
save both match. You don't strictly need to run it: CI formats every
pull request and commits the result back to the branch
(`.github/workflows/format.yml`). The exception is a PR from a fork,
where CI can't push to your branch — those fail the check and ask you
to run `pixi run fmt` yourself.

The formatter only touches code layout. Docstring and comment prose is
wrapped by hand; see the section above for how to write it.

## Testing

Tests use `TestSuite` from `std.testing`, with every file ending:

```mojo
def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

Test functions are named `test_*` and take no arguments. A new source
file gets a matching `tests/test_<name>.mojo`, added to the `test` task
list in `pixi.toml` (and a new example goes in the `example` list, plus
`_titles()` and `_categories()` in `scripts/gen_example_docs.mojo`).

The standard for expected values is the part worth internalizing:
**derive them independently, don't read them back out of the code.**
Existing tests hand-trace Bresenham runs, sum 4×4 sub-sample grids by
hand, compute Bezier points via De Casteljau, and cross-check font
metrics against a from-scratch Python oracle using only `struct.unpack`.
Where a value is exact, assert exact equality and say why it's exact —
`raw_units * 60 / 2048` is exactly representable because 2048 is a power
of two, so those assertions use `assert_equal`, not a tolerance.

Comments in tests should record the derivation. A number with no
arithmetic behind it is indistinguishable from a number someone pasted
from failing output.

### Golden images

`tests/test_golden.mojo` is the exception to all of the above, and
covers what per-pixel assertions structurally cannot: that an entire
render still looks the way it did. Hand-derived assertions are precise
about the places you thought to check; they cannot notice that every
anti-aliased edge shifted by one, or that a glyph moved half a pixel.

Each scene renders a small dense figure and compares it to a PNG in
`tests/golden/`. Two thresholds, and the important one is **how many
pixels changed, not how far**. A real regression (coverage-to-alpha
truncating instead of rounding) moves a couple of hundred pixels by
exactly one level, and a magnitude-only tolerance sails straight past
it. See that file's docstring for the full reasoning, including why the
opposite shape — a few pixels moving a lot — is what a legitimate
cross-platform difference looks like.

When a change is *supposed* to alter output:

```sh
CANVAS_REGEN_GOLDEN=1 pixi run test
```

That rewrites every reference and passes trivially, so **the diff it
produces is the thing to review**. Committing a regenerated golden is
asserting the new pixels are correct — do it deliberately, and never to
turn a red test green.

Text is deliberately not covered by a golden: it depends on which fonts
are installed and their exact version, which this repo does not control.

### The packaged install

`pixi run test` and `pixi run example` both run under `-I .`, which
resolves `canvas/` as a source directory. That covers the code and not
the packaging: the `[package]` section of `pixi.toml`, the
`pixi-build-mojo` backend, and what actually ends up inside the built
artifact are all invisible to them. A `[package.build.config.pkg]`
typo, or a subpackage that never makes it into the build, passes every
test in `tests/` and then fails for the first person who follows the
README.

`tests/consumer/` closes that gap. It is a separate pixi workspace that
depends on this one and imports `canvas` with no `-I` flag, the way a
downstream project does:

```sh
pixi run --manifest-path tests/consumer/pixi.toml smoke
```

`smoke.mojo` imports from the package root and from each subpackage —
a missing one fails here rather than reaching a user — then draws
through both backends and round-trips a PNG. It deliberately does not
resolve a font: a downstream workspace cannot assume any are installed.

Two things to know before relying on it:

- **A cached build can hide a packaging change.** Editing a file under
  `canvas/` does force a rebuild, but changing the root manifest's
  `[package]` section may not, and the smoke test will then pass
  against the previously built artifact. Delete `tests/consumer/.pixi`
  when you change packaging settings. CI's job disables caching for
  exactly this reason.
- **The dependency is a path, not the README's git URL.** A pull
  request has to be tested as proposed, not as already merged. Both
  forms go through the same build backend and install the same
  package.

`tests/consumer/pixi.lock` is not committed, unlike the root one: it
records the dependency by source hash, so it would go stale on every
edit under `canvas/`.

## Submitting a change

1. Branch off `main`.
2. `pixi run test` and `pixi run example` both clean. Examples matter:
   they're the rendering path a test can miss.
3. If behavior changed visibly, look at the output image. Several bugs
   in this package's history were geometry errors that every test passed
   through.
4. If you touched `pixi.toml`'s `[package]` section or added a
   subpackage under `canvas/`, run the packaged-install check above.
5. Open a PR. CI runs the same tests on Linux and macOS, the packaged
   install on both, plus a docs build as a status check.

For a change with real design reasoning behind it, consider adding a
wiki Changelog entry — that page is the project's record of *why*, and
it's most useful when written while the reasoning is fresh.

## Releasing

Bump the version in `pixi.toml` **first**, then tag — the tag should
point at the commit that already carries the new version, not the other
way around.

## License

MIT. Contributions are accepted under the same license.

# Working on canvas_mojo

This file is for coding agents and the people driving them. It is the
operational digest: what to run, where things are, the rules that are
not obvious from the code, and the Mojo 1.0 traps that cost a compile
cycle each until known. `CONTRIBUTING.md` explains the design behind
the rules; the wiki's Changelog and Backlog record why things are the
way they are. Read this first, then whichever of those you need.

## What this is

A 2D drawing engine written entirely in Mojo, no C libraries: raster
`Canvas`, `SvgCanvas` and `PdfCanvas` all implement the `DrawTarget`
trait in `canvas/vector/draw_target.mojo`. Shapes, paths, gradients,
text from system fonts, PNG/BMP/JPEG input, PNG/BMP/SVG/PDF output. It
is the rendering core a chart library sits on; anything chart-shaped
(axes, scales, legends) belongs one layer up, not here.

## Commands

```sh
pixi run test        # every tests/test_*.mojo, in parallel, capped at the core count
pixi run mojo run -I . tests/test_<name>.mojo   # one file, the usual loop
pixi run example     # renders examples/*.mojo to examples/out_*.{png,bmp,svg,pdf}
pixi run bench       # benchmarks/bench_canvas.mojo, one number per case
pixi run bench-check # the survey twice against benchmarks/reference.txt; fails on a 1.5x slower row
pixi run bench-record # rewrite that reference from this machine (quiet, on purpose, committed)
pixi run bench-verify # digest every verification scene against benchmarks/digests.txt
pixi run bench-record-digests # rewrite those digests (only when the new output is known correct)
pixi run micro       # interleaved micro-benchmarks, the gate for a perf change
pixi run roofline    # this machine's rates: copy, fill, blend, scatter, dispatch
pixi run roofline-census   # pixels each bench scene is obliged to change
pixi run roofline-locality # what an async task costs across L3 slices
pixi run fmt         # mojo format over canvas/ tests/ examples/ scripts/
pixi run docs        # rebuilds the site into docs/site/public (needs `example` first)
pixi run llms        # regenerates docs/site/static/llms.txt, the API digest
```

`test` and `example` both fan out through `scripts/run_parallel.sh`,
which caps concurrency at the machine's core count; `test` goes through
`scripts/run_tests.sh` first, which fails before compiling anything if
a `tests/test_*.mojo` file is missing from the task list.

Scratch scripts go outside the repo (`/tmp`), run with
`pixi run mojo run -I . <script>` from the repo root so `from canvas...`
resolves.

## Layout

- `canvas/` is the package. `buffer.mojo` (Canvas, pixel writes, clip
  and transform state), `color.mojo`, `path.mojo` (Path and the path
  fills), `shapes/` (primitives), `aa_crossing.mojo` (sampled sweep,
  even-odd) and `aa_area.mojo` (analytic area, nonzero), `gradient.mojo`,
  `blend.mojo`, `compose.mojo`, `blur.mojo`, `mask.mojo`, `resize.mojo`,
  `io/` (png, bmp, jpeg, deflate), `text/` (discovery, TrueType/CFF
  parsing, shaping, layout, rendering), `vector/` (the trait, svg,
  pdf, pdf_font).
- `tests/` mirrors `canvas/` one file per module; `tests/golden/` holds
  reference PNGs; `tests/jpeg/` holds decoder fixtures.
- `examples/` are the docs pages' sources; each writes one or more
  `out_<name>.{png,bmp,svg,pdf}`.
- `benchmarks/` has the survey bench and the micro harness.
- `docs/` is the Hugo site; `docs/llms.md` is the hand-written half of
  `llms.txt`; `scripts/gen_llms_txt.mojo` generates the rest.
- `skills/canvas-mojo/` is the consumer-facing skill for using the
  library from another project.

## Rules that are not in the code

- Docstrings and comments explain why, in prose a reader without the
  conversation can follow. Performance comparisons go to the wiki
  Changelog; an actionable warning stays in the code.
- U.S. spelling everywhere (color, center, gray, rasterize). Neutral
  tone: "known issue", not "defect that bites".
- Every primitive writes each pixel exactly once, so a translucent color
  never double-blends. Hard-edged and anti-aliased variants are separate
  functions. Pixel (x, y) is the square [x - 0.5, x + 0.5]; every
  rasterizer shares that convention.
- A new module gets a test file listed in `pixi.toml`'s `test` task; a
  new example goes in the `example` task and in `_titles()` and
  `_categories()` of `scripts/gen_example_docs.mojo`.
- Font discovery persists its table to
  `$XDG_CACHE_HOME/canvas_mojo/fonts.txt` (see `font_discovery.mojo`).
  Set `CANVAS_MOJO_FONT_CACHE=off` when changing or debugging
  discovery, and bump `_CACHE_FORMAT` in the same commit as any change
  to what `_parse_face` reads, or an old file will feed stale records
  to the new code.
- Public API is exported from `canvas/__init__.mojo` and the subpackage
  `__init__.mojo` files; the trait is the contract chart code writes
  against, so adding to it means all three backends.
- A change with design reasoning gets a wiki Changelog entry; a thing
  deliberately not built gets a Backlog entry saying what would make it
  worth building.
- CI formats every PR and commits the result; run `pixi run fmt` first
  anyway so the diff you review is the diff that lands.
- Releases: `pixi run bench-check` and `pixi run bench-verify` clean,
  the check on a quiet machine, then bump the version in `pixi.toml`
  (two places: `[workspace]` and `[package]`) and tag. A perf change
  that moved rows on purpose re-records the reference in the same PR.

## Mojo 1.0 traps, each with its fix

- `out` is a keyword. A variable named `out` fails to parse in the
  formatter and elsewhere; use `markup`, `result`, `buf`.
- Strings have no `len` or `s[a:b]`. Use `s.byte_length()` and
  `s[byte = a:b]`; wrap a slice in `String(...)` before assigning it
  back to the variable it came from, or the aliasing check rejects it.
  Walk `s.codepoints()` when rebuilding text: `for b in s.as_bytes()`
  with `chr(b)` turns each UTF-8 byte into its own character, which
  only shows up on text outside ASCII (macOS font filenames are
  Japanese; the Linux CI font set is not).
- `case` is a reserved word and cannot name a variable, like `out`.
- No module-level `var`. A `comptime` List cannot be indexed at runtime
  without materializing a copy each time. Tables live in a struct
  (`_Transfer` in color.mojo is the pattern) and are built on demand.
- `List[T](a, b, c)` is not a constructor; write a typed literal
  `var xs: List[Int] = [a, b, c]`. `List(length=n, fill=v)` zero-fills;
  `List(unsafe_uninit_length=n)` does not, and `resize(unsafe_uninit_length=n)`
  grows to exactly `n`, so `reserve` first when growing in a loop.
- `list.capacity()` is a method. `mask[i]` is bounds-checked and slow
  in a hot loop; read through `p = list.unsafe_ptr()` and
  `p[unsafe_offset=i]`, and write the bound in a comment.
- `p.unsafe_offset(i).unsafe_load[width=N]()` / `.unsafe_store(v)` are
  the SIMD idioms. A function parameter typed `UnsafePointer[T]` needs
  an origin; pass the `List` and take the pointer inside instead.
- The exclusivity checker rejects passing `self` mutably alongside a
  field of `self` immutably (`self._write(self._transform)`): copy the
  field to a local first. It also rejects `unsafe_memcpy` within one
  buffer; copy in doubling chunks with vector loads.
- A method that calls a raising function must be `raises`; `Path`'s
  builder methods raise, so anything building a Path does.
- `@parameter if` is deprecated; write `comptime if`.
- Structs with a `List` field cannot be `ImplicitlyCopyable`; a `String`
  field can. Give a struct `Copyable` explicitly when another struct
  needs to copy it.
- `mojo format` cannot parse a single-quoted string containing a double
  quote; escape inside double quotes instead.

## Concurrency, which is where the sharp edges are

- `TaskGroup.create_task` corrupts aggregate arguments passed by value
  (#97, upstream). Pass a struct holding the Lists by reference; never
  hand a task an owned temporary or a container element.
- Mojo destroys a value after its last use, and a task's borrow does not
  count. Anything tasks read must be named again after `tg.wait()`
  (`_ = len(source)`), or it is freed while they run (#263).
- Bands write disjoint rows or slots; that is the whole safety argument,
  so say it in the docstring of every band function.
- Creating a task costs about 1.2 us and tasks start after the last is
  created, so a band needs thousands of cells of work
  (`_CELLS_PER_BAND` in aa_area.mojo). Below `_MIN_PARALLEL_PIXELS`
  run inline.
- This 3970X holds 128 MB of L3 as eight separate 16 MB slices, and a
  canvas lives in one of them. The same fill loop is 7.5x slower inside
  an async task than called directly (166.6 vs 22.3 us) because the
  scheduler spreads tasks over all eight slices and seven reach the
  data over Infinity Fabric; pinning to one CCX takes it to 44.5 us,
  and a 4-band fill there hits 194 GB/s. So a banded pass that only
  moves bytes can lose to the serial version, while a compute-bound one
  still wins -- measure the operation, never assume from the shape.
  See benchmarks/roofline.md.

## Measuring performance

- `pixi run bench` rows at 20 iterations swing 20% between runs on
  anything parallel. Isolate the phase with a 200-iteration script,
  interleave old and new, quote the median; `pixi run micro` is the
  harness for a single primitive.
- Check the machine is quiet first: `ps -eo args | grep '^mojo run'`
  and `/proc/loadavg`. Another session's test run makes parallel numbers
  meaningless. This gates `pixi run bench-record` too: recording under
  load put every row 15-40% high, which raises the floor `bench-check`
  compares against for good. The tell is rows the branch never touched
  moving, so diff a new recording against the old and read those first.
- Compare two implementations inside one process, not across two runs
  of different builds. `resize 1600x1200 -> 741x533` swings 2487-2858
  us across fresh processes on an idle machine, so alternating builds
  "showed" a 6-9% regression that did not exist -- and 218 us of it
  looked exactly like an extra `Canvas` copy, which is the kind of
  story that survives scrutiny. Keeping both paths reachable and
  interleaving them in one process put the real figure at 0.983x. If a
  refactor leaves both sides callable, that is the measurement to make.
- A leaf function timed in a loop of its own can point the wrong way,
  because the loop vectorizes and the call site does not. A polynomial
  `asin` measured 2.7x faster than the library's that way and 1.75x
  slower where it was actually used.
- A loop copying or combining two buffers a byte at a time will not
  vectorize: the compiler cannot know they do not overlap. Saying it
  with `unsafe_load[width=N]` and `unsafe_store` is worth 3x to 20x,
  and was most of what the PNG codec had left to give.
- Phase-time inside the real call sequence, not each phase alone; the
  cache-coherence cost of a banded pass shows up in the *next* serial
  phase.
- Short parallel bursts do not reach the core count: clocks ramp and
  SMT shares. A pure loop with nothing shared scaling badly is the
  machine, not a bug. A parallel copy of a full-canvas plane is about
  as expensive as all the arithmetic, so the win is usually fewer bytes
  moved, not more threads.

- A reference is a ratchet, not a standard: it says a row did not
  change, never that it is good. `benchmarks/roofline.md` gives every
  row a floor -- the measured cost of a minimal kernel doing the same
  essential work -- so "is this optimized?" is a ratio with a stopping
  point. Keep the tight/loose split when adding a row: a tight floor
  accounts for all the compulsory work, a loose one omits real work
  (coverage, gradient evaluation, entropy decode) and so bounds the
  headroom from above rather than promising it.
- A floor has to count the work the algorithm must repeat, not the
  output it produces, and model how that work is organized. 2000
  markers change 88,810 pixels but visit 200,000, because their boxes
  overlap; and a large disk's interior is a run, so a per-pixel
  distance kernel "floors" it at 254% of its actual time, which is a
  contradiction rather than a result. Pricing the shape rows properly
  moved them from 0.2-16.9% of floor to 23-79% and reversed which ones
  are worth attention. `pixi run roofline-shapes`.
- Measure a floor, do not derive one from a spec sheet, and measure it
  on the library rather than on a kernel where you can. A pure-memory
  microbenchmark said task placement was worth 6.8x; the real bench
  said eight rows gain and the best is 2.31x.
- A timing loop that writes the same constant every iteration is
  loop-invariant and gets hoisted: a 1.92 MB fill "measured" 0.11 us,
  17 TB/s. Vary the value written and sink a byte of the result.

## Verifying output

- Render, then look: `pixi run mojo run -I . examples/<name>.mojo` and
  open `examples/out_<name>.png` (an agent reads the PNG directly).
- PDF: `pdftoppm -r 72 -png out.pdf page` renders it; `pdftotext out.pdf -`
  shows what a viewer extracts; `pdffonts` lists embedded fonts.
- Golden tests fail on any pixel change. Regenerate with
  `CANVAS_REGEN_GOLDEN=1` only when the new output is known correct,
  and say why in the PR.
- The checksum the bench prints is an anti-elimination sink, not a
  correctness check. It folds a handful of sampled channels together
  so the compiler cannot delete the work; almost every pixel never
  reaches it. A single changed pixel at (318, 238) of a scene leaves
  it identical.
- `pixi run bench-verify` is the check that does see that: every
  verification scene rendered outside any timed region and digested
  over every byte, against `benchmarks/digests.txt`. Re-record with
  `bench-record-digests` only when the new output is known correct,
  and say why in the PR. Text is excluded, for the reason the golden
  suite draws none: glyphs come from whatever fonts the machine has.
- A row's absolute time is only comparable across versions when the
  rows *before* it are the same. Adding survey rows shifts later ones:
  `read_png` read 620 us at v0.24.0 and 730 us at v0.25.0, and it was
  neither the decoder nor the file -- the PNG bytes were identical and
  an isolated decode of them was slightly *faster* on the newer tree.
  Two text rows added ahead of the image section were enough. Bisect a
  row with a standalone script before believing the survey about it.
- `benchmarks/reference.txt` is the timing memory across runs, and
  `bench-check` is how a row that doubled gets noticed (#251 went four
  releases unnoticed without it). It also names rows with no reference
  and rows in the reference nobody measures any more.

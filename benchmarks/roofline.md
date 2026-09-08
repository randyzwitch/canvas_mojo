# How close is each row to the floor?

`reference.txt` is a ratchet, not a standard. It answers whether a row
changed and never whether it is *good*, so hand-optimization has no
termination condition: you either stop arbitrarily or keep poking. It
also locks in whatever shipped -- a row that was 30x off the machine's
limit at v0.21.0 is still 30x off today, and every `bench-check` since
has said "ok".

This file gives every row a second number: the cost of a minimal kernel
doing the same essential work, measured on this machine rather than
quoted from a spec sheet. The ratio is headroom, and a row near 100% is
finished. That is what makes 57 rows tractable -- you compute 57 ratios
and read only the outliers.

Recorded 2026-09-08 on an AMD Ryzen Threadripper 3970X, the machine
quiet. Actuals are from current main, so they include the work merged
since v0.26.0 (#343, #356, #357, #358); the floors were re-derived
after two errors were found in them, described below. Re-derive with the tasks below; the constants are
machine properties and do not carry to other hardware.

    pixi run roofline           # machine constants
    pixi run roofline-census    # pixels each row must change
    pixi run roofline-locality  # async task placement
    pixi run roofline-shapes    # coverage-inclusive floors for shapes
    pixi run roofline-compositing  # what source-over and multiply really cost

## The yardsticks

All serial, over a 1.92 MB buffer -- an 800x600 RGBA canvas, so they
drop straight into the rows.

| rate | value | notes |
|---|---|---|
| vectorized copy | 96.9 GB/s | read+write, 39.6 us |
| vectorized fill | 85.8 GB/s | write only, 22.4 us |
| source-over, SIMD | **0.78 ns/px** | uint32 lanes, alpha broadcast, exact div255 |
| source-over, scalar | 3.52 ns/px | 4.5x -- the cost of not vectorizing |
| scattered sample | 1.65 ns/px | dependent load, the transform path |
| f64 axpy, 480k doubles | 44.6 us | resize's intermediate shape |
| task dispatch | 0.68 us/task | 43.5 us for 64 |

The source-over figure was 0.12 ns/px in the first version of this
file, taken with uint16 lanes, a `>>8` approximation and no alpha
broadcast. That is cheaper arithmetic than any correct implementation
can use, and it under-priced about 36 of the rows below by 6.3x. The
"cost of not vectorizing" moved with it, from 27x to 4.5x.

## What a floor is based on

Each row says which of four things its floor rests on, because they
carry very different weight.

**tight** -- compulsory traffic, and little else is required: a fill
must write its bytes, a copy must read and write them.

**measured** -- a kernel doing the operation's real arithmetic, timed
here. The compositing rows are priced this way.

**coverage** -- a kernel that also computes anti-aliased coverage over
the pixels the rasterizer must visit. See below.

**loose** -- traffic or blend cost only, with real work left unpriced
(curve flattening, gradient evaluation, entropy coding). A loose
percentage is an upper bound on headroom and nothing more.

**A floor above 100% is a broken model, not a fast row.** Six rows
below price above the row they are meant to bound. That means the
kernel is not a lower bound for them -- the library is doing less work
than the kernel charges for, by skipping fully transparent groups, by
hoisting source terms further, or because the model counts arithmetic
the operation does not perform. Those rows are marked, and the right
reading is "no headroom demonstrated", never "138% efficient".

Pixel counts come from `roofline_census.mojo`, which renders each
scene onto a known background and counts what changed. Coverage rows
use *visits* instead -- the pixels a shape's bounding box makes the
rasterizer look at, summed over every shape -- because overlapping
shapes visit a pixel several times and that work was never optional.

## Coverage floors, and why the loose ones misled

A floor that prices only the blend understates a shape by two orders
of magnitude, and ranking rows by that number sends effort at the
wrong ones. `roofline_shapes.mojo` measures what the shapes actually
have to do. Each kernel does the least arithmetic a correct
implementation of its shape can: locate the pixel relative to the
edge, turn that into a coverage fraction, scale the alpha, blend.

| row | blend-only floor | coverage floor |
|---|---:|---:|
| `fill_circle_aa x2000 markers` | 0.4% | **23.8%** |
| `fill_ellipse_aa x2000 small` | 0.4% | **34.7%** |
| `fill_arc_aa x2000 small` | 0.2% | **23.1%** |
| `fill_polygon_aa 64-gon` | 4.3% | **36.9%** |
| `fill_circle_aa one large (r=250)` | 16.9% | **79.0%** |

The large disk is the cautionary one. Read from the blend-only floor
it looked 5.9x off and worth attention; measured properly it is at
79% and there is nothing there. Optimizing it would have been effort
spent against a number, not against the machine.

Two corrections had to be made to get these, and both generalize.

**Count visits, not changed pixels.** 2000 markers change 88,810
distinct pixels but make the rasterizer look at 200,000, because
their bounding boxes overlap. Work that a shape repeats on a pixel
another shape already touched was never optional, so a floor built on
the census's changed-pixel count prices away real work. Every
coverage row above uses visits.

**Respect the algorithm's shape.** The first large-disk kernel tested
each pixel in the bounding box for distance and came out at 254% of
the row it was supposed to bound -- a floor slower than the thing it
floors, which is a contradiction. A large shape's interior is a run:
the row's span is solved once analytically, the inside is filled with
no coverage arithmetic at all, and only the two rim pixels pay for
coverage. Corrected, the same row reads 79%. A floor has to model how
the work must be organized, not just how many pixels it lands on.

Rows priced this way are marked `coverage` rather than `tight` or
`loose`: the floor now includes the coverage arithmetic, but not
per-call setup, curve flattening, or clipping.

## The source-over yardstick prices a cheaper operation

The yardstick below, 0.12 ns/px, was measured with uint16 lanes, a
`>>8` approximation and no alpha broadcast. `_blend_group_opaque`
widens to uint32, broadcasts each pixel's alpha across its four lanes
with a shuffle, and divides by 255 exactly. Measured side by side over
the same 480,000 pixels:

| | us | ns/px |
|---|---:|---:|
| published yardstick | 59.8 | 0.125 |
| the kernel's real arithmetic | 374.4 | 0.780 |

**The yardstick is low by 6.26x**, and every compositing floor built on
it is understated by that factor. Re-priced:

| row | actual | old floor | corrected floor | |
|---|---:|---:|---:|---|
| `fill_rect 600x400 multiply` | 304.7 | 30.96 | **192.1** | 63% |
| `Canvas.fill translucent` | 221.5 | 61.92 | **269.6** | *above* |
| `draw_canvas 800x600 translucent` | 283.0 | 61.92 | **374.4** | *above* |

Two of the three now price *above* the row they were meant to bound,
which means the kernel is not a floor for them: the library is beating
a straightforward vectorization. `Canvas.fill translucent` hoists its
source terms further than the kernel does, and `draw_canvas` skips
whole eight-pixel groups that are fully transparent, so it never does
the arithmetic the floor charges for. What these figures establish is
not headroom but its absence: the 3.6x and 4.6x in the original table
were artifacts of pricing the wrong arithmetic.

Multiply keeps a real gap, 1.6x rather than 9.8x. A multiply blend
computes `div255(dst*src)` and then composites it -- about twice
source-over's multiplies per channel -- so the source-over kernel was
never the right price for it. Vector width does not move it: 4, 8 and
16 pixels per iteration measure 192.6, 192.1 and 198.6 us.

One attempt at the remaining gap made it worse and is recorded here so
it is not tried again. The span checks four destination alphas with
scalar byte loads before deciding to load the group; replacing that
with a vector load plus a `reduce_min` horizontal test ran **2.3x
slower** (309 -> 722 us). The horizontal reduction sits on the
critical path ahead of the branch, where four short-circuiting scalar
compares do not.

## Floors that were called tight and are not

`resize 1600x1200 -> 741x533` was priced at input plus output traffic,
which is compulsory but not sufficient: the filter also does a
Float64 multiply-accumulate per tap per channel, and that arithmetic
is not in the number. #358 cut the row from 2626 us to 1046 by
removing the 28.5 MB intermediate -- the traffic part -- and the row
still sits at 9.2% of a floor that prices no filtering at all. Treat
that percentage as an upper bound on what remains.

`fill_rect 600x400 multiply` is priced with the source-over kernel,
which is the wrong arithmetic: a multiply blend does the multiply and
then the composite. Its floor is too low by whatever that costs, and
measuring it belongs with the work on that row.

## What it found

**Four rows are finished.** Transformed nearest sampling is at 103% of
floor (it beats the model, which means the floor slightly understates
the cache behavior, not that the code is superhuman), `Canvas.fill
opaque` 85%, bilinear 78%, `fill_rect` opaque 72%. These are done. That
is the point of the exercise as much as any win is.

**resize at an integer ratio, 3.2x, no new code.** `resize` and
`downsample` move identical traffic at an exact 2x ratio and are
documented to return identical bytes -- and they are 2820 vs 872 us
apart. `resize()` has an identity fast path but no integer-ratio
dispatch, so at exactly 2x it runs the general two-pass path through a
Float64 intermediate of `width * source.height * 4` doubles (30.7 MB)
while `downsample` uses its specialized factor-2 and factor-4 kernels.

**The 126x on `push_clip_path rect mask` is algorithmic, not sloppy
code.** 703.9 us to build a coverage plane whose floor is 5.6 us is the
worst tight-floor ratio in the table, but the code is not slow:
`push_clip_path` passes `supersample=4`, so it evaluates 4x4 = 16
sub-samples per pixel, and at 0.09 ns per sub-sample it is already near
the ALU ceiling. It does 16x the necessary work correctly and fast.
Every other primitive moved to exact-area coverage in v0.23.0; the clip
mask did not. Clipping to a plot area is the most common thing a chart
does.

**An opaque composite should be a copy.** `draw_canvas 800x600 opaque`
is 108.1 us against a 39.8 us copy. Fully opaque source over an opaque
destination is memcpy by another name, but the fast path re-derives
"is this run opaque?" per eight-pixel group by reading the source. It
also does not band -- its time is flat across every core count tested.

**One row measured nothing at all, and now two rows measure the right
things.** The census returned zero changed pixels for
`fill_path_gradient_aa 39-curve under a small clip`: the clip
rectangle at (300,200,100,80) fell in the gap between two arches of
the test path, so the row spent 51.1 us producing no output. It was
measuring flattening and rejection under a name that promised
painting.

Both are worth timing, so there are now two rows. The high window
keeps the old geometry under the honest name `clip misses the path`;
a second window at (300,400,100,80) is about 87% covered and is the
one that measures painting through an intersecting clip.
`tests/test_clip_path.mojo` pins both counts, so changing the test
path's shape fails a test rather than quietly returning the benchmark
to measuring rejection (#355).

**The scalar tax, priced.** A blend mode other than source-over cannot
take the packed store and goes through `write_pixel` per pixel. The
yardsticks put a number on exactly that: 3.22 ns/px scalar against 0.12
vectorized, 27x. `fill_rect 600x400 multiply` is 9.8x off its floor.

## Task placement and the L3 slices

A separate thread, and the one that changed mid-analysis.

An identical fill loop runs **7.5x slower inside an async task** than
called directly -- 166.6 vs 22.3 us. Splitting the same work into 64
chunks *serially* costs almost nothing (22.3 -> 28.9 us), so it is not
the chunking. Pinning separates the causes and it is not codegen: this
3970X carries 128 MB of L3 in **eight separate 16 MB slices**. A 1.92 MB
canvas lives in one of them, the scheduler spreads tasks across all
eight, and seven reach the data over Infinity Fabric.

| 1.92 MB fill kernel | unpinned | pinned to cores 0-3 |
|---|---:|---:|
| 1 async task | 166.6 us | 44.5 us |
| 4 bands | 67.0 us | 9.9 us (194 GB/s) |
| 64 bands | 90.3 us | 15.8 us |

That is a 6.8x swing, and it would be easy to stop there and call task
placement the biggest lever in the library. Running the real benchmark
pinned says otherwise. The honest version is narrower: eight rows gain,
the best 2.31x, and the gains land on large single anti-aliased shapes
where each band does modest work over a shared coverage plane.

| row | 64 cores | best pinned | delta |
|---|---:|---:|---:|
| `fill_ring_sector_aa large donut` | 80.3 | 34.7 | 2.31x |
| `fill_circle_aa one large (r=250)` | 140.2 | 85.8 | 1.63x |
| `fill_arc_aa large pie wedge` | 76.1 | 48.0 | 1.59x |
| `fill_path_aa large 39-curve (nonzero)` | 388.6 | 261.1 | 1.49x |
| `blur 800x600 r=16` | 2287.1 | 1584.6 | 1.44x |
| `downsample 1600x1200 -> 2x` | 872.4 | 656.4 | 1.33x |
| `fill_polygon_aa 64-gon` | 442.9 | 1048.4 | 0.42x |
| `fill_circles_aa x2000 batched` | 301.0 | 599.3 | 0.50x |
| `draw_polyline_aa 3000-segment series` | 2344.6 | 4475.8 | 0.52x |

The rows that lose are genuinely compute-bound and want all 32 cores.
So the lever is real but selective: band placement should follow the
shape of the work, and nothing in the runtime currently lets it say so.
The microbenchmark oversold it by 3x, which is its own lesson about
floors measured on kernels rather than on the library.

A free side effect: a row whose time moves with core count is banded,
one that is flat is not. 24 of 57 rows band today, marked `*` below.

## Every row

`*` marks a row that bands across cores. Sorted by distance from floor,
worst first.

| % of floor | row | us | floor us | basis | what the floor counts |
|---:|---|---:|---:|:--:|---|
| 0.3 | `draw_polyline_aa 3000-segment smooth series` | 1200.8 | 4.01 | loose | blend only at 0.78 ns/px; coverage not priced |
| 0.5 | `write_png 800x600 (deflate)` | 4129.8 | 22.54 | loose | LZ77+huffman not priced |
| 1.0 | `draw_text_on_path 20 glyphs on an arc` | 113.3 | 1.11 | loose | blend only at 0.78 ns/px; coverage not priced |
| 1.0 | `fill_path_gradient_aa 39-curve under a small clip` | 527.4 | 5.46 | loose | blend only at 0.78 ns/px; coverage not priced |
| 1.3 | `stroke_path_aa 39-curve path` | 2414.6 | 31.16 | loose | blend only at 0.78 ns/px; coverage not priced |
| 1.5 | `fill_path_aa glyph-sized` | 22.4 | 0.33 | loose | blend only at 0.78 ns/px; coverage not priced |
| 2.4 | `draw_polyline_aa 3000-segment dashed` | 3349.6 | 81.58 | loose | blend only at 0.78 ns/px; coverage not priced |
| 3.2 | `draw_text 3 lines @13px (cached)` | 96.5 | 3.12 | loose | blend only at 0.78 ns/px; coverage not priced |
| 3.3 | `blur 800x600 r=16` | 2388.4 | 79.26 | loose | same work; radius is free |
| 3.3 | `read_png 800x600 (inflate)` | 671.5 | 22.38 | loose | huffman decode not priced |
| 4.1 | `fill_path_aa large under a clip rect` | 646.5 | 26.65 | loose | blend only at 0.78 ns/px; coverage not priced |
| 4.5 | `draw_line dashed full diagonal` | 7.8 | 0.35 | loose | blend only at 0.78 ns/px; coverage not priced |
| 4.8 | `draw_polyline_aa 3000-segment series` | 2462.5 | 117.97 | loose | blend only at 0.78 ns/px; coverage not priced |
| 4.9 | `draw_line_aa full diagonal (w=2)` | 48.7 | 2.36 | loose | blend only at 0.78 ns/px; coverage not priced |
| 6.2 | `blur 800x600 r=4` | 1274.7 | 79.26 | loose | ~64 f32 ops/px not priced |
| 9.0 | `resize 1600x1200 -> 741x533` | 1067.3 | 95.57 | loose | traffic only; no filter arithmetic |
| 10.3 | `fill_path_aa large 39-curve` | 718.5 | 73.84 | loose | blend only at 0.78 ns/px; coverage not priced |
| 10.8 | `downsample 1600x1200 -> 2x` | 920.3 | 99.07 | loose | traffic only; no filter arithmetic |
| 11.1 | `resize 1600x1200 -> 800x600` | 894.1 | 99.07 | loose | traffic only; dispatches to downsample |
| 12.2 | `draw_line solid full diagonal` | 4.7 | 0.58 | loose | blend only at 0.78 ns/px; coverage not priced |
| 15.4 | `fill_path_aa large 39-curve (nonzero)` | 488.1 | 75.09 | loose | blend only at 0.78 ns/px; coverage not priced |
| 23.7 | `fill_arc_aa x2000 small (r=4)` | 2694.8 | 637.90 | coverage | measured coverage kernel |
| 23.8 | `fill_circle_aa x2000 markers (r=3.5)` | 2918.9 | 695.40 | coverage | measured coverage kernel |
| 32.2 | `fill_circles_aa x2000 markers batched (r=3.5)` | 225.6 | 72.65 | loose | blend only at 0.78 ns/px; coverage not priced |
| 35.0 | `fill_ellipse_aa x2000 small (5x3)` | 3448.9 | 1208.60 | coverage | measured coverage kernel |
| 38.6 | `fill_polygon_aa 64-gon` | 423.4 | 163.50 | coverage | measured coverage kernel |
| 42.0 | `draw_canvas 800x600 opaque` | 94.3 | 39.63 | tight | a copy, nothing more |
| 43.1 | `fill_ring_sector_aa large donut (150-260)` | 107.5 | 46.34 | loose | blend only at 0.78 ns/px; coverage not priced |
| 44.3 | `push_clip_path rect mask` | 12.6 | 5.59 | tight | write a 480 KB coverage plane |
| 50.6 | `Canvas(800x600) construct+fill` | 44.2 | 22.38 | tight | alloc + fill 1.92 MB |
| 63.1 | `fill_rect 600x400 multiply` | 304.7 | 192.10 | measured | multiply-specific kernel |
| 70.7 | `fill_arc_aa large pie wedge (r=260)` | 97.7 | 69.10 | loose | blend only at 0.78 ns/px; coverage not priced |
| 72.6 | `fill_rect 600x400 opaque` | 15.4 | 11.19 | tight | write 0.96 MB |
| 84.6 | `Canvas.fill opaque` | 26.4 | 22.38 | tight | write 1.92 MB |
| 88.2 | `fill_circle_aa one large (r=250)` | 125.7 | 110.80 | coverage | measured coverage kernel |
| 96.5 | `draw_canvas 800x600 through a mask` | 393.8 | 380.03 | measured | + mask read |
| 105.2 | `draw_canvas 200x200 1.7x rot 30 nearest` | 181.4 | 190.74 | tight | 1 scattered sample/px |
| 122.1 | `Canvas.fill translucent (blend)` | 220.8 | 269.60 | measured | hoisted flat-source kernel |
| 133.4 | `draw_canvas 800x600 at half opacity` | 280.7 | 374.40 | measured | + one scale/px |
| 142.7 | `draw_canvas 800x600 translucent` | 262.3 | 374.40 | measured | exact source-over kernel |
| 163.0 | `fill_ellipse_aa one large (340x220)` | 112.9 | 184.10 | loose | blend only at 0.78 ns/px; coverage not priced |
| 184.4 | `draw_canvas 200x200 1.7x rot 30 bilinear` | 299.0 | 551.41 | tight | 1 scatter + 2x2 lerp |
| -- | `fill_path_aa glyph-sized (nonzero)` | 5.0 | -- | n/a | no model |
| -- | `fill_path_gradient_aa glyph-sized` | 27.5 | -- | n/a | no model |
| -- | `fill_path_gradient_aa large 39-curve` | 1249.7 | -- | n/a | no model |
| -- | `fill_path_gradient_aa 39-curve, clip misses the path` | 49.8 | -- | n/a | no model |
| -- | `fill_path_radial_gradient_aa glyph-sized` | 28.3 | -- | n/a | no model |
| -- | `fill_path_radial_gradient_aa large 39-curve` | 1278.5 | -- | n/a | no model |
| -- | `fill_path_conic_gradient_aa glyph-sized` | 35.8 | -- | n/a | no model |
| -- | `fill_path_conic_gradient_aa large 39-curve` | 1447.8 | -- | n/a | no model |
| -- | `draw_text 3 lines @13px (uncached)` | 1787.5 | -- | n/a | no model |
| -- | `FontCache() font scan` | 0.1 | -- | n/a | no model |
| -- | `fill_circle_aa x2000 under a clip path` | 3256.6 | -- | n/a | no model |
| -- | `fill_circle_aa x2000 under a clip rect` | 2905.3 | -- | n/a | no model |
| -- | `measure_text one label (cached)` | 2.7 | -- | n/a | no model |
| -- | `measure_text_block 3 lines (cached)` | 21.2 | -- | n/a | no model |
| -- | `measure then draw 3 lines (laid out twice)` | 117.7 | -- | n/a | no model |
| -- | `measure then draw 3 lines (prepared once)` | 95.7 | -- | n/a | no model |

## Where this leaves it

Of the 17 rows with a floor worth trusting -- tight, measured or
coverage -- **nine are at or above it** and can be left alone:

| row | actual | floor | |
|---|---:|---:|---|
| `draw_canvas 200x200 bilinear` | 299.0 | 551.4 | model over-prices |
| `draw_canvas 800x600 translucent` | 262.3 | 374.4 | model over-prices |
| `draw_canvas 800x600 at half opacity` | 280.7 | 374.4 | model over-prices |
| `Canvas.fill translucent` | 220.8 | 269.6 | model over-prices |
| `draw_canvas 200x200 nearest` | 181.4 | 190.7 | at floor |
| `draw_canvas 800x600 through a mask` | 393.8 | 380.0 | 96.5% |
| `fill_circle_aa one large (r=250)` | 125.7 | 110.8 | 88.2% |
| `Canvas.fill opaque` | 26.4 | 22.4 | 84.6% |
| `fill_rect 600x400 opaque` | 15.4 | 11.2 | 72.6% |

What is actually left, worst first:

| row | actual | floor | gap |
|---|---:|---:|---|
| `fill_arc_aa x2000 small (r=4)` | 2694.8 | 637.9 | 4.2x |
| `fill_circle_aa x2000 markers` | 2918.9 | 695.4 | 4.2x |
| `fill_ellipse_aa x2000 small` | 3448.9 | 1208.6 | 2.9x |
| `fill_polygon_aa 64-gon` | 423.4 | 163.5 | 2.6x |
| `draw_canvas 800x600 opaque` | 94.3 | 39.6 | 2.4x |
| `push_clip_path rect mask` | 12.6 | 5.6 | 2.3x |
| `Canvas(800x600) construct+fill` | 44.2 | 22.4 | 2.0x |
| `fill_rect 600x400 multiply` | 304.7 | 192.1 | 1.6x |

The batched small shapes are the only rows left with a gap over 2.5x
against a floor that prices their real work. Everything else is either
close to its floor or has no floor worth acting on yet.

The 41 rows still marked `loose` are not evidence of anything. Their
floors price a blend and no coverage, no flattening, no gradient
evaluation and no entropy coding, so a figure like 0.3% for
`draw_polyline_aa smooth series` says the model is absent, not that
the row is bad. Pricing them is the same move each time: write the
smallest honest kernel that does the essential work, measure it, and
see whether an afternoon is warranted.

## What the refresh corrected

The first version of this file got two things wrong, and both
inflated the apparent headroom.

**The source-over yardstick priced a cheaper operation than the
library performs** -- uint16 lanes and `>>8` where the real kernel
broadcasts alpha, widens to uint32 and divides exactly. 6.3x low,
propagating to about 36 rows. Six of them now price above their own
row, which is how the error announced itself.

**The shape floors priced a blend and no coverage**, understating
them by up to two orders of magnitude. `fill_circle_aa one large` read
16.9% and looked worth an afternoon; priced properly it is at 88.2%
and there is nothing in it.

Both errors pointed the same way: they made finished rows look
unfinished. The three rows that were genuinely worth doing -- the clip
mask, resize, and masked compositing -- were all *tight*-floor rows,
where the model was simple enough to be right.

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

Recorded 2026-09-08 at v0.26.0 on an AMD Ryzen Threadripper 3970X, the
machine quiet. Re-derive with the tasks below; the constants are
machine properties and do not carry to other hardware.

    pixi run roofline           # machine constants
    pixi run roofline-census    # pixels each row must change
    pixi run roofline-locality  # async task placement
    pixi run roofline-shapes    # coverage-inclusive floors for shapes

## The yardsticks

All serial, over a 1.92 MB buffer -- an 800x600 RGBA canvas, so they
drop straight into the rows.

| rate | value | notes |
|---|---|---|
| vectorized copy | 96.6 GB/s | read+write, 39.7 us |
| vectorized fill | 86.0 GB/s | write only, 22.3 us |
| source-over, SIMD | 0.12 ns/px | ALU ceiling, L1-resident |
| source-over, scalar | 3.22 ns/px | 27x -- the cost of not vectorizing |
| scattered sample | 1.64 ns/px | dependent load, the transform path |
| f64 axpy, 480k doubles | 44.4 us | resize's intermediate shape |
| task dispatch | 0.68 us/task | 43.5 us for 64 |

## Tight and loose

The distinction that keeps this honest.

A **tight** floor accounts for essentially all the compulsory work: a
fill must write its bytes, a composite must read and write them.
Fifteen rows have one, and for those the gap is real headroom.

A **loose** floor omits work that genuinely has to happen -- computing
anti-aliased coverage, evaluating a gradient, Huffman-decoding a
scanline. Those floors are lower bounds, so the ratio is an *upper
bound on headroom*, never a promise. A low percentage on a loose row is
a question, not a verdict.

Pixel counts are measured, not estimated: `roofline_census.mojo`
renders each scene onto a known background and counts what actually
changed. That is the floor's denominator -- the output the operation is
obliged to produce.

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

| % of floor | row | us | floor us | px changed | floor | what the floor counts |
|---:|---|---:|---:|---:|:--:|---|
| 0.1 | `draw_polyline_aa 3000-segment smooth series` * | 1120.2 | 0.62 | 5,141 | loose | blend only; coverage math not in floor |
| 0.1 | `draw_text 3 lines @13px (uncached)` | 1753.0 | 2.22 | 4,000 | loose | dominated by a full font rescan |
| 23.1 | `fill_arc_aa x2000 small (r=4)` | 2766.3 | 637.90 | 242,000 | coverage | disk coverage + two half-plane tests per visit |
| 0.2 | `fill_path_aa glyph-sized` | 22.8 | 0.05 | 425 | loose | blend only; coverage math not in floor |
| 0.2 | `stroke_path_aa 39-curve path` * | 2350.6 | 4.79 | 39,947 | loose | blend only; coverage math not in floor |
| 0.3 | `fill_circle_aa x2000 under a clip path` | 3281.7 | 10.66 | 88,810 | loose | blend only; coverage math not in floor |
| 23.8 | `fill_circle_aa x2000 markers (r=3.5)` | 2921.0 | 695.40 | 200,000 | coverage | distance, clamp and blend per visit |
| 34.7 | `fill_ellipse_aa x2000 small (5x3)` | 3482.5 | 1208.60 | 234,000 | coverage | normalized radius, clamp and blend per visit |
| 0.4 | `fill_path_gradient_aa glyph-sized` | 27.6 | 0.10 | 425 | loose | + gradient eval/px (sqrt, atan2) |
| 0.4 | `draw_polyline_aa 3000-segment dashed` * | 3133.7 | 12.55 | 104,585 | loose | blend only; coverage math not in floor |
| 0.4 | `fill_circle_aa x2000 under a clip rect` | 2923.2 | 10.66 | 88,810 | loose | blend only; coverage math not in floor |
| 0.7 | `fill_path_aa large under a clip rect` * | 547.7 | 4.10 | 34,164 | loose | blend only; coverage math not in floor |
| 0.7 | `fill_path_radial_gradient_aa glyph-sized` | 28.4 | 0.20 | 425 | loose | + gradient eval/px (sqrt, atan2) |
| 0.7 | `draw_line dashed full diagonal` | 7.8 | 0.05 | 449 | loose | blend only; coverage math not in floor |
| 0.7 | `write_png 800x600 (deflate)` | 4233.3 | 29.14 | 480,000 | loose | LZ77+huffman; memory floor only |
| 0.8 | `draw_line_aa full diagonal (w=2)` | 47.7 | 0.36 | 3,029 | loose | blend only; coverage math not in floor |
| 0.8 | `draw_polyline_aa 3000-segment series` * | 2344.6 | 18.15 | 151,241 | loose | blend only; coverage math not in floor |
| 0.8 | `push_clip_path rect mask` * | 703.9 | 5.58 | 480,000 | tight | exact-area floor; today 4x4 supersampled |
| 1.0 | `fill_path_aa glyph-sized (nonzero)` | 5.0 | 0.05 | 425 | loose | blend only; coverage math not in floor |
| 1.2 | `fill_path_conic_gradient_aa glyph-sized` | 35.3 | 0.41 | 425 | loose | + gradient eval/px (sqrt, atan2) |
| 1.8 | `fill_path_aa large 39-curve` * | 640.6 | 11.36 | 94,669 | loose | blend only; coverage math not in floor |
| 1.9 | `fill_path_gradient_aa large 39-curve` * | 1208.2 | 22.72 | 94,669 | loose | + gradient eval/px (sqrt, atan2) |
| 1.9 | `draw_line solid full diagonal` | 4.7 | 0.09 | 741 | loose | blend only; coverage math not in floor |
| 2.8 | `draw_text 3 lines @13px (cached)` | 97.5 | 2.70 | 4,000 | loose | 111 cached glyph blits |
| 2.8 | `measure then draw 3 lines (prepared once)` | 98.1 | 2.70 | 4,000 | loose | layout once + blit |
| 3.0 | `fill_path_aa large 39-curve (nonzero)` * | 388.6 | 11.55 | 96,273 | loose | blend only; coverage math not in floor |
| 3.0 | `read_png 800x600 (inflate)` | 754.8 | 22.33 | 480,000 | loose | huffman decode; memory floor only |
| 3.5 | `resize 1600x1200 -> 800x600` * | 2820.4 | 99.38 | 480,000 | tight | same traffic as downsample |
| 3.6 | `resize 1600x1200 -> 741x533` * | 2628.2 | 95.86 | 395,073 | tight | read 7.68 MB, write 1.58 |
| 3.7 | `fill_circles_aa x2000 markers batched (r=3.5)` * | 301.0 | 11.18 | 93,142 | loose | blend only; coverage math not in floor |
| -- | `fill_path_gradient_aa 39-curve, clip misses the path` | 51.1 | -- | 0 | n/a | renamed: flatten 39 curves and find no coverage |
| -- | `fill_path_gradient_aa 39-curve under a small clip` | -- | -- | 7,000 | n/a | new intersecting scene; re-record for a time |
| 3.8 | `fill_path_radial_gradient_aa large 39-curve` * | 1198.7 | 45.44 | 94,669 | loose | + gradient eval/px (sqrt, atan2) |
| 4.1 | `measure then draw 3 lines (laid out twice)` | 119.6 | 4.92 | 4,000 | loose | layout twice + blit |
| 36.9 | `fill_polygon_aa 64-gon` * | 442.9 | 163.50 | 157,244 | coverage | scanline crossings, interior run, edge coverage |
| 6.9 | `fill_path_conic_gradient_aa large 39-curve` * | 1318.8 | 90.88 | 94,669 | loose | + gradient eval/px (sqrt, atan2) |
| 7.4 | `measure_text one label (cached)` | 2.7 | 0.20 | 0 | loose | 10 glyph lookups + advances |
| 8.2 | `draw_canvas 800x600 through a mask` | 843.4 | 69.20 | 480,000 | tight | + mask read |
| 8.8 | `draw_text_on_path 20 glyphs on an arc` | 113.5 | 10.00 | 1,427 | loose | 20 rotated glyphs, each outline-filled |
| 8.9 | `fill_ring_sector_aa large donut (150-260)` * | 80.3 | 7.13 | 59,415 | loose | blend only; coverage math not in floor |
| 9.6 | `draw_canvas 800x600 at half opacity` | 646.0 | 61.92 | 480,000 | tight | + one scale/px |
| 10.2 | `fill_rect 600x400 multiply` | 304.7 | 30.96 | 240,000 | tight | read+write+blend |
| 10.5 | `measure_text_block 3 lines (cached)` | 21.2 | 2.22 | 0 | loose | 111 glyph lookups + advances |
| 11.4 | `downsample 1600x1200 -> 2x` * | 872.4 | 99.38 | 480,000 | tight | read 7.68 MB, write 1.92 |
| 14.0 | `fill_arc_aa large pie wedge (r=260)` * | 76.1 | 10.63 | 88,594 | loose | blend only; coverage math not in floor |
| 79.0 | `fill_circle_aa one large (r=250)` * | 140.2 | 110.80 | 196,805 | coverage | analytic row span, interior run, rim coverage |
| 21.7 | `fill_ellipse_aa one large (340x220)` * | 130.5 | 28.32 | 236,029 | loose | blend only; coverage math not in floor |
| 21.9 | `draw_canvas 800x600 translucent` | 283.0 | 61.92 | 480,000 | tight | read+write+blend |
| 28.0 | `Canvas.fill translucent (blend)` | 221.5 | 61.92 | 480,000 | tight | read+write+blend |
| 28.2 | `blur 800x600 r=16` * | 2287.1 | 645.12 | 480,000 | loose | same work; radius is free |
| 36.8 | `draw_canvas 800x600 opaque` | 108.1 | 39.75 | 480,000 | tight | a copy, nothing more |
| 50.2 | `Canvas(800x600) construct+fill` | 44.4 | 22.33 | 480,000 | tight | alloc + fill 1.92 MB |
| 53.5 | `blur 800x600 r=4` * | 1206.2 | 645.12 | 480,000 | loose | ~64 f32 ops/px (estimated), 6 stages |
| 71.9 | `fill_rect 600x400 opaque` | 15.5 | 11.16 | 240,000 | tight | write 0.96 MB |
| 78.4 | `draw_canvas 200x200 1.7x rot 30 bilinear` * | 312.6 | 245.07 | 115,600 | tight | 1 scatter + 2x2 lerp |
| 85.4 | `Canvas.fill opaque` | 26.1 | 22.33 | 480,000 | tight | write 1.92 MB |
| 103.2 | `draw_canvas 200x200 1.7x rot 30 nearest` * | 183.8 | 189.58 | 115,600 | tight | 1 scattered sample/px |
| -- | `FontCache() font scan` | 0.1 | -- | 0 | loose | machine property, not code |

## Where this leaves it

Three tight rows carry most of the recoverable time -- resize at 28x,
the clip mask at 126x, masked compositing at 12x -- and each has a named
cause rather than a vague suspicion.

The 42 loose rows are where the floor model itself needs work. To say
anything firm about `fill_circle_aa x2000 markers` at 0.4%, the floor
has to include the cost of computing coverage, which means writing the
minimal kernel for that and measuring it, exactly as the yardsticks
were measured. That is the next increment, and it is the same move each
time: pick the operation, write the smallest honest thing that does its
essential work, measure it, and let the ratio say whether there is an
afternoon's work in it or nothing at all.

Tracking: #338.

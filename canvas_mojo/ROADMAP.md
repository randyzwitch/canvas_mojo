# canvas_mojo roadmap

What exists, what's deliberately deferred, and what's plausibly left
for `canvas_mojo` as a general-purpose raster/drawing library — not
`dataviz_mojo`-specific concerns (axes, scales, chart types), which
belong in that sibling package, built on top of whatever's here (as of
2026-08-13, still inside the combined `graphics` workspace; this
package itself split out into its own repo that day -- see this file's
own "Split into its own standalone repo" entry, in Done, below).

No external reference API this tracks against — see the conversation
this file came out of for the honest version of "why these names."

## Done

- **`color.mojo`** — `Color` (RGBA8) + `blend_over` (src-over alpha
  compositing).
- **`buffer.mojo`** — `Canvas`: owns the pixel buffer, `get_pixel` /
  `set_pixel` (blends automatically on non-opaque writes) / `fill` /
  `in_bounds`. Also `push_clip` / `pop_clip` / `in_clip`: a clip
  *stack*, checked inside `set_pixel` alongside `in_bounds`. This is
  Canvas-level state (not an explicit parameter threaded through every
  primitive), and deliberately so: `Canvas` already silently discards
  out-of-bounds writes via `in_bounds`, so a clip rectangle is the
  same category of behavior, not a new kind of hidden state -- and
  every primitive gets it for free with zero changes of its own, since
  they all write through `set_pixel`. Verified that composition
  directly, not just assumed it: `fill_rect` and `draw_line` were both
  confirmed to respect an active clip without any modification.
  `push_clip` *intersects* with whatever's currently active rather
  than replacing it (originally `set_clip`/`clear_clip`, a single
  settable rect with no nesting -- superseded once the clip-stacking
  roadmap item below was done, not kept alongside it: two ways to
  express "restrict drawing" would've meant a caller needing to know
  which one composes safely with nested plots and which one silently
  clobbers a parent's clip). `in_clip` on an empty stack is
  unconditionally `True` -- it no longer implicitly encodes canvas
  bounds into a "default" rect the way the single-rect version did;
  that's `in_bounds`' job alone, checked separately by `set_pixel`.
- **`io/bmp.mojo`** — write-only, uncompressed 24-bit BMP.
- **`io/png.mojo`** — write-only PNG, also stdlib-only: hand-rolled
  CRC-32 and Adler-32 (each independently verified against zlib's own
  output on the same byte sequences), DEFLATE's "stored" (uncompressed)
  block type instead of real LZ77/Huffman compression -- same
  "trivial to verify, don't need small files" tradeoff BMP already
  made, PNG's only real advantage here being that it actually
  previews in most viewers, unlike BMP. Verified two ways: a tiny 2x1
  canvas's *entire* output file (75 bytes) matched an independently
  computed reference byte-for-byte, and separately, a real
  `zlib.decompress` successfully decoded a written file's IDAT
  stream back to the exact original scanline bytes (which also
  transitively confirms the Adler-32 trailer, since `zlib.decompress`
  verifies it internally). Proved the reference-bytes test is
  load-bearing by corrupting the CRC-32 polynomial constant and
  confirming the right tests fail, then restoring.
- **`primitives.mojo`**:
  - `draw_line` — Bresenham.
  - `draw_rect` / `fill_rect` — stroke and fill, axis-aligned.
  - `draw_circle` / `fill_circle` — midpoint algorithm / span-fill,
    both hard-edged.
  - `draw_line_aa` / `draw_circle_aa` / `fill_circle_aa` —
    anti-aliased via supersampled analytic coverage (4x4 sub-pixel
    grid, exact geometric membership test per sub-sample). All three
    share one sampling convention (pixel centered *at* its integer
    coordinate, matching the hard-edged algorithms) so a hard/AA pair
    given identical arguments draws the same shape.
- **`geometry.mojo`** — `Point` (integer x/y) and `Transform2D`
  (affine map: `pixel = rotate(data * scale, rotation) + translate`,
  `Float64` in, `Point` out). Still deliberately minimal beyond that
  one fixed pipeline: no general matrix composition, no "map this data
  range onto this pixel range" convenience constructor -- that
  domain/range awareness belongs one layer up, in `dataviz`'s eventual
  scale types, which will compute a `Transform2D`'s scale/translate
  from a domain and range. `scale_y` is commonly negative in real use:
  pixel-space y increases downward, data-space y conventionally
  increases upward, so flipping a chart's vertical axis is exactly
  what a negative `scale_y` does -- see `examples/transform.mojo` for
  the full data -> pixel -> primitive pipeline this exists for.
  `rotation` (radians, default 0.0) tilts the whole coordinate frame
  around the scaled data space's origin, applied after scale and
  before translate -- a fixed, documented order, not a general
  composable matrix, matching this type's existing "one pipeline, not
  a stack" scope. Hand-derived test values used a 90-degree rotation
  specifically because sin/cos are exact there (0 and 1, not
  floating-point approximations), including one test that would fail
  if rotation were applied in the wrong pipeline position (e.g. to the
  translated point instead of the scaled one). This is a different
  feature from rotating one rendered primitive around its own anchor
  (e.g. an angled axis-tick label) -- that's `text.mojo`'s own
  rotation, unrelated to this data-to-pixel mapping.
- `primitives.mojo` also has:
  - `draw_polyline` / `draw_polygon` — connected/closed line
    segments. Each joint (including a polygon's closing vertex) is
    drawn by exactly one segment, not two, so translucent colors
    don't get double-blended at corners -- same category of fix as
    `draw_rect`'s corners.
  - `draw_polyline_aa` / `draw_polygon_aa` — anti-aliased, via one
    coverage test per pixel against the *minimum* distance across all
    segments (not a loop calling `draw_line_aa` per segment, which
    would double-blend at joints via overlapping round caps -- a
    different mechanism than the hard-edged double-blend hazard, with
    no "skip a sample" equivalent fix).
  - Hard-edged and AA variants are kept as separate functions on
    purpose, never merged behind an `antialias: Bool` -- see the
    module docstring for the reasoning (a shared name would hide a
    real O(radius) vs O(radius^2 * supersample^2) complexity jump, and
    `draw_line_aa`'s `width` parameter has no hard-edged equivalent).
  - `draw_ellipse` — midpoint algorithm, independently re-derived
    (not recalled from a textbook) via the same discrete-calculus
    method as the circle/line algorithms, then hand-traced and
    confirmed to match the actual code's output exactly. Two decision
    parameters (shallow-slope and steep-slope regions), 4-way
    symmetry, integer-only (scaled by 4 to absorb a fractional term).
  - `fill_ellipse` — `fill_circle`'s generalization to independent x/y
    radii: same span-fill-per-row technique, with the per-row bound
    generalized to the integer-exact `dx^2*ry^2 + dy^2*rx^2 <=
    rx^2*ry^2` (the ellipse equation scaled by `rx^2*ry^2` to avoid a
    sqrt/float dependency). Row half-widths independently computed by
    hand and confirmed to match the code's actual output exactly.
  - `fill_ellipse_aa` / `draw_ellipse_aa` — `fill_circle_aa` /
    `draw_circle_aa`'s generalization to independent x/y radii, same
    supersampled analytic-coverage technique. `fill_ellipse_aa` tests
    each sample against the ellipse equation in normalized form,
    `(dx/rx)^2 + (dy/ry)^2 <= 1` -- a direct, exact generalization.
    `draw_ellipse_aa`'s ring test isn't as clean: a circle's inner/
    outer ring boundaries are concentric offsets of one curve, testable
    against one shared distance, but an ellipse's `(rx-0.5, ry-0.5)`
    and `(rx+0.5, ry+0.5)` boundaries are two different ellipses, so
    each sample is tested against both independently in their own
    normalized space (strictly inside outer, not strictly inside
    inner) -- see the function's own docstring for the resulting known,
    accepted imprecision (the ring's actual physical width isn't
    perfectly uniform around the ellipse the way the circle's is).
    Hand-computed coverage values for both, independently verified
    against the exact same 4x4 sub-sample grid the code uses, matched
    the actual code's output exactly on first run.
  - `fill_polygon` — scanline fill (even-odd by default; see
    `fill_rule.mojo` in Done, below, for `FillRule.NONZERO` and full
    self-intersecting-shape support -- this entry's "assumes a simple
    polygon" caveat is stale as of that work and has been removed).
    Y-extent per edge is half-open (`[min(y0,y1), max(y0,y1))`), which
    is *required* for correctness, not a style choice: it's what makes
    a vertex shared by two opposite-direction edges count as exactly
    one crossing (not two) while a genuine local-extremum vertex (a
    triangle's apex) counts as zero net crossings, not two. Concrete,
    surprising-if-undocumented consequence: a polygon's flat bottom
    edge doesn't get its own row filled, so matching
    `fill_rect(x, y, w, h)` exactly needs *asymmetric* corners --
    verified directly against `fill_rect`'s own output, not just
    derived on paper.
- Test convention (`std.testing.TestSuite`, see each package's
  `tests/`), with most non-trivial values hand-verified independently
  rather than just asserted against the code's own output, and every
  double-blend fix proven by temporarily reverting it and confirming
  the test actually catches the regression.
- **`text.mojo`** — `draw_text`, real system-font rendering via
  `third_party/cairo_mojo` (vendored; see its `VENDORED.md`) rather
  than from-scratch TrueType parsing. This is the one place `canvas`
  -- and this whole workspace -- isn't stdlib-only; see the module's
  own docstring and the repo root `README.md` for why. A standalone
  `fonts/` package (a from-scratch, stdlib-only TrueType parser/
  rasterizer) explored the alternative first -- deleted once this
  existed rather than kept around unused; if a stdlib-only text path
  is wanted again, whatever `text.mojo` needs factored out at that
  point can become the next `fonts/`, shaped by what's actually needed
  rather than resurrecting the old exploration wholesale.

  Also has `measure_text` (expose Cairo's own text measurement without
  drawing, for layout decisions made before committing to draw),
  `TextAlign` (LEFT/CENTER/RIGHT, measured against a line's *advance*
  width, matching HTML5 Canvas's textAlign convention rather than
  tight ink bounds), multi-line strings ("\\n"-separated -- Cairo's
  own toy API has no line-break handling at all), and per-block
  rotation around the `(x, y)` anchor (a different feature from
  `Transform2D`'s own `rotation` -- see geometry.mojo's entry -- this
  tilts one rendered text block around its own anchor with everything
  else on the canvas staying upright; that tilts an entire data-to-
  pixel coordinate mapping). Rotation and multi-line share one code
  path with the plain single-line case, not three: every line's ink
  corners get rotated around the shared anchor and combined into one
  bounding box that sizes a single scratch surface, and one line with
  rotation=0.0 reduces exactly to what a simpler implementation would
  have done -- confirmed by direct pixel comparison in
  `canvas_mojo/tests/test_text.mojo`, not just argued.

  **`measure_text_block`/`TextBlockBounds`** expose that same rotated-
  bounding-box math (the part that decides how big `draw_text`'s
  scratch surface needs to be) as its own public, non-drawing query --
  the concrete gap for a `dataviz` axis-label layer: `measure_text`
  alone only measures one unrotated line, but a rotated or multi-line
  tick label's actual on-canvas footprint (needed to size a chart's
  margin, or check whether two labels would overlap) isn't derivable
  from that without redoing `draw_text`'s own rotation math a second
  time. Rather than let that become a second, independently-
  maintained copy of already-hard-won math (see the AA-sampling and
  translate-before-rotate bugs both documented in this file), the
  layout computation itself was extracted out of `draw_text` into a
  private, shared `_layout_block` -- `draw_text` now calls it and
  renders the result, `measure_text_block` calls it and just reports
  the result, so the two can never quietly drift apart. Confirmed
  correctness-neutral two ways: `draw_text`'s own full pre-existing
  test suite passed unchanged after the extraction, and
  `measure_text_block`'s predicted box was cross-checked directly
  against `draw_text`'s *actually-rendered* ink pixels (not just
  reasoned about abstractly) for both an unrotated and a 90-degree-
  rotated case, landing within a pixel or two -- the same floor-
  rounding/AA-fringe slop `draw_text`'s own pixel placement already
  has relative to Cairo's ink extents, not evidence of drift between
  the two functions. Proved that cross-check test itself was load-
  bearing, not just "close enough to always pass": deliberately
  scaled the shared rotation math's `sin` term and confirmed the
  rotated cross-check test (and only that one -- the unrotated case
  is correctly insensitive to a rotation-only bug) failed, then
  restored. An empty or whitespace-only string returns a zero-sized
  box, matching `draw_text`'s own no-op for the identical input rather
  than reporting a box sized by whitespace's nonzero advance.

  A second real, confirmed bug, independent of the `unsafe_data_ptr()`
  one below, and this time root-caused rather than just empirically
  patched around: `cairo_mojo`'s `Context.text_extents()`/
  `show_text()` convenience wrappers silently measure/draw as *empty*
  for any String that isn't a compile-time literal once its length
  crosses roughly 20 bytes -- exactly what multi-line's own internal
  `text.split("\n")` produces per line, which is how this surfaced at
  all (a real string in an early multi-line/rotation demo silently
  drew nothing). The Mojo String itself is never corrupted -- its own
  `byte_length()` and printed content stay correct the whole time;
  only those two wrapper methods' internal C-string marshaling
  mishandles it. Traced by elimination, not a first guess: confirmed
  present regardless of *how* the String was built (`.split()`, manual
  byte-range slicing, char-by-char concatenation, even a deliberately
  over-capacity fresh allocation all still triggered it) as long as it
  wasn't a literal -- and confirmed that an *empirical* capacity-based
  fix (over-allocate, hope it helps) actually made things worse,
  silently corrupting a previously-working short string into garbage,
  non-repro-stable-within-a-run-but-different-across-runs output --
  caught only because a short-string regression test that had nothing
  to do with the original bug started failing too. The real fix:
  `_c_string()` manually builds a NUL-terminated `UnsafePointer[c_char]`
  buffer, and `_text_extents()`/`_show_text()` call `cairo_mojo`'s own
  *raw* FFI bindings directly with it, bypassing the broken wrapper
  methods' marshaling entirely -- verified deterministic and correct
  across many repeated runs, for a previously-broken long string and a
  previously-working short one together, not just whichever one
  motivated the fix. Also worth naming plainly: the first regression
  test written for this (a `measure_text` call with a string literal)
  passed even against the *reverted*, broken code -- because a literal
  never triggers the bug in the first place, only a runtime-constructed
  String does. Caught by actually reverting the fix and checking the
  test failed, not by assuming a green test proved anything; replaced
  with a version that builds the string via concatenation instead.
- **Dash patterns** — optional `dashes`/`dash_offset` parameters
  (empty by default, meaning solid, exactly the pre-existing behavior)
  added to `draw_line`, `draw_line_aa`, `draw_polyline`,
  `draw_polygon`, `draw_polyline_aa`, `draw_polygon_aa`. Not a new
  hard/AA split, since dashing doesn't introduce the kind of
  branch-specific parameter or complexity-class jump that split
  exists to keep visible (see the module docstring) -- it composes
  orthogonally with both. `_is_dash_on` (private, but directly unit
  tested -- Mojo doesn't treat a leading underscore as import-private
  the way Python's convention-only privacy might suggest) is the
  shared core: given a distance along a path and an alternating
  on/off length list, is that point drawn? Floor-based modulo (not
  truncating `%`) so a negative offset wraps correctly; an odd-length
  pattern is doubled, matching Cairo's own convention for anyone
  porting a pattern from it.

  The two rasterization styles measure "distance along the path"
  differently, each for a concrete reason rather than arbitrarily:
  the hard-edged version accumulates actual Bresenham step lengths (1
  for an axis step, sqrt(2) for a diagonal one) as it walks, since
  that's what it already has on hand and it's what real per-pixel
  distance-so-far means for a raster walker; the AA version instead
  uses each sample's already-computed, already-clamped projection
  fraction `t` times the segment's true straight-line length, since
  there's no pixel walk to measure steps along in a supersampled
  algorithm. For a multi-segment polyline/polygon, a dash pattern's
  phase carries continuously across joints -- each segment's distance
  picks up where the previous one left off, not reset to 0 -- proven
  load-bearing, not just claimed, by breaking the carry-forward and
  confirming the joint-phase test fails, then restoring.
  `_draw_polyline_core_aa`'s per-sample "minimum distance across all
  segments" search (see the `draw_polyline_aa` entry above) needed a
  real restructure, not just a filter bolted on afterward: a segment
  is only a coverage candidate if it's both within `half_width` AND
  on-dash at that exact projected point, evaluated independently per
  segment before taking the minimum -- so a sample near a joint where
  one segment's dash state is off but a neighbor's is on at the same
  physical point still gets covered correctly, rather than the whole
  sample being decided by whichever segment happened to be closest.
- **`path.mojo`** — a general `Path` (move_to/line_to/quad_curve_to/
  cubic_curve_to/close, chained `mut self` calls, no fluent-style
  returns -- matches `Canvas`'s own builder methods) that flattens
  into straight-line segments and hands off to the already-tested
  polyline/polygon/fill machinery in `primitives.mojo`, rather than
  reimplementing fill or stroke logic. Fixed-step curve flattening
  (16 steps/segment, not adaptive), the same choice `fonts/raster.mojo`
  made for TrueType's quadratic curves before this package had its own
  general path type (see the `text.mojo` entry above for that
  package's own history). `fill_path` combines every sub-path's
  scanline crossings together (even-odd) -- the same multi-contour
  hole-punching technique, independently reimplemented here rather
  than shared code (`fonts` and `canvas` were never allowed to depend
  on each other -- see the repo root `README.md` -- and `fonts` is
  gone now regardless). Proved hole-punching is load-bearing the same
  way `fonts/raster.mojo` did: breaking the multi-sub-path combination
  (scanning only the first sub-path) and confirming the hole-punching
  test catches it, then restoring. `stroke_path`/`stroke_path_aa`
  route each sub-path to `draw_polygon`/`draw_polyline` (or their AA
  equivalents) depending on whether that specific sub-path's own
  `close()` was called -- verified directly: an unclosed sub-path's
  implicit closing edge is confirmed absent, not just "close() exists".
  Quadratic/cubic point math independently verified by hand before
  trusting the code's own output, then confirmed the *flattened*
  curve actually passes through that hand-computed midpoint at the
  exact step index `_CURVE_STEPS` predicts, not just that the
  standalone curve-math functions are correct in isolation.
- **`gradient.mojo`** — `LinearGradient`, the minimal fill-source
  abstraction that justifies existing: `fill_rect_gradient`
  (`primitives.mojo`) and `fill_path_gradient` (`path.mojo`) are the
  *only* two linear-gradient-aware fill entry points, not every
  `fill_*` primitive retrofitted with a gradient variant --
  `fill_circle_gradient`/`fill_ellipse_gradient`/`fill_polygon_gradient`
  are easy to add later if something concrete needs one, not built
  speculatively now; these two cover the actual dataviz cases
  (bar/area fills) this exists for. Only "pad" extend behavior is
  supported (a point beyond either endpoint gets that endpoint's own
  color, clamped -- not tiled/mirrored the way real gradient APIs also
  offer), the case an area or bar fill actually wants: the gradient's
  edges are the shape's own edges, not a repeating pattern. Stops
  don't need to be added in offset order -- verified that specifically,
  not just "gradients work": corrupted the bracketing-pair search to
  assume insertion order and confirmed the out-of-order test (and only
  that one -- the in-order test still passed, which is exactly why
  both exist) failed, then restored.

  **`RadialGradient`** followed once `fill_path_gradient`'s own donut
  example made the gap concrete: it used a `LinearGradient` along a
  diameter (named `radial_ish` in the code, honestly) to fake a
  concentric look, which is visibly wrong off-axis. `RadialGradient`
  (center + radius, offset 0.0 at the center to 1.0 at the radius) has
  its own `fill_rect_radial_gradient`/`fill_path_radial_gradient`
  entry points, kept as separate functions from the linear ones rather
  than a shared "Gradient" trait/generic -- matches this codebase's
  existing preference for distinct named functions over one type
  dispatched by a flag (the reason `LinearGradient` itself got
  dedicated `fill_*_gradient` functions instead of a boolean on
  `fill_rect`/`fill_path` in the first place), and this project has no
  trait-generics precedent anywhere else to introduce for a single
  feature. What *is* shared: `_color_at_t`, the stop-bracketing-and-
  interpolation logic both `LinearGradient.color_at` and
  `RadialGradient.color_at` reduce to once each has computed its own
  `t` (axis projection vs. distance-from-center/radius) -- genuinely
  identical code, not near-identical, so factoring it was correctness-
  neutral refactoring, confirmed by the fact that all of
  `LinearGradient`'s pre-existing tests passed unchanged once it was
  rewritten to call the shared helper.

  Deliberately the simple single-circle form (center + radius), not
  the general two-circle "off-center focal point, focal point has its
  own radius" gradient SVG/Cairo/HTML5 Canvas also offer -- that
  generality mostly exists to fake a lit-sphere look, not a dataviz
  need identified so far (bubble/donut centers, a radial legend
  swatch, all want a plain concentric gradient); easy to widen later.
  `radius == 0.0` is handled as a documented degenerate case (resolves
  to `t=1.0`, a solid fill of the highest-offset stop, rather than
  dividing by zero) instead of crashing, the same category of decision
  `LinearGradient` already made for its own degenerate case (two
  coincident endpoints). Distance math verified with exact integer
  Pythagorean triples (a 3-4-5 right triangle scaled as needed) so a
  test's expected `t` lands on a precise value instead of "close to"
  one -- confirmed in `examples/gradient.mojo`'s donut, now filled with
  a genuinely concentric gradient instead of the old linear
  approximation, and a rectangular swatch with a radial highlight
  (`fill_rect_radial_gradient`, no circle primitive involved at all).
- **Arc primitives** (`primitives.mojo`) — `draw_arc`/`draw_arc_aa`
  (a bare curved boundary), `fill_arc`/`fill_arc_aa` (a solid
  pie-slice wedge), `fill_ring_sector`/`fill_ring_sector_aa` (a donut/
  ring segment) -- closing the one concrete gap identified when
  scoping `dataviz` against `canvas`: pie/donut charts need wedge and
  ring-segment shapes, and without a native arc, building one meant
  hand-approximating with cubic Beziers (see `gradient.mojo`'s example,
  which does exactly that for a full circle). `_arc_points` instead
  samples exact circle math (`cx + r*cos(theta)`, `cy + r*sin(theta)`)
  directly -- matching `draw_circle`/`draw_ellipse`'s own preference
  for independently-derived exact math over an approximation -- at a
  step count proportional to `radius * angle_span`, not `path.mojo`'s
  fixed per-curve step count, since arc radii vary far more widely in
  real use (a small pie-chart marker vs. a full-page donut) than a
  `Path` curve's typical size does. `fill_arc_aa`/`fill_ring_sector_aa`
  are supersampled analytic coverage tests against the wedge/ring's
  own exact definition (radius bounds AND an angular span test,
  `_angle_in_span`) -- not a flattened polygon run through a generic
  AA fill, since no such thing exists in this codebase (`fill_polygon`
  is hard-edged only; `draw_polygon_aa` is an AA *outline*, not a
  fill) and the wedge/ring's membership test was clean enough
  analytically that inventing one wasn't needed. `_angle_in_span`'s
  own job -- normalizing a sample's raw `atan2` angle (range
  `(-pi, pi]`) into an arbitrary `[start_angle, end_angle]` window --
  matters concretely, not just in theory: a wedge spanning the
  `atan2` discontinuity at +/-pi (e.g. one centered straight up)
  needs it to render as one continuous shape instead of splitting or
  vanishing, confirmed both visually (`examples/arc.mojo` draws
  exactly this case) and by corrupting the normalization loop and
  watching the wraparound-specific test (and only that one) fail.
  Also consolidated `_round_to_int` (used by `geometry.mojo`,
  `path.mojo`, and now this) into one definition in `geometry.mojo`
  instead of a third hand-copied duplicate -- a small cleanup, not
  scope creep, done because writing a third copy for the same
  already-twice-duplicated helper would have made the inconsistency
  worse, not just left it alone.
- **`fill_rule.mojo`** -- `FillRule` (EVEN_ODD default / NONZERO),
  an optional parameter on `fill_polygon`, `fill_path`, and
  `fill_path_gradient` -- properly closes the "self-intersecting
  polygon fill" gap this file used to list under "Plausibly next".
  `fill_polygon`'s per-row crossings now carry a signed `direction`
  (+1/-1, from each edge's y-order) instead of just an x position;
  `_spans_from_crossings` (shared by `fill_polygon` and, via
  `path.mojo`'s `_row_crossings`, `fill_path`/`fill_path_gradient`)
  scans a running signed winding total per row and calls a point
  inside via `_is_inside(winding, fill_rule)` -- `abs(winding) % 2 ==
  1` for EVEN_ODD, `winding != 0` for NONZERO. EVEN_ODD via signed-
  winding parity is provably identical to the old plain crossing-count
  parity for *any* crossing sequence (each crossing changes the
  winding total by an odd amount, so parity flips exactly once per
  crossing regardless of sign) -- confirmed not just by that argument
  but empirically too, every pre-existing `fill_polygon`/`fill_path`
  test (including the exact-pixel `fill_rect`-equivalence one) passed
  unchanged under the rewrite.

  Rewriting to a signed scan surfaced a real, previously-undocumented
  bug the old docstring only warned about rather than fixed: two
  crossings landing on the same integer x (e.g. a self-intersection,
  or two sub-paths' edges meeting exactly) can produce two raw spans
  that both include that x under the inclusive-inclusive fill
  convention -- e.g. crossings at x=[10,15,15,20] naively produce
  spans (10,15) and (15,20), both covering x=15, a genuine double
  `set_pixel`/double-blend. Caught by hand-tracing a concrete example
  (not trusting the abstract "one crossing in, one crossing out"
  argument), fixed with an explicit merge pass over consecutive spans
  wherever `next.start_x <= last.end_x + 1`. Proven load-bearing: a
  synthetic-crossings unit test (`_spans_from_crossings` called
  directly, bypassing polygon geometry entirely) confirmed exactly one
  merged span comes out; reverting the merge step to a plain
  span-per-pair list was confirmed to make (only) that test fail, then
  restored.

  A single self-crossing polygon (a "bowtie") turned out not to be
  useful for demonstrating EVEN_ODD vs. NONZERO actually diverging --
  its pinch point only ever produces 2 crossings, which resolve to the
  same single span under either rule, so it's kept as a "self-
  intersection doesn't crash or misbehave, both rules agree" sanity
  test instead. The real divergence demonstration (`test_path.mojo`,
  `examples/fill_rule.mojo`) uses two same-direction-wound overlapping
  squares as two sub-paths of one `Path`: EVEN_ODD punches a hole
  where they overlap (crossed twice = outside again), NONZERO fills
  the union solid (signed winding reaches 2, still nonzero) -- hand-
  verified first, and the two tests share an identical shape so the
  only variable is the `fill_rule` argument itself.
- **`fill_polygon_aa`/`fill_path_aa`** — the one inconsistency left
  once every other filled primitive (circle/ellipse/arc/ring, all in
  Done above) already had an anti-aliased companion: an arbitrary
  filled shape -- the general case an area chart's region, a smoothed-
  edge custom marker, or a curved `Path` fill actually is -- could
  only ever render hard-edged. `draw_polygon_aa` already existed, but
  only as an AA *outline*; these are the fills `fill_polygon`/
  `fill_path` themselves never had. Same supersampled-analytic-
  coverage technique `fill_circle_aa` established (NxN sub-pixel grid
  per candidate pixel, coverage fraction becomes that pixel's alpha,
  each output pixel visited exactly once so there's no double-blend
  hazard) and the same pixel-centered-AT-its-integer-coordinate
  convention, generalized from "distance to a center" to "inside a
  shape" via `_point_in_polygon`/`_point_in_subpaths` -- the continuous
  analog of `fill_polygon`'s per-row crossing scan and `fill_path`'s
  `_row_crossings`, sharing the identical `_is_inside(winding,
  fill_rule)` decision both hard-edged functions already use, so a
  hard-edged and AA fill of the same shape agree on exactly where its
  boundary is, not just approximately. `fill_rule` threads through
  both, the same `FillRule.EVEN_ODD`/`NONZERO` choice `fill_polygon`/
  `fill_path` themselves take.

  Coverage math hand-verified before trusting it (same
  right-triangle-with-a-known-hypotenuse-equation technique used
  elsewhere in this file): a 4x4 sub-sample grid at a pixel straddling
  the hypotenuse of triangle `(0,0),(20,0),(0,20)` gives exactly 6/16
  covered, matching the code's actual output on first run, not
  adjusted to match it after the fact. Proven load-bearing by
  reintroducing the exact historical "off by half a pixel" bug
  documented below under `fill_circle_aa` (dropping the `- 0.5`
  pixel-centering term) into `fill_polygon_aa`'s own sampling loop:
  confirmed the partial-coverage test (and only that one) failed, then
  restored -- the same convention/reasoning error already caught once
  for circles turned out to be worth checking wasn't silently
  reintroduced here.

  `fill_polygon` has no multiple-sub-path notion the way `fill_path`
  does, so a bowtie's single pinch point still isn't enough to
  demonstrate real EVEN_ODD-vs-NONZERO divergence on it (same
  limitation `fill_rule.mojo`'s own entry above already found for the
  hard-edged case) -- confirmed instead on a genuinely different
  construction: two same-direction squares connected into one closed
  polygon boundary by a zero-width "bridge" edge walked out and back,
  so the winding number actually reaches 2 in their overlap. Verified
  by hand first that the bridge's own coincident opposite-direction
  traversal cancels out everywhere the test points sample, before
  trusting it as a real divergence demonstration rather than an
  accident of a degenerate shape. `fill_path_aa`, which *does* support
  multiple sub-paths, reuses the same two-overlapping-squares
  construction `fill_rule.mojo`'s own entry already used for the
  discrete case, confirming the identical divergence holds for the
  continuous membership test too. See `examples/polygon.mojo` (a
  fourth pentagon, `fill_polygon_aa`, alongside the existing three) and
  `examples/path.mojo` (a second leaf, `fill_path_aa`, specifically
  because a curved boundary is where hard-edged jaggedness is most
  visible, unlike the axis-aligned shapes the polygon example uses).
- **`downsample()`** (`canvas_mojo/resize.mojo`) -- box-filter shrink a
  Canvas by an integer factor, each output pixel the rounded mean of
  its `factor x factor` source block. Built for a concrete problem
  raised against `dataviz`'s own example output ("the text looks
  fuzzy"), and refined once by real pushback rather than shipped on
  the first idea: the first attempt just rendered `dataviz` examples
  onto a bigger canvas (`Theme.scale`, see dataviz_mojo/ROADMAP.md) and
  left the *output file* that much bigger too -- which only looks
  sharper in a viewer that happens to scale the larger file back down
  to fit some display area, not a real per-pixel quality improvement,
  and does nothing for a viewer that shows images at native pixel
  size. `downsample()` is the actual fix: render at `factor`x the
  intended final size, then shrink back down through this to that
  *exact* original size -- real supersampled anti-aliasing baked into
  the file itself, independent of anything that later displays it.
  Confirmed directly, not just argued: the same scatter scene
  rendered once plainly at 640x420 and once at 1920x1260-then-
  downsample()d back to 640x420 -- both files the *identical*
  dimensions, viewed side by side, the supersampled one visibly finer
  at the shared axis/legend text.

  Rounds rather than truncates each channel average (`(sum + n // 2)
  // n`, not `sum // n`) -- confirmed by a dedicated test case whose
  true average lands exactly on .5 (a 2-and-2 split of 0/1 values,
  average 0.5, must round *up* to 1 -- truncation would silently give
  0 and skew every downsampled image slightly dark). `factor=1` is a
  valid, un-special-cased no-op copy; a `factor` that doesn't evenly
  divide both dimensions raises rather than silently truncating a
  partial edge block or rounding to a slightly wrong output size.
- **`DrawTarget` (`canvas_mojo/draw_target.mojo`) + `SvgCanvas` (`canvas/
  svg.mojo`)** -- a vector rendering backend for `dataviz`, sitting
  alongside the raster `Canvas` one rather than replacing it.
  Motivated by a direct question raised against `downsample()` itself
  (the entry just above): does starting from a raster foundation and
  patching resolution/sharpness problems onto it (`Theme.scale`,
  `downsample()`) just push a problem downstream that an SVG-based
  design would never have had in the first place, since a vector
  format has no fixed pixel grid to lose sharpness at? The honest
  answer was yes for the sharpness problem specifically, but no for
  the whole raster investment -- `canvas`'s own AA/path-fill/gradient/
  clip engineering isn't wasted, it's just not the only backend
  `dataviz` renders through anymore.

  `DrawTarget` is a trait covering exactly the six shape primitives
  `dataviz_mojo/plot.mojo` actually calls (`fill_rect`, `draw_line_aa`,
  `fill_circle_aa`, `fill_arc_aa`, `stroke_path_aa`, `fill_path_aa`) --
  `Canvas` (`canvas_mojo/buffer.mojo`) conforms via six thin methods that
  delegate to the exact free functions every existing call site
  already calls; `SvgCanvas` conforms by emitting SVG markup strings
  instead of touching a pixel buffer at all, so it needs none of
  `canvas`'s own AA/coverage/scanline-fill machinery -- an SVG
  renderer (browser, image viewer, PDF exporter) does that itself, at
  whatever resolution it's displayed at.

  Getting `Canvas` to conform to a shared trait took two real, wrong
  turns before landing on the shape it has now, both instructive
  enough to record rather than silently discard:
  1. A first version put `draw_text` in `DrawTarget` too, with `Canvas`
     delegating to `canvas_mojo.text.draw_text` (needs `cairo_mojo`).
     Compiling *any* file that merely imports `Canvas` from `canvas.
     buffer` -- `canvas_mojo/tests/test_buffer.mojo`, which touches no text
     at all -- then failed with "unable to locate module 'cairo_mojo'",
     since Mojo resolves a struct's entire method surface (and
     whatever those methods import) at the point the struct itself is
     declared, not lazily per call. This would have broken the
     careful cairo-is-opt-in separation `canvas_mojo/text.mojo`'s own
     docstring documents ("Text is the deliberate exception") for
     every canvas user, not just the ones drawing text. Fixed by
     excluding `draw_text` from `DrawTarget` entirely -- see
     `_TextRequest` in dataviz_mojo/ROADMAP.md's own entry for how text
     gets handled generically without this.
  2. Before landing on the "text isn't in the trait" fix, a move-in/
     move-out wrapper struct (`RasterTarget`, holding an owned
     `Canvas`, meant to keep `canvas_mojo/buffer.mojo` itself untouched)
     was tried as an alternative way to keep cairo out of `Canvas`'s
     own file. Hit a genuine Mojo ownership-tracking limitation,
     confirmed by reducing to a minimal repro: constructing the
     wrapper, then extracting its one field back out via `wrapper.
     canvas^`, failed with "field ... destroyed out of the middle of a
     value" even with *zero* method calls in between -- Mojo doesn't
     support this specific partial-move-out-of-a-`var` pattern in this
     version. Abandoned once confirmed reproducible in isolation, not
     worked around blindly.

  Also confirmed directly, not assumed, before committing to the
  design: Mojo's trait conformance is nominal (a struct must
  explicitly declare a trait in its own signature -- `Canvas(Copyable,
  DrawTarget, Movable)` -- not satisfied by merely having matching
  methods), and multi-file circular imports genuinely work in this
  Mojo version (`canvas_mojo.buffer` -> `canvas_mojo.draw_target` ->
  `canvas_mojo.path` -> `canvas_mojo.buffer`, and separately -> `canvas.
  primitives` -> `canvas_mojo.buffer`) -- both checked with minimal
  standalone reproductions before touching real code, not discovered
  by trial and error against the real module graph.

  `TextAlign` moved out of `canvas_mojo/text.mojo` into its own `canvas/
  text_align.mojo` as part of this -- it was always a plain, cairo-
  free `Int`-wrapping struct, just previously defined inside a module
  whose own top-level import list pulled in `cairo_mojo` regardless.
  `canvas_mojo.text` re-exports it (`from canvas_mojo.text_align import
  TextAlign`), so every pre-existing `from canvas_mojo.text import
  TextAlign` call site kept working unchanged.

  `SvgCanvas` itself: `fill_arc_aa` draws each wedge as an SVG arc
  path (`M center L start A r,r 0 large-arc-flag,1 end Z`) with no
  sign flip for the sweep direction -- SVG's own coordinate space is
  y-down by default, the same as `canvas`'s, so increasing angle
  already sweeps clockwise in both (see dataviz_mojo/ROADMAP.md's own
  `Mark.ARC` entry, which confirmed this same fact for the raster
  path). `stroke_path_aa`/`fill_path_aa` convert `Path.commands`
  directly to an SVG `d` string (`_MOVE_TO`/`_LINE_TO`/`_QUAD_TO`/
  `_CUBIC_TO`/`_CLOSE` map one-for-one onto `M`/`L`/`Q`/`C`/`Z`, both
  using absolute coordinates already -- no coordinate-system
  translation needed either). `draw_text` (a plain method, not part of
  `DrawTarget` -- see above) maps `TextAlign` onto `text-anchor`
  (`start`/`middle`/`end`) and escapes `&`/`<`/`>` in text content
  (`&` first, always, since escaping the other two each introduce a
  literal `&` a second pass would then mangle).

  16 tests (`canvas_mojo/tests/test_svg.mojo`, no cairo needed -- confirmed
  by running with `-I .` alone) assert on the generated markup's own
  string content, hand-derived the same rigor pixel-color assertions
  get elsewhere in this workspace: exact rect/line/circle/path
  attributes, an arc wedge's endpoint coordinates (cross-checked via
  `python3`, including one genuinely non-`nice` floating-point value
  -- confirmed Mojo's `cos`/`sin` and Python's `math.cos`/`sin`
  produce bit-identical output for the same input before trusting an
  exact-string match against it, not assumed), and the large-arc-flag
  boundary (a span > pi, deliberately not exactly pi -- an exact-pi
  wedge is an ambiguous edge case not worth pinning down a test to).
  Extended for `fill_ring_sector_aa` (donut wedges, added for
  dataviz's own donut-chart feature -- see dataviz_mojo/ROADMAP.md's own
  entry) the identical way: hand-derived quarter- and wide-wedge
  endpoint coordinates for a ring instead of a full wedge, including
  the same large-arc-flag boundary check on both the inner and outer
  arc. See "Bugs found and fixed along the way" below for a real
  floating-point formatting bug this same hand-derivation process
  caught while building the wide-wedge ring-sector test.

- **Split into its own standalone repo (2026-08-13)** — `canvas_mojo`
  moved out of the combined `graphics` pixi workspace it started in
  (alongside its own sibling `dataviz_mojo`, still there for now) into
  `github.com/randyzwitch/canvas_mojo`, its own git repo with its own
  `pixi.toml`/CI. First step toward this: renaming the folder itself
  from plain `canvas` to `canvas_mojo` inside the shared workspace
  (recorded in this file's own entries above, before the split), so
  the folder was already named the way its own repo would be by the
  time the actual `mv` happened. `dataviz_mojo` stays inside the
  `graphics` workspace for now (referencing this repo the same way it
  always has, no import changes needed) -- splitting it out too is a
  separate, not-yet-scheduled step.

  Repo-root layout matches this package's own long-standing internal
  convention rather than adopting a different split-source/no-source
  layout some other Mojo pixi packages use (`cairo-mojo`'s own repo, for
  one, keeps `examples/`/`test/` at repo-root level, sibling to -- not
  nested inside -- its packaged source directory): this repo's own
  `canvas_mojo/` subdirectory is a byte-identical copy of what was
  already inside the `graphics` workspace, `examples/`/`tests/` and all,
  preserving every existing internal doc cross-reference unchanged and
  zero risk of quietly breaking one during the move, at the cost of the
  packaged build artifact (once `pixi build` actually works -- see
  "Deferred on purpose," below) technically bundling example/test files
  too. Considered a fine trade for now, revisit once the build path
  itself is actually testable.

  `third_party/cairo_mojo` (the vendored Cairo binding `canvas_mojo/
  text.mojo` depends on) came along as a plain copy too, at the same
  relative path it already had -- every existing `-I third_party/
  cairo_mojo` flag in this repo's own `pixi.toml` tasks needed no
  changes. `pixi run test`/`pixi run example` confirmed clean in the
  new repo, standalone, before pushing -- not assumed to still work
  just because they did inside the old shared workspace.

## Bugs found and fixed along the way

Worth keeping visible rather than just folded silently into the diff:

- **`SvgCanvas`'s raw `String(Float64)` coordinates could differ by 1
  ULP depending on compilation context, breaking exact-string test
  assertions that were otherwise completely correct.** Caught live,
  not hypothesized: a hand-derived `fill_ring_sector_aa` test,
  computed and cross-checked via `python3` exactly like every other
  float-coordinate test in this file, still failed. Debugging (a
  temporary `print()` of the real runtime output, since two separate
  isolated single-file probes of the *identical* `cx + radius *
  cos(angle)` expression both matched `python3` exactly) narrowed it
  to one specific value differing in its last bit -- `33.6589094784097`
  in isolation vs. `33.658909478409704` compiled as part of the larger
  `test_svg.mojo` file, confirmed via `.hex()` in Python to be
  genuinely different `float64` bit patterns, not a display artifact.
  Root cause not chased further (likely FMA/instruction-scheduling
  differences depending on surrounding code, a known class of
  cross-context floating-point non-reproducibility, not specific to
  this codebase) -- the fix instead removes the precondition the bug
  needs to matter at all: `_format_svg_float` rounds every coordinate/
  width/size `SvgCanvas` emits to a fixed 3 decimal places (millipixel
  precision, far finer than any real display renders, so nothing
  visible is lost) before turning it into a string, the same fix
  `dataviz_mojo/scale.mojo`'s own `_format_fixed` already used for a
  different symptom of the same underlying "don't trust `String
  (Float64)`'s own drift" lesson. Also incidentally cleans up
  `Mark.ARC`'s own wedge output (see dataviz_mojo/ROADMAP.md): a value that
  used to print as `219.99999999999997` (`pi`'s own finite
  representation leaking through two wedges meant to meet at exactly
  the same point) now rounds to the correct, clean `220.000` both
  wedges actually share.

- **AA alpha ignored the caller's color.a.** All three original AA
  functions computed final pixel alpha as `coverage_fraction * 255`,
  discarding the input color's own alpha entirely -- so a fully-
  covered pixel with `alpha=128` rendered fully opaque. Invisible in
  every test and example up to that point because they all happened
  to pass opaque colors, where `coverage * 255 == coverage * color.a`
  by coincidence. Found while probing `draw_polyline_aa` with a
  translucent color for the first time. Fixed in all four AA
  functions; added regression tests using translucent input colors
  specifically, since that was the exact gap that hid it.
- **AA circle sampling was off by half a pixel.** `fill_circle_aa` /
  `draw_circle_aa` originally sampled pixel `(px,py)` as a unit square
  with `(px,py)` at its *corner*, not centered *at* `(px,py)` like the
  hard-edged algorithms -- so `draw_circle_aa(c, cx, cy, r, ...)` drew
  a circle shifted from `draw_circle(c, cx, cy, r, ...)` given
  identical arguments. Caught by checking whether `supersample=1`
  degenerates to exactly the hard-edged decision (it should, and
  didn't).
- **`cairo_mojo`'s `unsafe_data_ptr()` reads back garbage at buffer
  boundaries.** Confirmed via probe on a *freshly-created, never-drawn*
  `ImageSurface` (should read back as all-zero, transparent black --
  Cairo's own documented guarantee): the first 16 bytes of the pixel
  buffer come back as non-deterministic garbage every time (different
  random-looking bytes each run, at the exact same offsets), reproduced
  across surface sizes from 9x34 up to 200x200; a small surface also
  showed one bad pixel near the buffer's tail end that a larger one
  didn't. `write_to_png` -- which reads the same buffer natively in
  Cairo's own C code, not through Mojo's pointer marshaling -- round-
  trips clean, so the real pixel data is correct; the bug is
  specifically in reading it back this way, either in the vendored
  binding or in Mojo's own `UnsafePointer` indexing at a freshly-
  returned pointer's boundary. Root cause not confirmed (would need
  deeper C-level or compiler-level debugging than was in scope here).
  Fix is deliberately narrow and empirical rather than a guess at the
  real cause: `draw_text` never reads the first or last row of the
  scratch surface it renders into (`_BORDER_ROWS_TO_DISTRUST` in
  `text.mojo`), with the ink margin widened to guarantee real glyph
  content never lands there anyway. Proven load-bearing by reverting
  it and re-running the tests: the alpha=0 no-op test failed every
  time, the translucent-blend-bounds test failed about two-thirds of
  the time (matching the garbage's non-determinism) -- both green
  again once restored.
- **`draw_circle` double-blended at 8 points per circle.** At `y==0`
  (loop start) and `x==y` (the loop's diagonal crossing), several of
  the 8 symmetric `set_pixel` expressions collapse onto the same
  pixel -- e.g. `(cx+y,cy+x)` and `(cx-y,cy+x)` both become `(cx,cy+x)`
  when `y==0`. Plotting all 8 unconditionally blended a translucent
  color twice (confirmed via probe: value 150, exactly what you get
  blending the same color over an already-blended 100) at 4 axis
  points and 4 diagonal points on every circle. Present since the very
  first `draw_circle` implementation; found only while designing
  `draw_ellipse`'s symmetry and tracing through the same hazard
  deliberately this time.
- **Mojo toolchain upgrade (1.0.0b2 -> 1.0.0 stable) broke `svg.mojo`'s
  `_hex_byte`, not a bug in this codebase's own logic but a real,
  reproducible break worth recording the same way: the stable release
  removed plain positional `String` indexing (`s[i]`) entirely --
  `_HEX_DIGITS[v // 16]` (a fixed, pure-ASCII hex-digit literal) failed
  to compile with a real, specific compiler error naming the fix
  (Mojo's own UTF-8-safety concern: a byte position, a codepoint
  position, and a grapheme-cluster position can all mean different
  things for the same index into a non-ASCII string), not a vague
  deprecation. Fixed with `[byte=...]`, the raw-UTF-8-byte accessor the
  error itself suggested -- correct here specifically because `_HEX_
  DIGITS` is guaranteed pure ASCII, where "byte" and "codepoint" are
  the same thing; a string with real multi-byte characters would need
  `[codepoint=...]`/`[grapheme=...]` instead depending on intent. `pixi
  run test`/`pixi run example` both confirmed clean afterward (this was
  the *only* break the upgrade caused across the whole workspace,
  including the `dataviz` package and the `cairo_mojo` FFI bindings --
  the latter's own long-standing `MutExternalOrigin`-deprecation
  warnings, mentioned elsewhere in this file, are still just warnings
  in 1.0.0 stable, not yet a break).

## Plausibly next, roughly in order of how directly they build on what exists

1. **AA glyph edges in `text.mojo`** — Cairo already anti-aliases for
   us (that's most of the point of using it), so this isn't the same
   gap it would've been for a from-scratch rasterizer; listed here
   only in case a use case needs finer control (e.g. disabling AA,
   subpixel hinting modes) than the current fixed defaults expose.

## Deferred on purpose, not forgotten

- **Install `cairo_mojo` as a real pixi/git dependency, retiring
  `third_party/cairo_mojo`'s vendored copy** — wanted, directly
  attempted, and currently blocked by an upstream bug, not a design
  question left open on this side. `third_party/cairo_mojo/VENDORED.md`'s
  own original reason for vendoring instead (cairo-mojo's own `pixi.toml`
  hard-pinning `mojo == 1.0.0b1`, conflicting with this workspace's own
  pin) is now moot -- this workspace's Mojo upgrade to `1.0.0` stable
  (see this file's own "Mojo toolchain upgrade" entry, above) landed
  inside cairo-mojo's own `mojo >=1.0.0b1,<2` constraint, so the two no
  longer conflict.

  Direct attempt, not just checked in theory: `pixi add --git https://
  github.com/MoSafi2/cairo-mojo cairo-mojo` (after enabling the
  `pixi-build` preview feature cairo-mojo's own real `pixi-build-mojo`
  backend needs) resolves dependencies cleanly -- pixi finds the
  package, satisfies `mojo`/`cairo` on both sides -- but the actual
  build step fails: the `pixi-build-mojo` backend (v0.1.14, the only
  version pixi's backend resolution offered regardless of which channel
  was searched, even after clearing the local backend cache and
  retrying) still invokes the now-deprecated `mojo package` command,
  which Mojo 1.0.0 doesn't merely warn about anymore but hard-errors on
  (`mojo: error: '...' does not correspond to a Mojo package`) --
  confirmed reproducible, not a one-off fluke. This is a real bug in
  third-party tooling (either `pixi-build-mojo` needing to move to
  `mojo precompile`, or cairo-mojo's own build recipe needing an update)
  external to this repo, not something fixable by editing anything
  here.

  Retry once `pixi-build-mojo` publishes a version built against current
  Mojo's CLI (`pixi search -c https://conda.modular.com/max -c conda-
  forge pixi-build-mojo` to check what's available) -- if the resolve-
  then-build sequence above completes clean and `pixi run test`/`pixi
  run example` still pass, retire `third_party/cairo_mojo`'s vendored
  copy and this entry both. Explicit direction from the user to keep
  the vendored copy in the meantime rather than leave the workspace
  without working text rendering.
- **This package's own `pixi build`/`pixi install`** — this repo's own
  `pixi.toml` already carries a correct `[package]` section (the same
  `pixi-build-mojo` backend, `[package.build.config.pkg]` shape --
  discovered by direct trial-and-error against a minimal throwaway
  package before being trusted here, not guessed at from cairo-mojo's
  own manifest alone: an early attempt without that `config.pkg` block
  failed metadata extraction outright with "No bin or pkg configuration
  detected," a different, earlier failure than the one below), but
  can't actually be verified working end to end -- the exact same
  `mojo package`-is-deprecated-and-now-hard-errors bug the entry just
  above documents for `cairo-mojo` specifically turns out to be backend-
  wide, not project-specific: a from-scratch, trivial one-file test
  package (no dependency on this one at all) hit the identical error,
  confirming it's `pixi-build-mojo` itself broken against Mojo `1.0.0`,
  for any Mojo package, regardless of git vs. local source. A second,
  independent bug surfaced in that same trial run too: the backend's
  own work-directory path came out visibly double-concatenated
  (`.../pkgtest//tmp/.../pkgtest/mypkg`), a second reason not to trust
  this build path yet even once the deprecated-command issue is fixed.

  Same retry condition as the entry above (a `pixi-build-mojo` version
  built against current Mojo's CLI) -- once available, actually run
  `pixi build`/`pixi install` against *this* package specifically before
  trusting the `[package]` section is correct as shipped, not just that
  metadata extraction gets further than it used to.
- **`UnsafePointer`-backed buffer** instead of `List[UInt8]` — a
  performance path, not a correctness one. Don't reach for it before
  profiling says the `List` bounds-checking is actually the
  bottleneck.
- **Blend modes beyond src-over** (multiply, screen, overlay, the rest
  of the Porter-Duff/CSS set) — a real raster feature, but nothing
  built so far has asked for one. Add when a concrete caller needs it,
  not speculatively. (Gradient fills are no longer on this list --
  see `gradient.mojo` in Done, above.)
- **Named color palettes** — deliberately removed once already (see
  `color.mojo`'s history); belongs in an opt-in module if it ever
  comes back, not the core `Color` type.
- **Non-rectangular clipping** (clip to an arbitrary path/polygon, not
  just `push_clip`'s axis-aligned rect). Considered directly against
  the "solid dataviz foundation" question, not just left unexamined:
  a plot area -- the thing a clip actually exists to protect, keeping
  a line/bar/area series from drawing past its own axes -- is
  overwhelmingly rectangular in real charts; the primitives that
  natively *aren't* rectangular (`fill_arc`/`fill_ring_sector` for
  wedges/donuts) already bound their own drawing via their own angle/
  radius membership test and never needed a canvas-level clip to do
  it. A path-shaped clip is also a materially bigger feature than it
  sounds -- correctly antialiasing content *at* a clip's own curved
  boundary needs the same kind of per-pixel coverage math
  `fill_path_aa` just added, but applied as a *mask over subsequent
  drawing* rather than a one-shot fill, a real, separable feature with
  no concrete caller yet, not a small extension of the rect clip
  stack.
- **Canvas-to-canvas compositing/blitting** (drawing one `Canvas` onto
  another at an offset, e.g. compositing a pre-rendered legend swatch
  or background layer into a main chart). Deliberately *not* wrapped
  in a dedicated function: `Canvas` is `Copyable` and already exposes
  `get_pixel`/`set_pixel` publicly, so this is a direct few-line loop
  any caller (this module or `dataviz`) can already write today,
  nested `for`/`set_pixel(dst_x+x, dst_y+y, src.get_pixel(x,y))` --
  the same "don't build a wrapper for something already trivially
  expressible" reasoning `Transform2D`'s own docstring gives for not
  offering data-range convenience constructors.
- **Point-in-shape hit-testing as public API** (e.g. "is pixel (x,y)
  inside this bar" for hover/tooltip interactivity). `_point_in_
  polygon`/`_point_in_subpaths` (`primitives.mojo`/`path.mojo`) exist
  now as a side effect of `fill_polygon_aa`/`fill_path_aa`'s own
  coverage math and are trivially promotable to public names later,
  but nothing here promotes them today: real hit-testing in a chart
  is overwhelmingly a data-space question ("which data point is
  nearest the cursor," answered against the chart's own scales) that
  a `dataviz` layer already has everything it needs to answer without
  ever touching a rendered raster, not a canvas-level concern to
  design speculatively ahead of a concrete interactive use case.
- **Marker/symbol shape presets** (star, cross, diamond, triangle --
  common scatter-plot marker shapes beyond a plain circle). Considered
  and deliberately left out: every one of these is already directly
  expressible with existing primitives (`fill_polygon`/`fill_polygon_
  aa` for triangle/diamond/star, two thick `draw_line_aa` calls for a
  cross) with no new canvas-level math behind any of them, unlike
  every primitive actually built this session (each needed its own
  real geometry or coverage algorithm). A marker preset library is a
  convenience/vocabulary layer, and `dataviz` is what should own that
  vocabulary -- it's the one that knows which marker set an actual
  chart type wants, not `canvas` guessing ahead of time.
- **Selectable line joins/caps for hard-edged strokes** (miter/bevel/
  round, the way SVG/Canvas stroke APIs expose them). Not built:
  `draw_polyline_aa`/`draw_polygon_aa`'s per-sample "minimum distance
  across all segments" coverage test already produces a round-join-
  like result implicitly, with no join parameter needed, and thick
  hard-edged strokes with sharp/beveled corners haven't come up as a
  concrete dataviz need (thick stroked lines in charts are more often
  reached via `fill_path`/`fill_path_aa` -- a filled ribbon shape --
  than via a literal wide stroked polyline with a chosen join style).
  Real, isolable feature if a concrete need shows up later, not
  forgotten.
- **Sub-pixel-positioned axis-aligned rects** (`fill_rect` taking
  `Float64` bounds with edge antialiasing, instead of today's `Int`-
  only, always-pixel-aligned bounds). Considered specifically for
  tightly-packed bar charts/histograms, where many adjacent bars each
  independently rounding their edges to the nearest pixel can
  accumulate a visible width wobble across a wide chart. Left out for
  now: every other primitive in this package (including `Transform2D`
  itself, which rounds data-to-pixel positions down to a `Point`) is
  consistently integer-pixel-positioned, and introducing float bounds
  for exactly one primitive would be a real, isolated exception to
  that convention rather than a small addition -- worth building if a
  concrete chart surfaces visible wobble, not speculatively ahead of
  one.

## Explicitly out of scope for `canvas`

Anything chart-shaped — axes, scales, legends, series types, figure
layout. That's `dataviz`, and it depends on `canvas`, never the
reverse (see the repo root `README.md`).

## Foundation review: is this enough for `dataviz`?

Asked explicitly, not left implicit, at the end of a session spent
working through every "somewhat open" problem until none were left
that weren't either built or deliberately, documentedly deferred above
(see this file's own git history / the conversation this came out of
for the full trace): **yes.** What tipped this from "probably" to a
documented "yes" this round: `canvas` can now fill *any* shape it can
describe -- convex or not, self-intersecting or not, straight-edged or
curved, hard-edged or antialiased, flat or gradient-filled (linear or
radial), correctly hole-punched or union-merged depending on winding
rule -- which is the actual precondition for a `dataviz` layer to
render bar/line/area/scatter/pie/donut charts, stacked and overlapping
regions, and gradient-shaded fills without ever needing to drop back
down into raw pixel manipulation itself. Text can be measured,
aligned, rotated, and multi-line-laid-out, and now its rotated
footprint can be *known before drawing* (`measure_text_block`) --
exactly what axis-tick-label placement needs. Every deferred item
above was considered and rejected for a concrete reason (usually:
already directly expressible with what exists, or genuinely belongs
one layer up in `dataviz` itself, which knows its own chart
vocabulary), not because it ran out of turn budget -- if `dataviz`
work surfaces a real need for one of them, that's the signal to build
it then, not a sign this review missed something.

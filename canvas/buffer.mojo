"""The pixel raster buffer at the core of the canvas package."""

# Bytes per pixel: R, G, B, A, straight (non-premultiplied) alpha.
#
# The alpha channel is what lets a canvas have a transparent
# background -- `Canvas(w, h, Color(0, 0, 0, 0))` -- and therefore what
# lets `write_png` emit a PNG with real transparency and `read_png`
# keep the alpha of a file that has one.
#
# Straight rather than premultiplied, so `get_pixel` returns the color
# a caller would recognize: premultiplying is the better representation
# for repeated compositing, but it makes every read lossy at low alpha
# and would change what every existing caller of `get_pixel` sees.
comptime BYTES_PER_PIXEL = 4

from std.math import ceil, floor
from std.sys import size_of
from std.runtime.asyncrt import TaskGroup

from canvas.blend import BlendMode, _blend_pixel, _blend_span
from canvas.color import (
    Color,
    ColorSpace,
    _Transfer,
    _div255,
    _DIV255_MUL,
    _DIV255_SHIFT,
)
from canvas.gradient import LinearGradient
from canvas.machine import l3_slice_bytes
from canvas.vector.draw_target import DrawTarget
from canvas.workers import _bands_for, _worker_limit
from canvas.fill_rule import FillRule
from canvas.aa_crossing import _EdgeTable
from canvas.batch import _render_batch, _replay_supersampled
from canvas.resize import downsample
from canvas.geometry import FPoint, Matrix2D, _mapped_bounds, _mapped_rect
from canvas.path import (
    Path,
    PathCommand,
    _CoverageMask,
    fill_path_aa,
    stroke_path_aa,
    _path_coverage_mask,
    _rect_path,
    _through,
)
from canvas.shapes.lines import draw_line_aa, LineCap, LineJoin
from canvas.shapes.arcs import fill_arc_aa, fill_ring_sector_aa
from canvas.shapes.circles import draw_circle_aa, fill_circle_aa
from canvas.shapes.ellipses import draw_ellipse_aa, fill_ellipse_aa
from canvas.shapes.rects import fill_rect, fill_rect_gradient
from canvas.compose import draw_canvas, draw_image


struct _ClipRect(ImplicitlyCopyable, Movable):
    """A clip rectangle, private to this module: an implementation
    detail of Canvas's clip stack, unrelated to any public type.
    """

    var x: Int
    var y: Int
    var width: Int
    var height: Int
    # For a rectangle push_clip turned into a clip path (a rotated or
    # skewed transform): how many clip masks were pushed before it, so
    # pop_clip can pop the mask along with this entry. -1 for a plain
    # rectangle.
    var mask_depth: Int

    def __init__(
        out self, x: Int, y: Int, width: Int, height: Int, mask_depth: Int = -1
    ):
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.mask_depth = mask_depth


struct _CanvasState(ImplicitlyCopyable, Movable):
    """What `Canvas.save` records and `Canvas.restore` puts back: the
    transform, the blend mode, the color space, and how deep the two
    clip stacks were.
    """

    var transform: Matrix2D
    var transformed: Bool
    var blend: BlendMode
    var space: ColorSpace
    var clip_depth: Int
    var mask_depth: Int

    def __init__(
        out self,
        transform: Matrix2D,
        transformed: Bool,
        blend: BlendMode,
        space: ColorSpace,
        clip_depth: Int,
        mask_depth: Int,
    ):
        self.transform = transform
        self.transformed = transformed
        self.blend = blend
        self.space = space
        self.clip_depth = clip_depth
        self.mask_depth = mask_depth


def _pack_rgba(color: Color) -> UInt32:
    """`color`'s four bytes as the one 32-bit word a pixel occupies in
    memory, so a solid fill is one store per pixel rather than four.

    Little-endian, r in the low byte, which is every platform this
    package builds for (linux-64, osx-arm64); a big-endian target would
    need the bytes swapped.
    """
    return (
        UInt32(color.r)
        | (UInt32(color.g) << 8)
        | (UInt32(color.b) << 16)
        | (UInt32(color.a) << 24)
    )


# A whole-buffer solid fill is one store per pixel and no reads, so its
# only limit is how fast stores retire -- and that limit changes shape
# at one L3 slice.
#
# This machine's 128 MB of L3 is eight separate 16 MB slices, one per
# CCX (see benchmarks/roofline.md). A buffer inside one slice is
# written at L3 speed by the single core that owns it -- 8 MB clears at
# 74 GB/s -- and splitting it across bands only moves those lines to
# other CCXs' slices over Infinity Fabric, which measured *slower* than
# staying serial at every size below the slice. Past the slice the
# writes go to DRAM either way, one core cannot keep enough of them in
# flight to fill the memory channels (16 MB clears at 16.5 GB/s), and
# bands are worth 2.2x to 3.7x.
#
# So the threshold is one L3 slice, not a work count -- and it is that
# machine's slice, which is why it is asked of the machine the process
# is on rather than written here (`canvas.machine`, #399). The sweep
# that produced the rule is in the #364 PR.
def _min_parallel_clear() -> Int:
    """Bytes from which banding a solid fill pays: one L3 slice."""
    return l3_slice_bytes()


def _clear_bytes_per_band() -> Int:
    """Half a slice per band, so each band's share still fits the slice
    of whichever CCX runs it with room to spare. Two bands measured
    fastest at 16 MB (3.66x) and the count matters far less than the
    threshold does -- every count from 2 to 16 beat serial above it.
    """
    return l3_slice_bytes() // 2


# A cap for buffers large enough that the ratio would keep growing
# after the memory channels are already saturated.
comptime _MAX_CLEAR_BANDS = 16


def _store_packed_span(
    mut pixels: List[UInt8], start: Int, count: Int, packed: UInt32
):
    """Write `packed` to `count` consecutive pixels from pixel index
    `start`, eight at a time through vector stores and one at a time for
    the remainder. `Canvas._store_packed` is the method form of this,
    used where the fill is a row of an active drawing operation; this
    free function is what the band tasks below call, since they hold the
    buffer rather than the canvas.
    """
    comptime LANES = 8
    var p32 = pixels.unsafe_ptr().unsafe_bitcast[UInt32]()
    var vec = SIMD[DType.uint32, LANES](packed)
    var idx = start
    var end = start + count
    while idx + LANES <= end:
        p32.unsafe_offset(idx).unsafe_store(vec)
        idx += LANES
    while idx < end:
        p32[unsafe_offset=idx] = packed
        idx += 1


async def _store_packed_span_async(
    mut pixels: List[UInt8], start: Int, count: Int, packed: UInt32
):
    _store_packed_span(pixels, start, count, packed)


def _clear_bands(count: Int, cap: Int) -> Int:
    """How many bands to split a `count`-pixel solid fill over: 1 while
    the buffer fits in one L3 slice, where a band would cost more than
    it saves, otherwise one band per `_CLEAR_BYTES_PER_BAND` bounded by
    `_MAX_CLEAR_BANDS`, the caller's worker cap and the runtime's count.

    Args:
        count: Pixels to fill.
        cap: The caller's worker cap, 0 or less for no cap of its own.

    Returns:
        The band count, at least 1.
    """
    var total = count * BYTES_PER_PIXEL
    if total < _min_parallel_clear():
        return 1
    # The floor of two applies before the cap, not after: past the
    # threshold even the smallest split is worth making, but a caller
    # that asked for one worker gets one band.
    var bands = min(total // _clear_bytes_per_band(), _MAX_CLEAR_BANDS)
    return max(min(max(bands, 2), _worker_limit(cap)), 1)


def _clear_packed(
    mut pixels: List[UInt8], count: Int, packed: UInt32, cap: Int
):
    """Fill `count` pixels from index 0 with `packed`, across bands when
    the buffer is large enough to be worth it.

    Only whole-buffer fills reach this -- `Canvas.__init__`'s initial
    color and an unclipped opaque `Canvas.fill`. A per-row fill inside a
    drawing operation calls `Canvas._store_packed` directly, since those
    already run inside band tasks of their own and nesting task groups
    would oversubscribe the runtime.

    Args:
        pixels: The buffer to fill, at least `count` pixels long.
        count: Pixels to fill.
        packed: The packed color, from `_pack_rgba`.
        cap: The caller's worker cap, from `Canvas.max_workers`.
    """
    if count <= 0:
        return
    var bands = _clear_bands(count, cap)
    if bands == 1:
        _store_packed_span(pixels, 0, count, packed)
        return
    var per = (count + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var start = b * per
        var n = min(per, count - start)
        if n <= 0:
            continue
        tg.create_task(_store_packed_span_async(pixels, start, n, packed))
    tg.wait()


async def _fill_region_band_async(
    mut canvas: Canvas, rx: Int, ry: Int, rw: Int, rh: Int, color: Color
):
    """One band of rows of `Canvas._fill_region_top`. Bands write
    disjoint rows and read nothing the others write.
    """
    canvas._fill_region(rx, ry, rw, rh, color)


# What a `_BatchOp` holds: edges to rasterize, a closed-form disk or
# ellipse, a solid rectangle, or a stroke or path still to be built
# into edges when the batch is drawn.
comptime _OP_EDGES = 0
comptime _OP_DISK = 1
comptime _OP_ELLIPSE = 2
comptime _OP_RECT = 3
comptime _OP_STROKE = 4
comptime _OP_PATH = 5
# A cached glyph's coverage mask, recorded so that text inside a batch
# replays per band like every other op rather than forcing a flush
# (#391). The counts live in the batch's own `glyph_counts`.
comptime _OP_GLYPH = 6


struct _BatchOp(Copyable, ImplicitlyCopyable, Movable):
    """One primitive recorded between `Canvas.begin_batch` and
    `end_batch`: its paint, the canvas rows it can touch (which a band
    reads to skip it), and either its closed-form parameters or
    indices into the batch's side lists (`_Batch`) for its geometry.
    Scalars only, so recording an op is an append and a batch of
    thousands owns a few allocations rather than one per op --
    allocation across many threads was most of what a batch of tiny
    shapes cost when each op held its own lists.

    An op is recorded as early in its primitive's pipeline as the
    canvas state allows, so that what follows can run in parallel when
    the batch is drawn: a stroke as its device-space points and stroke
    style (`_OP_STROKE`), a path fill as the path (`_OP_PATH`), both
    turned into edges by `canvas.batch` before the band pass; a
    polygon fill as the edges it already built (`_OP_EDGES`, exact
    area or the sampled sweep); a disk or ellipse small enough for the
    closed form; a rectangle already intersected with the clip. Each
    is what the primitive's raster stage would have consumed at the
    call, under the transform, clip, blend mode and color space then
    in force, so rendering it later, on any band, writes the pixels
    the call would have.
    """

    var kind: Int
    var color: Color
    var exact: Bool
    var fill_rule: FillRule
    var supersample: Int
    # An edge range's unpadded bounds; a rectangle's x, y and the
    # exclusive x + width, y + height; a disk's or ellipse's box.
    var min_x: Int
    var min_y: Int
    var max_x: Int
    var max_y: Int
    # The closed forms.
    var cx: Float64
    var cy: Float64
    var rx: Float64
    var ry: Float64
    # `_OP_EDGES`: edges [first_edge, last_edge) of the batch's table
    # `table`. A sampled op has a table of its own, whole.
    var table: Int
    var first_edge: Int
    var last_edge: Int
    # `_OP_STROKE`: `point_count` of the batch's points from
    # `first_point`, `dash_count` of its dashes from `first_dash`, and
    # the style, in the space `matrix` maps to the device.
    var first_point: Int
    var point_count: Int
    var closed: Bool
    var half_width: Float64
    var first_dash: Int
    var dash_count: Int
    var dash_offset: Float64
    var cap: LineCap
    var join: LineJoin
    var miter_limit: Float64
    var matrix: Matrix2D
    # `_OP_PATH`: the batch's path `path`, its flattening, and about
    # how many vertices it flattens to.
    var first_command: Int
    var command_count: Int
    var curve_steps: Int
    var path_work: Int
    # Rows [first_row, last_row) the op can write, in canvas rows;
    # empty until a stroke or path is built.
    var first_row: Int
    var last_row: Int

    def __init__(out self, kind: Int, color: Color):
        """An op of `kind` with nothing else set; the builders below
        fill in what the kind needs."""
        self.kind = kind
        self.color = color
        self.exact = True
        self.fill_rule = FillRule.NONZERO
        self.supersample = 0
        self.min_x = 0
        self.min_y = 0
        self.max_x = 0
        self.max_y = 0
        self.cx = 0.0
        self.cy = 0.0
        self.rx = 0.0
        self.ry = 0.0
        self.table = 0
        self.first_edge = 0
        self.last_edge = 0
        self.first_point = 0
        self.point_count = 0
        self.closed = False
        self.half_width = 0.0
        self.first_dash = 0
        self.dash_count = 0
        self.dash_offset = 0.0
        self.cap = LineCap.ROUND
        self.join = LineJoin.ROUND
        self.miter_limit = 4.0
        self.matrix = Matrix2D.identity()
        self.first_command = 0
        self.command_count = 0
        self.curve_steps = 0
        self.path_work = 0
        self.first_row = 0
        self.last_row = 0

    def set_edges(
        mut self,
        table: Int,
        first_edge: Int,
        last_edge: Int,
        min_x: Int,
        min_y: Int,
        max_x: Int,
        max_y: Int,
        exact: Bool,
    ):
        """Make the op an `_OP_EDGES` over that range of that table,
        with the unpadded bounds the sweep pads: the rows are the ones
        `_area_edges_aa` and the sampled sweep visit. An empty range
        leaves the op touching no row.
        """
        self.kind = _OP_EDGES
        self.exact = exact
        self.table = table
        self.first_edge = first_edge
        self.last_edge = last_edge
        if last_edge <= first_edge:
            self.first_row = 0
            self.last_row = 0
            return
        self.min_x = min_x
        self.min_y = min_y
        self.max_x = max_x
        self.max_y = max_y
        self.first_row = min_y - 1
        self.last_row = max_y + 2

    def geometry_work(self) -> Int:
        """How much building the op's edges will cost, in vertices:
        what the batch weighs against splitting the build across
        tasks. Zero for an op with nothing to build.
        """
        if self.kind == _OP_STROKE:
            return self.point_count
        if self.kind == _OP_PATH:
            return self.path_work
        return 0

    def work(self) -> Int:
        """About how many pixels rendering the op visits: its box.
        What the batch weighs against the parallel threshold.
        """
        var rows = self.last_row - self.first_row
        var cols = self.max_x - self.min_x + 3
        if rows <= 0 or cols <= 0:
            return 0
        return rows * cols


struct _Batch(Copyable, Movable):
    """Everything recorded since the outermost `Canvas.begin_batch`:
    the ops, and the side lists their indices point into -- the
    strokes' points and dash patterns, the paths, and the edge tables.
    Table 0 gathers the edges recorded ready-made (polygon fills and
    the strokes that reach `_rasterize_stroke` already built); a
    sampled op gets a table of its own, since the sampled sweep sorts
    and seeds a whole table; and drawing the batch adds one table per
    build task. `canvas.batch` renders one of these.
    """

    var ops: List[_BatchOp]
    var points: List[FPoint]
    var dashes: List[Float64]
    # Every recorded path's commands, end to end, each op holding its
    # own range. One list of commands rather than a `Path` per op, so
    # a batch of thousands of markers costs a few amortized growths
    # instead of an allocation and a free each (#390), which is what
    # #387 did for edges and points.
    var commands: List[PathCommand]
    # Every recorded glyph's coverage bytes, end to end, each op
    # holding its own range (#391).
    var glyph_counts: List[UInt8]
    var tables: List[_EdgeTable]

    def __init__(out self):
        self.ops = List[_BatchOp]()
        self.points = List[FPoint]()
        self.dashes = List[Float64]()
        self.commands = List[PathCommand]()
        self.glyph_counts = List[UInt8]()
        self.tables = List[_EdgeTable]()
        self.tables.append(_EdgeTable())

    def reserve_like(mut self, other: _Batch):
        """Room for a batch the size of `other`: the next one usually
        is."""
        self.ops.reserve(len(other.ops))
        self.points.reserve(len(other.points))
        self.commands.reserve(len(other.commands))
        self.glyph_counts.reserve(len(other.glyph_counts))

    def record_edges(
        mut self,
        edges: _EdgeTable,
        min_x: Int,
        min_y: Int,
        max_x: Int,
        max_y: Int,
        color: Color,
        fill_rule: FillRule,
        supersample: Int,
        exact: Bool,
    ):
        """Edges already built, appended to table 0 when they
        rasterize by exact area and copied into a table of their own
        when they take the sampled sweep (already top-sorted then)."""
        var op = _BatchOp(_OP_EDGES, color)
        op.fill_rule = fill_rule
        op.supersample = supersample
        var table = 0
        var first = 0
        var last = len(edges.y_lo)
        if exact:
            first = len(self.tables[0].y_lo)
            self.tables[0].extend(edges)
            last = len(self.tables[0].y_lo)
        else:
            self.tables.append(edges.copy())
            table = len(self.tables) - 1
        op.set_edges(table, first, last, min_x, min_y, max_x, max_y, exact)
        self.ops.append(op)

    def record_stroke(
        mut self,
        points: List[FPoint],
        closed: Bool,
        half_width: Float64,
        cap: LineCap,
        dashes: List[Float64],
        dash_offset: Float64,
        join: LineJoin,
        miter_limit: Float64,
        matrix: Matrix2D,
        supersample: Int,
        color: Color,
    ):
        """A stroke as `_stroke_edges` takes it, to be built when the
        batch is drawn."""
        var op = _BatchOp(_OP_STROKE, color)
        op.first_point = len(self.points)
        op.point_count = len(points)
        for i in range(len(points)):
            self.points.append(points[i])
        op.closed = closed
        op.half_width = half_width
        op.cap = cap
        op.first_dash = len(self.dashes)
        op.dash_count = len(dashes)
        for i in range(len(dashes)):
            self.dashes.append(dashes[i])
        op.dash_offset = dash_offset
        op.join = join
        op.miter_limit = miter_limit
        op.matrix = matrix
        op.supersample = supersample
        self.ops.append(op)

    def record_path(
        mut self,
        path: Path,
        fill_rule: FillRule,
        supersample: Int,
        curve_steps: Int,
        color: Color,
    ):
        """A device-space path to fill, flattened and built when the
        batch is drawn. The commands are appended to the batch's own
        list and the op keeps their range, so recording a path is an
        extend rather than an allocation (#390)."""
        var op = _BatchOp(_OP_PATH, color)
        op.first_command = len(self.commands)
        op.command_count = len(path.commands)
        # Appended through the source's pointer: `extend` would take a
        # copy of the whole list first, which is the allocation this
        # change exists to remove. No `reserve` per record -- reserving
        # to an exact length every time grows the list by a few
        # commands at a time instead of geometrically, which made the
        # record slower than the copy it replaced.
        var cp = path.commands.unsafe_ptr()
        for k in range(op.command_count):
            self.commands.append(cp[unsafe_offset=k])
        op.path_work = op.command_count * 4
        op.fill_rule = fill_rule
        op.supersample = supersample
        op.curve_steps = curve_steps
        self.ops.append(op)


def _glyph_op(
    first: Int,
    count: Int,
    width: Int,
    height: Int,
    left: Int,
    top: Int,
    total_samples: Int,
    color: Color,
) -> _BatchOp:
    """A cached glyph's coverage mask placed at (left, top): `count`
    bytes of the batch's `glyph_counts` from `first`, `width` wide.
    """
    var op = _BatchOp(_OP_GLYPH, color)
    op.first_command = first
    op.command_count = count
    op.min_x = left
    op.min_y = top
    op.max_x = left + width
    op.max_y = top + height
    op.supersample = total_samples
    op.first_row = top
    op.last_row = top + height
    return op


def _disk_op(
    cx: Float64, cy: Float64, radius: Float64, color: Color
) -> _BatchOp:
    """A closed-form disk; its rows are the ones `_fill_circle_aa_rows`
    visits."""
    var op = _BatchOp(_OP_DISK, color)
    op.cx = cx
    op.cy = cy
    op.rx = radius
    op.ry = radius
    op.min_x = Int(floor(cx - radius)) - 1
    op.max_x = Int(ceil(cx + radius)) + 2
    op.first_row = Int(floor(cy - radius)) - 1
    op.last_row = Int(ceil(cy + radius)) + 2
    return op


def _ellipse_op(
    cx: Float64, cy: Float64, rx: Float64, ry: Float64, color: Color
) -> _BatchOp:
    """A closed-form ellipse; its rows are the ones
    `_fill_ellipse_aa_rows` visits."""
    var op = _BatchOp(_OP_ELLIPSE, color)
    op.cx = cx
    op.cy = cy
    op.rx = rx
    op.ry = ry
    op.min_x = Int(floor(cx - rx)) - 1
    op.max_x = Int(ceil(cx + rx)) + 2
    op.first_row = Int(floor(cy - ry)) - 1
    op.last_row = Int(ceil(cy + ry)) + 2
    return op


def _rect_op(x: Int, y: Int, width: Int, height: Int, color: Color) -> _BatchOp:
    """A solid rectangle already intersected with the canvas and the
    rectangle clip, as `_fill_region` takes it."""
    var op = _BatchOp(_OP_RECT, color)
    op.min_x = x
    op.min_y = y
    op.max_x = x + width
    op.max_y = y + height
    op.first_row = y
    op.last_row = y + height
    return op


def _intersect_clip(a: _ClipRect, b: _ClipRect) -> _ClipRect:
    """The overlapping region of two clip rects. This is what keeps a
    nested clip from escaping an ancestor's: a rect extending past the
    current clip is cut down to the overlap. Disjoint rects give a
    zero-size result, clamped rather than negative, which in_clip's
    half-open check reads as "nothing is inside this clip."
    """
    var left = max(a.x, b.x)
    var top = max(a.y, b.y)
    var right = min(a.x + a.width, b.x + b.width)
    var bottom = min(a.y + a.height, b.y + b.height)
    return _ClipRect(left, top, max(0, right - left), max(0, bottom - top))


struct Canvas(Copyable, DrawTarget, Movable):
    """A width x height RGBA raster buffer, row-major, 4 bytes per pixel.

    Alpha is stored per-pixel and straight, not premultiplied (see
    BYTES_PER_PIXEL), so a canvas can carry a transparent background and
    `write_png` can emit real transparency.

    There is no `draw_text` method, since `DrawTarget` has none. Call
    `canvas.text.render.draw_text(canvas, ...)`.
    """

    var width: Int
    var height: Int
    var pixels: List[UInt8]
    # The size the coordinate space has, which is the buffer's size
    # except inside a supersampled region: there the caller draws in a
    # space `factor` times larger than the buffer that will hold the
    # result, and nothing is drawn until `end_supersampled` replays it
    # a band at a time (#391).
    var _virtual_width: Int
    var _virtual_height: Int
    # The supersample factor of an open region, 0 when none is open,
    # and what each of its bands starts from.
    var _supersample: Int
    var _supersample_bg: Color
    # A region gives up and holds the enlarged buffer when something
    # inside it cannot be recorded -- a bulk marker call, a clip, a
    # gradient, anything that draws what is pending and then itself.
    # Those draw in the enlarged space, which the output buffer cannot
    # address, so the canvas becomes the enlarged one until
    # `end_supersampled` downsamples it back (#409). These hold what
    # it was before.
    var _region_materialized: Bool
    var _region_pixels: List[UInt8]
    var _region_width: Int
    var _region_height: Int
    # Which row of a larger virtual canvas this buffer's row 0 is.
    # Zero for every ordinary canvas; a supersampled band sets it so
    # that geometry recorded in the virtual canvas's coordinates draws
    # into a buffer holding only that band's rows (#391). Only this
    # struct's addressing honours it: code that walks `pixels` itself
    # sees a plain buffer of `height` rows, which is what `downsample`
    # and the encoders want.
    var _row_origin: Int
    var _clip_stack: List[_ClipRect]
    # Coverage masks pushed by push_clip_path, innermost last. Each is
    # width*height bytes: 255 fully inside the clip, 0 fully outside,
    # and the values between are what make a clip path's own edge
    # anti-aliased rather than a staircase.
    #
    # Each mask is already intersected with its parent, so only the top
    # mask must be consulted.
    var clip_masks: List[List[UInt8]]
    # len(clip_masks), mirrored as a plain Int. `set_pixel` tests this
    # once per pixel drawn anywhere in the package, and a bare field
    # load beats reaching into a List-of-Lists for its length.
    var _clip_mask_count: Int
    # Mojo passes a Canvas by reference only when the struct exceeds
    # 256 bytes. Keep this padding and the size check in `__init__` so
    # pixel-writing calls do not copy the Canvas value.
    var _layout_pad: InlineArray[UInt8, 176]
    # The current transform (see `save`), and whether it is anything
    # but the identity. Every drawing call tests the flag once, so it
    # is a field rather than six comparisons on the matrix.
    var _transform: Matrix2D
    var _transformed: Bool
    # The current blend mode (see `set_blend_mode`). SOURCE_OVER until
    # a caller sets otherwise, and every pixel write tests it.
    var _blend: BlendMode
    # The space source-over blends mix in (see `set_color_space`), and
    # the transfer tables, built when it first becomes LINEAR.
    var _space: ColorSpace
    # A per-render ceiling on worker threads, 0 for the runtime's own
    # count. Not part of `save`/`restore`: it is a resource policy for
    # the whole render, not drawing state a local frame should undo.
    var _max_workers: Int
    var _transfer: _Transfer
    var _saved: List[_CanvasState]
    # Primitives recorded since the outermost `begin_batch`, and how
    # many `begin_batch` calls are open; see `begin_batch`.
    var _batch: _Batch
    var _batch_depth: Int

    def __init__(
        out self, width: Int, height: Int, fill: Color = Color(255, 255, 255)
    ) raises:
        """Allocate a `width x height` canvas, every pixel set to `fill`.

        A zero width or height gives an empty canvas and is allowed; a
        negative one raises, since the allocation below sizes itself
        from `width * height * 4` and a negative length is not a
        buffer this type can represent.

        Args:
            width: Canvas width in pixels.
            height: Canvas height in pixels.
            fill: Initial color for every pixel.

        Raises:
            Error: `width` or `height` is negative.
        """
        if width < 0 or height < 0:
            raise Error(
                "Canvas(width, height, fill): dimensions must be"
                " non-negative (got "
                + String(width)
                + "x"
                + String(height)
                + ")"
            )
        self.width = width
        self.height = height
        self._row_origin = 0
        self._virtual_width = width
        self._virtual_height = height
        self._supersample = 0
        self._supersample_bg = Color(255, 255, 255)
        self._region_materialized = False
        self._region_pixels = List[UInt8]()
        self._region_width = 0
        self._region_height = 0

        # One 32-bit store per pixel of the packed color (see
        # _pack_rgba and _store_packed). The buffer's base is
        # allocator-aligned and every pixel sits at a multiple of four
        # bytes, so the 32-bit stores are aligned; the vector stores
        # make no alignment assumption.
        var total = width * height * BYTES_PER_PIXEL
        # The fill below writes every channel of every pixel, including
        # its scalar tail, before any of them can be read, so a zeroing
        # allocation here would be a second full pass over the buffer
        # that changes nothing. It runs on a local rather than on
        # `self.pixels` because the band tasks borrow the buffer and
        # `self` is not a whole value yet -- the fields below are unset.
        var buf = List[UInt8](unsafe_uninit_length=total)
        _clear_packed(buf, width * height, _pack_rgba(fill), 0)
        self.pixels = buf^
        self._clip_stack = List[_ClipRect]()
        self.clip_masks = List[List[UInt8]]()
        self._clip_mask_count = 0
        self._layout_pad = InlineArray[UInt8, 176](fill=0)
        comptime assert (
            size_of[Canvas]() > 256
        ), "Canvas must stay over 256 bytes -- see _layout_pad"
        self._transform = Matrix2D.identity()
        self._transformed = False
        self._blend = BlendMode.SOURCE_OVER
        self._space = ColorSpace.SRGB
        self._max_workers = 0
        self._transfer = _Transfer()
        self._saved = List[_CanvasState]()
        self._batch = _Batch()
        self._batch_depth = 0

    def __init__(
        out self, width: Int, height: Int, var pixels: List[UInt8]
    ) raises:
        """Wrap an already-built RGBA pixel buffer, skipping the
        solid-fill loop the (width, height, fill) constructor pays for.
        For a caller about to write every pixel itself, such as
        `downsample()` in canvas/resize.mojo.

        Raises unless `pixels` is exactly width * height * 4 bytes (RGBA,
        row-major, the layout get_pixel/set_pixel assume); a wrong-sized
        buffer would corrupt every later index.

        Args:
            width: Canvas width in pixels.
            height: Canvas height in pixels.
            pixels: Row-major RGBA bytes, exactly width * height * 4
                long.

        Raises:
            Error: `pixels`' length isn't width * height * 4.
        """
        if len(pixels) != width * height * BYTES_PER_PIXEL:
            raise Error(
                "Canvas(width, height, pixels): pixels must be exactly"
                " width * height * 4 bytes (got "
                + String(len(pixels))
                + " for a "
                + String(width)
                + "x"
                + String(height)
                + " canvas)"
            )
        self.width = width
        self.height = height
        self._row_origin = 0
        self._virtual_width = width
        self._virtual_height = height
        self._supersample = 0
        self._supersample_bg = Color(255, 255, 255)
        self._region_materialized = False
        self._region_pixels = List[UInt8]()
        self._region_width = 0
        self._region_height = 0
        self.pixels = pixels^
        self._clip_stack = List[_ClipRect]()
        self.clip_masks = List[List[UInt8]]()
        self._clip_mask_count = 0
        self._layout_pad = InlineArray[UInt8, 176](fill=0)
        comptime assert (
            size_of[Canvas]() > 256
        ), "Canvas must stay over 256 bytes -- see _layout_pad"
        self._transform = Matrix2D.identity()
        self._transformed = False
        self._blend = BlendMode.SOURCE_OVER
        self._space = ColorSpace.SRGB
        self._max_workers = 0
        self._transfer = _Transfer()
        self._saved = List[_CanvasState]()
        self._batch = _Batch()
        self._batch_depth = 0

    def save(mut self):
        """Push the current transform, blend mode and clip state, for
        `restore` to put back. The pair works as Cairo's
        `cairo_save`/`cairo_restore` and the HTML5 canvas's
        `save`/`restore` do: whatever `translate`, `rotate`, `scale`,
        `transform`, `set_transform`, `set_blend_mode`,
        `set_color_space`, `push_clip` or `push_clip_path` does between
        the two is undone by `restore`,
        so a caller can set up a local frame for one part of a drawing
        and leave the canvas as it found it.
        """
        self._saved.append(
            _CanvasState(
                self._transform,
                self._transformed,
                self._blend,
                self._space,
                len(self._clip_stack),
                self._clip_mask_count,
            )
        )

    def restore(mut self):
        """Pop the state `save` pushed: the transform and blend mode go
        back to what they were, and every clip pushed since --
        rectangle or path -- is popped. A no-op with nothing saved,
        matching `pop_clip`.
        """
        self._flush_batch()
        if len(self._saved) == 0:
            return
        var state = self._saved.pop()
        while self._clip_mask_count > state.mask_depth:
            self.pop_clip_path()
        while len(self._clip_stack) > state.clip_depth:
            _ = self._clip_stack.pop()
        self._transform = state.transform
        self._transformed = state.transformed
        self._blend = state.blend
        self._space = state.space

    def translate(mut self, tx: Float64, ty: Float64):
        """Shift the origin subsequent drawing is measured from by
        (tx, ty), in the current user space: after `scale(2.0, 2.0)`,
        `translate(10.0, 0.0)` moves it 20 pixels.

        Args:
            tx: Horizontal shift.
            ty: Vertical shift.
        """
        self.transform(Matrix2D.translation(tx, ty))

    def rotate(mut self, angle: Float64):
        """Turn subsequent drawing by `angle` radians about the current
        origin. Positive turns +x toward +y, clockwise on screen.

        Args:
            angle: Radians.
        """
        self.transform(Matrix2D.rotation(angle))

    def scale(mut self, sx: Float64, sy: Float64):
        """Scale subsequent drawing about the current origin, each axis
        by its own factor. A negative factor mirrors that axis --
        `scale(1.0, -1.0)` after a `translate` to the bottom of a plot
        area gives a y-up coordinate system.

        Args:
            sx: Horizontal factor.
            sy: Vertical factor.
        """
        self.transform(Matrix2D.scaling(sx, sy))

    def transform(mut self, matrix: Matrix2D):
        """Compose `matrix` into the current transform, applied to
        coordinates before everything already in place -- the same
        order `translate`/`rotate`/`scale` compose in, so a
        `Matrix2D(Transform2D(...))` slots in like any of them.

        Args:
            matrix: The map to apply first.
        """
        self._set_transform(matrix.then(self._transform))

    def set_transform(mut self, matrix: Matrix2D):
        """Replace the current transform outright.

        Args:
            matrix: The new map from user space to device pixels.
        """
        self._set_transform(matrix)

    def reset_transform(mut self):
        """Back to the identity: coordinates are device pixels again.
        Clips are left alone; `restore` undoes both.
        """
        self._set_transform(Matrix2D.identity())

    def current_transform(self) -> Matrix2D:
        """The map every drawing call currently applies.

        Returns:
            The current transform; the identity if none is set.
        """
        return self._transform

    def has_transform(self) -> Bool:
        """Whether the current transform is anything but the identity.
        Each drawing primitive checks this once and, when it is false,
        runs exactly as it did before transforms existed.

        Returns:
            True if drawing is being mapped.
        """
        return self._transformed

    def _set_transform(mut self, matrix: Matrix2D):
        self._transform = matrix
        self._transformed = not matrix.is_identity()

    def _take_transform(mut self) -> Matrix2D:
        """The current transform, with the canvas left at the identity:
        for a primitive that has mapped its own coordinates to device
        space and is about to call a drawing function that would
        otherwise map them again. Put it back with `_set_transform`.
        """
        var m = self._transform
        self._set_transform(Matrix2D.identity())
        return m

    def set_blend_mode(mut self, mode: BlendMode):
        """Set how every later drawing call combines with the pixels
        already there -- the equivalent of Cairo's
        `cairo_set_operator` and the HTML5 canvas's
        `globalCompositeOperation`.

        `save`/`restore` carry the mode with the rest of the canvas
        state. See canvas/blend.mojo for each mode's formula and for
        the three limits on where a mode applies.

        Args:
            mode: The blend mode later calls use.
        """
        self._flush_batch()
        self._blend = mode

    def blend_mode(self) -> BlendMode:
        """The blend mode later drawing calls will use.

        Returns:
            The current mode, `BlendMode.SOURCE_OVER` until
            `set_blend_mode` says otherwise.
        """
        return self._blend

    def set_max_workers(mut self, workers: Int):
        """Cap how many worker threads a banded pass on this canvas may
        use. 0, the default, leaves it to the runtime.

        An application rendering several canvases at once otherwise
        has each one fan out to every thread, which oversubscribes the
        machine rather than sharing it. This is a per-render ceiling,
        not a budget across renders: two canvases each capped at 8 may
        use 16 threads between them.

        Passing a number above what the runtime offers is the same as
        passing 0. The cap changes how work is divided, never what is
        drawn: every banded pass writes disjoint rows, so a render is
        identical at any worker count.

        `save`/`restore` do not carry it, unlike the transform, the
        blend mode and the color space. It is a resource policy for the
        whole render rather than drawing state a local frame should be
        able to undo.

        Args:
            workers: Maximum worker threads, 0 for the runtime's count.
        """
        self._max_workers = workers if workers > 0 else 0

    def max_workers(self) -> Int:
        """The worker cap `set_max_workers` set.

        Returns:
            The cap, or 0 when there is none and the runtime's count
            applies.
        """
        return self._max_workers

    def set_color_space(mut self, space: ColorSpace):
        """Set the space later source-over blends mix in: SRGB, the
        default, blends the stored channel bytes directly; LINEAR
        converts them to linear light, blends, and converts back (see
        `ColorSpace`). Every anti-aliased edge, translucent fill and
        composite drawn from here on takes it, since they all reach the
        pixels through the same source-over. The Porter-Duff operators
        and the blend modes (`set_blend_mode`) stay in sRGB either way.

        `save`/`restore` carry the space, as they do the blend mode.

        Args:
            space: The color space later blends use.
        """
        self._flush_batch()
        self._space = space
        if space.is_linear():
            self._transfer.build()

    def color_space(self) -> ColorSpace:
        """The space source-over blends mix in now.

        Returns:
            The current space, `ColorSpace.SRGB` until
            `set_color_space` says otherwise.
        """
        return self._space

    def begin_batch(mut self):
        """Start deferring anti-aliased shapes so that `end_batch` can
        draw them all in one parallel pass, in the order they were
        called: what a chart's gridlines, ticks and markers want, where
        each shape is far too small to split across cores on its own
        and drawing them one call at a time runs on one core.

        Deferred: `fill_path_aa`, `stroke_path_aa`, `fill_polygon_aa`,
        `draw_line_aa`, `draw_polyline_aa`, `draw_polygon_aa`,
        `fill_circle_aa`, `fill_ellipse_aa`, `fill_arc_aa`,
        `fill_ring_sector_aa`, `draw_circle_aa`, `draw_ellipse_aa`,
        `draw_arc_aa`, and the solid `fill_rect`. Each is recorded at
        the call, under the transform, clip, blend mode and color
        space in force then -- a stroke as its points and style, a
        path as the path, so that `end_batch` can build their outlines
        and edge tables in parallel before it rasterizes -- and
        rendered by the same row-restricted code its batched relatives
        use, so the pixels are exactly the ones drawing it at once
        would have written.

        Everything else -- text, gradient and pattern fills, the
        hard-edged primitives, `draw_canvas`, `draw_image`, `blur`,
        `fill`, and the
        `fill_circles_aa`-style batches -- first draws what is
        pending and then draws itself, so it stays in order. So does a
        change of clip, blend mode or color space, and `restore`. Two
        things are not ordered against a pending batch: `set_pixel`
        and `write_pixel`, whose per-pixel cost a check would double,
        and reads -- `get_pixel`, `write_png`, `draw_canvas` with this
        canvas as the source -- which see the canvas without the
        pending shapes until `end_batch`.

        Calls nest; only the outermost `end_batch` draws.
        """
        self._batch_depth += 1

    def end_batch(mut self):
        """Draw everything recorded since the matching `begin_batch`.
        A no-op with no batch open, like `pop_clip` with nothing to
        pop.
        """
        if self._batch_depth == 0:
            return
        self._batch_depth -= 1
        if self._batch_depth == 0:
            self._flush_batch()

    def begin_supersampled(
        mut self, factor: Int, background: Color = Color(255, 255, 255)
    ) raises:
        """Draw the next region at `factor` times this canvas's
        resolution without ever holding the enlarged buffer: every
        shape between here and `end_supersampled` is recorded, and
        `end_supersampled` replays it one output band at a time into a
        scratch that holds only that band, downsamples each band and
        writes it here.

        Callers draw in this canvas's own coordinates. The half-pixel
        that box-downsampling costs is applied here, so a rectangle
        drawn at the same coordinates lands where it would have
        without the region -- the recipe on `downsample`, which every
        consumer would otherwise reimplement.

        A factor of 1 or less opens nothing and draws directly.

        Each band starts from `background`, as the recipe's own
        scratch does; what this canvas already shows underneath is not
        carried into the region. Seeding from it was measured both as
        a copy per pixel and as a nearest-neighbour upscale, and both
        cost more than the region saves, so a caller who needs to draw
        over existing content wants the two-step recipe instead.

        Args:
            factor: Resolution multiplier, 1 for none.
            background: What each band starts from.

        Raises:
            Error: A region is already open.
        """
        if self._supersample != 0:
            raise Error("begin_supersampled: a region is already open")
        if factor <= 1:
            return
        self.save()
        self._supersample = factor
        self._supersample_bg = background
        var shift = Float64(factor - 1) / 2.0
        self.translate(shift, shift)
        self.scale(Float64(factor), Float64(factor))
        # The coordinate space is the enlarged one while recording, so
        # geometry past this buffer's own rows is kept rather than
        # clipped away at the call.
        self._virtual_width = self.width * factor
        self._virtual_height = self.height * factor
        self.begin_batch()

    def end_supersampled(mut self) raises:
        """Draw what `begin_supersampled` recorded, band by band, and
        put the downsampled result on this canvas. A no-op when no
        region is open.

        Raises:
            Error: The band scratch cannot be allocated.
        """
        if self._supersample == 0:
            return
        var factor = self._supersample
        var bg = self._supersample_bg
        var batch = self._batch^
        self._batch = _Batch()
        self._batch_depth = 0
        self._supersample = 0
        if self._region_materialized:
            # The region gave up its banded replay when something
            # inside it had to draw rather than record, so this canvas
            # *is* the enlarged one: draw what is still pending into
            # it, then downsample it back (#409).
            self._virtual_width = self.width
            self._virtual_height = self.height
            if len(batch.ops) > 0:
                _render_batch(self, batch)
            # The enlarged buffer comes out and the output's goes
            # back in one step, so `self` is never left with a field
            # taken from it: the checker rejects reading one field of
            # `self` while another is uninitialized.
            var ew = self.width
            var eh = self.height
            var taken = self.pixels^
            self.pixels = self._region_pixels^
            self.width = self._region_width
            self.height = self._region_height
            self._virtual_width = self.width
            self._virtual_height = self.height
            self._region_materialized = False
            self._region_pixels = List[UInt8]()
            var enlarged = Canvas(ew, eh, taken^)
            var small = downsample(enlarged, factor)
            self.restore()
            draw_canvas(self, small, 0, 0)
            return
        self._virtual_width = self.width
        self._virtual_height = self.height
        self.restore()
        _replay_supersampled(self, batch, factor, bg)

    def _batching(self) -> Bool:
        """Whether a `begin_batch` is open, so a primitive records
        itself instead of drawing."""
        return self._batch_depth > 0

    def _record(mut self, op: _BatchOp):
        """Append one recorded closed-form primitive; see
        `_BatchOp`."""
        self._batch.ops.append(op)

    def _record_edges(
        mut self,
        edges: _EdgeTable,
        min_x: Int,
        min_y: Int,
        max_x: Int,
        max_y: Int,
        color: Color,
        fill_rule: FillRule,
        supersample: Int,
        exact: Bool,
    ):
        """Record edges already built; see `_Batch.record_edges`."""
        self._batch.record_edges(
            edges,
            min_x,
            min_y,
            max_x,
            max_y,
            color,
            fill_rule,
            supersample,
            exact,
        )

    def _record_stroke(
        mut self,
        points: List[FPoint],
        closed: Bool,
        half_width: Float64,
        cap: LineCap,
        dashes: List[Float64],
        dash_offset: Float64,
        join: LineJoin,
        miter_limit: Float64,
        matrix: Matrix2D,
        supersample: Int,
        color: Color,
    ):
        """Record a stroke to build when the batch is drawn; see
        `_Batch.record_stroke`."""
        self._batch.record_stroke(
            points,
            closed,
            half_width,
            cap,
            dashes,
            dash_offset,
            join,
            miter_limit,
            matrix,
            supersample,
            color,
        )

    def _record_glyph(
        mut self,
        mask: _CoverageMask,
        offset_x: Int,
        offset_y: Int,
        color: Color,
    ):
        """Record a cached glyph's coverage to composite when the
        batch is drawn; see `_glyph_op`."""
        if mask.width <= 0 or mask.height <= 0:
            return
        var first = len(self._batch.glyph_counts)
        var n = mask.width * mask.height
        var cp = mask.counts.unsafe_ptr()
        for k in range(n):
            self._batch.glyph_counts.append(cp[unsafe_offset=k])
        self._batch.ops.append(
            _glyph_op(
                first,
                n,
                mask.width,
                mask.height,
                offset_x + mask.origin_x,
                offset_y + mask.origin_y,
                mask.total_samples,
                color,
            )
        )

    def _record_path(
        mut self,
        path: Path,
        fill_rule: FillRule,
        supersample: Int,
        curve_steps: Int,
        color: Color,
    ):
        """Record a path to build when the batch is drawn; see
        `_Batch.record_path`."""
        self._batch.record_path(
            path, fill_rule, supersample, curve_steps, color
        )

    def _materialize_region(mut self):
        """Give up on replaying an open region a band at a time and
        hold the enlarged buffer instead: this canvas becomes the
        enlarged canvas until `end_supersampled` downsamples it back.

        What forces it is anything inside the region that draws rather
        than records -- `fill_circles_aa` and its relatives, a clip, a
        gradient, `blur`, `draw_canvas`, a hard-edged primitive. Those
        draw in the enlarged space, and before #409 they wrote it
        into the output buffer, which cannot address those rows.

        The result is the two-step recipe's, which is what the region
        promises; only the memory and the speed are given up.
        """
        if self._supersample == 0 or self._region_materialized:
            return
        var w = self._virtual_width
        var h = self._virtual_height
        var buf = List[UInt8](unsafe_uninit_length=w * h * BYTES_PER_PIXEL)
        _store_packed_span(buf, 0, w * h, _pack_rgba(self._supersample_bg))
        self._region_pixels = self.pixels^
        self.pixels = buf^
        self._region_width = self.width
        self._region_height = self.height
        self.width = w
        self.height = h
        self._region_materialized = True

    def _flush_batch(mut self):
        """Draw the pending batch now, keeping any open `begin_batch`
        open. What `end_batch` calls, and what every primitive or
        state change that cannot be recorded calls first so that it
        lands after the shapes recorded before it.

        The batch depth is zeroed while rendering so the row bodies
        draw rather than record, and the list is taken whole so a
        band never sees an appending list.

        Inside a supersampled region this is the signal that something
        cannot be recorded, so the region gives up its banded replay
        first: what follows draws in the enlarged space and needs a
        buffer that can hold it (#409).
        """
        if self._supersample != 0 and not self._region_materialized:
            self._materialize_region()
        if len(self._batch.ops) == 0:
            return
        var batch = self._batch^
        self._batch = _Batch()
        var depth = self._batch_depth
        self._batch_depth = 0
        _render_batch(self, batch)
        self._batch_depth = depth
        self._batch.reserve_like(batch)

    def row_bounds(self) -> Tuple[Int, Int]:
        """The rows this buffer holds, in the coordinates geometry is
        drawn in: (0, height) for an ordinary canvas, and the band's
        own slice of the enlarged space inside a supersampled replay
        (#391). A rasterizer clamping to "the canvas" wants these
        rather than 0 and `height`.

        Returns:
            The first row and one past the last.
        """
        if self._supersample != 0:
            # Recording: nothing is written yet, so the bound is the
            # enlarged space's, not this buffer's. Clamping to the
            # buffer here would drop the part of a shape that falls
            # below the output's own row count.
            return (0, self._virtual_height)
        return (self._row_origin, self._row_origin + self.height)

    def in_bounds(self, x: Int, y: Int) -> Bool:
        """Whether (x, y) is a real pixel on this canvas.

        Args:
            x: Column to check.
            y: Row to check.

        Returns:
            True if the column is on the canvas and the row is one this
            buffer holds -- normally 0 <= y < height, and the band's own
            rows when `_row_origin` is set.
        """
        var rb = self.row_bounds()
        return x >= 0 and x < self._virtual_width and y >= rb[0] and y < rb[1]

    def push_clip(mut self, x: Int, y: Int, width: Int, height: Int):
        """Restrict subsequent drawing to this sub-rectangle. Every
        primitive picks it up, since they all write through set_pixel.

        Intersects with the current effective clip and pushes the result,
        so nested clips compose: a child can restrict further but never
        escape its parent's region, even if its own rectangle extends
        past it. Pair with pop_clip(). A clip rectangle extending past
        the canvas bounds is fine; in_bounds still rejects anything
        outside the canvas.

        Under a canvas transform the rectangle is in user space. An
        axis-aligned transform maps it to another rectangle; a rotated
        or skewed one turns it into a clip path, with its bounding
        rectangle on this stack so `pop_clip` removes both together.

        Args:
            x: Clip rectangle's left edge.
            y: Clip rectangle's top edge.
            width: Clip rectangle's width.
            height: Clip rectangle's height.
        """
        self._flush_batch()
        if self._transformed:
            if self._transform.is_axis_aligned():
                var r = _mapped_rect(self._transform, x, y, width, height)
                self._push_clip_rect(r[0], r[1], r[2], r[3], -1)
                return
            var depth = self._clip_mask_count
            self._push_clip_mask(
                _through(_rect_path(x, y, width, height), self._transform),
                FillRule.EVEN_ODD,
                4,
                0,
            )
            var bb = _mapped_bounds(self._transform, x, y, width, height)
            self._push_clip_rect(bb[0], bb[1], bb[2], bb[3], depth)
            return
        self._push_clip_rect(x, y, width, height, -1)

    def _push_clip_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, mask_depth: Int
    ):
        """Intersect a device-space rectangle with the current clip and
        push it; `mask_depth` is -1 or the mask count the entry owns
        from (see `_ClipRect`).
        """
        var new_rect = _ClipRect(x, y, width, height)
        if len(self._clip_stack) > 0:
            new_rect = _intersect_clip(
                self._clip_stack[len(self._clip_stack) - 1], new_rect
            )
        new_rect.mask_depth = mask_depth
        self._clip_stack.append(new_rect)

    def pop_clip(mut self):
        """Remove the most recently pushed clip, reverting to the parent
        clip if one exists or to the whole canvas if not.

        A no-op on an empty stack rather than an error, matching
        in_bounds' handling of out-of-range requests: a stack alone
        cannot distinguish an unbalanced pop from "nothing to undo".
        """
        self._flush_batch()
        if len(self._clip_stack) == 0:
            return
        var top = self._clip_stack.pop()
        if top.mask_depth >= 0:
            while self._clip_mask_count > top.mask_depth:
                self.pop_clip_path()

    def push_clip_path(
        mut self,
        path: Path,
        fill_rule: FillRule = FillRule.EVEN_ODD,
        supersample: Int = 4,
        curve_steps: Int = 0,
    ):
        """Restrict subsequent drawing to `path`'s interior.

        The clip is *anti-aliased*, not a hard in/out test: the path's
        coverage becomes a 0-255 mask, and a pixel the path half covers
        lets half the drawing through.

        A new mask is multiplied into the current one, so a nested clip
        can only restrict further, never escape its parent. Rectangle
        clips still apply independently on top. Pair with
        `pop_clip_path`. Under a canvas transform `path` is in user
        space and is mapped before it is rasterized.

        Args:
            path: Shape to clip to. Its interior is what stays visible.
            fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
                Governs the interior of a self-intersecting or
                multi-sub-path clip shape exactly as it does a fill.
            supersample: Sub-pixel grid side length used to compute the
                mask's edge coverage.
            curve_steps: Straight-line segments per quad/cubic Bezier.
                0 (the default) picks a count from the curvature.
        """
        self._flush_batch()
        if self._transformed:
            self._push_clip_mask(
                _through(path, self._transform),
                fill_rule,
                supersample,
                curve_steps,
            )
        else:
            self._push_clip_mask(path, fill_rule, supersample, curve_steps)

    def _push_clip_mask(
        mut self,
        path: Path,
        fill_rule: FillRule,
        supersample: Int,
        curve_steps: Int,
    ):
        """`push_clip_path` for a path already in device space."""
        self.push_clip_coverage(
            _path_coverage_mask(
                path,
                self.width,
                self.height,
                fill_rule,
                supersample,
                curve_steps,
            )
        )

    def push_clip_coverage(mut self, var mask: List[UInt8]):
        """Restrict subsequent drawing to a coverage already computed:
        one 0-255 byte per canvas pixel, row-major, in device space.
        What `push_clip_path` pushes once it has rasterized its path,
        and what `canvas.mask.push_clip_mask` pushes for a `Mask`.
        Nests and pops exactly as a clip path does.

        Args:
            mask: `width * height` coverage bytes, taken by value.
        """
        self._flush_batch()
        if self._clip_mask_count > 0:
            # Intersect with the parent by multiplying coverages: a
            # pixel half-covered by an outer clip and half by an inner
            # one lets a quarter through, which is what nesting two
            # translucent stencils physically does.
            ref parent = self.clip_masks[self._clip_mask_count - 1]
            var mp = mask.unsafe_ptr()
            var pp = parent.unsafe_ptr()
            for i in range(self.width * self.height):
                var m = Int(mp[unsafe_offset=i])
                if m != 0:
                    mp[unsafe_offset=i] = UInt8(
                        _div255(m * Int(pp[unsafe_offset=i]))
                    )
        self.clip_masks.append(mask^)
        self._clip_mask_count += 1

    def has_clip_mask(self) -> Bool:
        """Whether a clip path is currently active.

        The check a caller writing through `write_pixel` needs: that
        method skips every per-pixel test, and a clip path's coverage is
        per-pixel by nature, so a bulk writer routes through `set_pixel`
        while one is pushed. See `write_pixel` and `_fill_region`.

        Returns:
            True if at least one clip path is pushed.
        """
        return self._clip_mask_count > 0

    def pop_clip_path(mut self):
        """Remove the most recently pushed clip path, reverting to the
        parent clip path if one exists or to no path clip if not.

        A no-op on an empty stack, matching `pop_clip`.
        """
        self._flush_batch()
        if self._clip_mask_count > 0:
            _ = self.clip_masks.pop()
            self._clip_mask_count -= 1

    def clip_coverage(self, x: Int, y: Int) -> UInt8:
        """How much of (x, y) the active clip paths let through: 255 if
        no clip path is active or the pixel is fully inside one, 0 if
        fully outside, in between on an anti-aliased boundary.

        Rectangle clips are not included; `in_clip` covers those, and
        `set_pixel` applies both.

        Args:
            x: Column to query.
            y: Row to query.

        Returns:
            Coverage 0-255.
        """
        if self._clip_mask_count == 0:
            return 255
        if not self.in_bounds(x, y):
            return 0
        return self.clip_masks[self._clip_mask_count - 1][
            (y - self._row_origin) * self.width + x
        ]

    def in_clip(self, x: Int, y: Int) -> Bool:
        """Whether (x, y) is inside the active clip region.

        Args:
            x: Column to check.
            y: Row to check.

        Returns:
            True if no clip is active, or (x, y) is inside the
            innermost pushed clip rectangle.
        """
        if len(self._clip_stack) == 0:
            return True
        # A reference, not a copy: this runs per pixel inside every
        # primitive's loop, and copying the entry is enough to push
        # set_pixel past what inlines there.
        ref top = self._clip_stack[len(self._clip_stack) - 1]
        return (
            x >= top.x
            and x < top.x + top.width
            and y >= top.y
            and y < top.y + top.height
        )

    def set_pixel(mut self, x: Int, y: Int, color: Color):
        """Write `color` at (x, y), a no-op if it's off-canvas or
        outside the active clip.

        Args:
            x: Column to write.
            y: Row to write.
            color: Color to write, combined with the existing pixel
                under the current blend mode.
        """
        if not self.in_bounds(x, y):
            return
        if not self.in_clip(x, y):
            return
        if self._clip_mask_count != 0:
            self._set_pixel_masked(x, y, color)
            return
        self.write_pixel(x, y, color)

    def _set_pixel_masked(mut self, x: Int, y: Int, color: Color):
        """`set_pixel`'s clip-path branch, kept out of line.

        `set_pixel` runs once per pixel for every primitive here, so its
        common path has to stay small enough to inline into those loops.
        Keep this branch, and the plain-integer `_clip_mask_count` guard
        that gates it, out of `set_pixel`'s body; folding either inline
        measurably slows every fill.
        """
        var coverage = self.clip_masks[self._clip_mask_count - 1][
            (y - self._row_origin) * self.width + x
        ]
        if coverage == 0:
            return
        if coverage == 255:
            self.write_pixel(x, y, color)
            return
        # Coverage scales the drawn color's own alpha rather than
        # replacing it, so clipping a translucent fill compounds the two.
        self.write_pixel(
            x, y, color.with_alpha(UInt8(_div255(Int(color.a) * Int(coverage))))
        )

    def _store_packed(mut self, start: Int, count: Int, packed: UInt32):
        """Write `packed` (see `_pack_rgba`) to `count` consecutive
        pixels from pixel index `start`. This is what a solid fill costs
        per row: no scratch span to build or free, and the wide stores
        in `_store_packed_span` keep a canvas-wide row at memcpy speed.

        Always serial. A row of a drawing operation is usually already
        running inside a band task, so the split belongs at the top of
        the operation, not here -- `_clear_packed` is the banded form,
        and only whole-buffer fills call it.
        """
        _store_packed_span(self.pixels, start, count, packed)

    def write_pixel(mut self, x: Int, y: Int, color: Color):
        """Write `color` at (x, y) *without* set_pixel's in_bounds/
        in_clip checks. The caller must already know (x, y) is inside
        both the canvas and the active clip, typically from a range
        `effective_fill_rect` (below) intersected against both.

        It also skips the clip *path* mask, which `effective_fill_rect`
        cannot fold in: a rectangle clip is a range, but a path clip is a
        per-pixel coverage value. A bulk writer must therefore check
        `has_clip_mask()` and fall back to `set_pixel` when one is
        active, as `_fill_region` and the gradient rect fills in
        canvas.shapes.rects do.

        Writes go through `pixels.unsafe_ptr()`, unchecked. The index is
        computed from `width` and the caller's validated (x, y), so it
        cannot leave the buffer. The blend path reads the background
        bytes from the same pointer rather than through `get_pixel`.

        Args:
            x: Column to write. Must already be known in-bounds.
            y: Row to write. Must already be known in-bounds.
            color: Color to write, combined with the existing pixel
                under the current blend mode.
        """
        if not self._blend.is_source_over():
            self._write_pixel_blended(x, y, color)
            return

        var idx = ((y - self._row_origin) * self.width + x) * BYTES_PER_PIXEL
        var p = self.pixels.unsafe_ptr()
        if color.a == 255:
            p[unsafe_offset=idx] = color.r
            p[unsafe_offset=idx + 1] = color.g
            p[unsafe_offset=idx + 2] = color.b
            p[unsafe_offset=idx + 3] = 255
            return
        if self._space.is_linear():
            self._write_pixel_linear(idx, color)
            return

        var dst_a = p[unsafe_offset=idx + 3]
        if dst_a == 255:
            # The overwhelmingly common case -- anything drawn onto a
            # canvas with an opaque background -- and the one that
            # avoids a per-pixel division. See Color.blend_over_opaque.
            var opaque_blend = color.blend_over_opaque(
                p[unsafe_offset=idx],
                p[unsafe_offset=idx + 1],
                p[unsafe_offset=idx + 2],
            )
            p[unsafe_offset=idx] = opaque_blend.r
            p[unsafe_offset=idx + 1] = opaque_blend.g
            p[unsafe_offset=idx + 2] = opaque_blend.b
            p[unsafe_offset=idx + 3] = 255
            return

        var blended = color.blend_over(
            Color(
                p[unsafe_offset=idx],
                p[unsafe_offset=idx + 1],
                p[unsafe_offset=idx + 2],
                dst_a,
            )
        )
        p[unsafe_offset=idx] = blended.r
        p[unsafe_offset=idx + 1] = blended.g
        p[unsafe_offset=idx + 2] = blended.b
        p[unsafe_offset=idx + 3] = blended.a

    def composite_alpha_row(
        mut self,
        x: Int,
        y: Int,
        alphas: List[UInt8],
        base: Int,
        count: Int,
        color: Color,
    ):
        """`write_pixel` of `color` at alpha `alphas[base + i]` for each
        of `count` pixels from (x, y) rightward, as one loop over the
        row: what compositing a cached glyph mask does per pixel,
        without a method call, an index computation and a clip test
        for each. The caller has already intersected the row with the
        canvas and the rectangle clip, and there is no clip path
        active. Each pixel's result is exactly `write_pixel`'s: the
        same shortcuts, the same `Color.blend_over_opaque` and
        `blend_over`.

        Args:
            x: Column of the first pixel.
            y: Row.
            alphas: Per-pixel alpha, 0-255, read from `base`.
            base: Index in `alphas` of the first pixel's alpha.
            count: Pixels to write.
            color: Color to write; its own alpha is replaced per pixel.
        """
        if not self._blend.is_source_over():
            for i in range(count):
                var a = alphas[base + i]
                if a != 0:
                    self._write_pixel_blended(x + i, y, color.with_alpha(a))
            return
        if self._space.is_linear():
            for i in range(count):
                var a = alphas[base + i]
                if a != 0:
                    self.write_pixel(x + i, y, color.with_alpha(a))
            return
        var p = self.pixels.unsafe_ptr()
        var ap = alphas.unsafe_ptr()
        var idx = ((y - self._row_origin) * self.width + x) * BYTES_PER_PIXEL
        for i in range(count):
            var a = ap[unsafe_offset=base + i]
            if a == 0:
                idx += BYTES_PER_PIXEL
                continue
            if a == 255:
                p[unsafe_offset=idx] = color.r
                p[unsafe_offset=idx + 1] = color.g
                p[unsafe_offset=idx + 2] = color.b
                p[unsafe_offset=idx + 3] = 255
            elif p[unsafe_offset=idx + 3] == 255:
                var blended = color.with_alpha(a).blend_over_opaque(
                    p[unsafe_offset=idx],
                    p[unsafe_offset=idx + 1],
                    p[unsafe_offset=idx + 2],
                )
                p[unsafe_offset=idx] = blended.r
                p[unsafe_offset=idx + 1] = blended.g
                p[unsafe_offset=idx + 2] = blended.b
                p[unsafe_offset=idx + 3] = 255
            else:
                var blended = color.with_alpha(a).blend_over(
                    Color(
                        p[unsafe_offset=idx],
                        p[unsafe_offset=idx + 1],
                        p[unsafe_offset=idx + 2],
                        p[unsafe_offset=idx + 3],
                    )
                )
                p[unsafe_offset=idx] = blended.r
                p[unsafe_offset=idx + 1] = blended.g
                p[unsafe_offset=idx + 2] = blended.b
                p[unsafe_offset=idx + 3] = blended.a
            idx += BYTES_PER_PIXEL

    def _write_pixel_linear(mut self, idx: Int, color: Color):
        """`write_pixel`'s LINEAR color-space branch, kept out of line
        for the same reason `_set_pixel_masked` is: `color` is neither
        opaque nor, when this is reached, blended by a mode other than
        source-over."""
        var p = self.pixels.unsafe_ptr()
        var blended: Color
        if p[unsafe_offset=idx + 3] == 255:
            blended = self._transfer.blend_over_opaque(
                color,
                p[unsafe_offset=idx],
                p[unsafe_offset=idx + 1],
                p[unsafe_offset=idx + 2],
            )
        else:
            blended = self._transfer.blend_over(
                color,
                Color(
                    p[unsafe_offset=idx],
                    p[unsafe_offset=idx + 1],
                    p[unsafe_offset=idx + 2],
                    p[unsafe_offset=idx + 3],
                ),
            )
        p[unsafe_offset=idx] = blended.r
        p[unsafe_offset=idx + 1] = blended.g
        p[unsafe_offset=idx + 2] = blended.b
        p[unsafe_offset=idx + 3] = blended.a

    def _write_pixel_blended(mut self, x: Int, y: Int, color: Color):
        """`write_pixel` under any mode but SOURCE_OVER, kept out of
        line so the default path above compiles with one field test
        ahead of it.

        None of `write_pixel`'s shortcuts survive here: an opaque
        source does not necessarily replace the pixel (DARKEN keeps
        the darker channel), a transparent one does not necessarily
        leave it alone (DESTINATION_IN clears it), and an opaque
        destination does not necessarily stay opaque (XOR punches
        through it). So the general blend reads all four bytes and
        writes all four back.
        """
        var idx = ((y - self._row_origin) * self.width + x) * BYTES_PER_PIXEL
        var p = self.pixels.unsafe_ptr()
        var blended = _blend_pixel(
            self._blend,
            color,
            Color(
                p[unsafe_offset=idx],
                p[unsafe_offset=idx + 1],
                p[unsafe_offset=idx + 2],
                p[unsafe_offset=idx + 3],
            ),
        )
        p[unsafe_offset=idx] = blended.r
        p[unsafe_offset=idx + 1] = blended.g
        p[unsafe_offset=idx + 2] = blended.b
        p[unsafe_offset=idx + 3] = blended.a

    def effective_fill_rect(
        self, x: Int, y: Int, width: Int, height: Int
    ) -> Tuple[Int, Int, Int, Int]:
        """The (x, y, width, height) a rectangular fill covering
        [x, x+width) x [y, y+height) may actually touch, intersected
        against the canvas bounds and the active clip -- the same
        intersection set_pixel enforces per pixel, computed once for a
        caller about to loop over the whole region. Pair with
        write_pixel.

        A returned width/height of 0 means nothing in the requested
        rectangle is drawable; `range(0)` is a no-op, so callers need no
        separate check.

        Args:
            x: Requested rectangle's left edge.
            y: Requested rectangle's top edge.
            width: Requested rectangle's width.
            height: Requested rectangle's height.

        Returns:
            (x, y, width, height) of the sub-rectangle actually
            touchable, clamped to the canvas and the active clip.
        """
        var left = max(0, x)
        # Rows are the virtual canvas's when a supersampled region is
        # open or this is one of its bands, so the vertical clamp is
        # whichever of those the canvas is in (#391).
        var rb = self.row_bounds()
        var top = max(rb[0], y)
        var right = min(self._virtual_width, x + width)
        var bottom = min(rb[1], y + height)
        if len(self._clip_stack) > 0:
            ref top_clip = self._clip_stack[len(self._clip_stack) - 1]
            left = max(left, top_clip.x)
            top = max(top, top_clip.y)
            right = min(right, top_clip.x + top_clip.width)
            bottom = min(bottom, top_clip.y + top_clip.height)
        return (left, top, max(0, right - left), max(0, bottom - top))

    def get_pixel(self, x: Int, y: Int) -> Color:
        """Read the color at (x, y).

        Args:
            x: Column to read.
            y: Row to read.

        Returns:
            The pixel's color, or opaque black if (x, y) is off-canvas.
        """
        if not self.in_bounds(x, y):
            return Color(0, 0, 0)
        return self.read_pixel(x, y)

    def read_pixel(self, x: Int, y: Int) -> Color:
        """Read (x, y) *without* `get_pixel`'s in_bounds check, the
        counterpart to `write_pixel` and subject to the same contract:
        the caller must already know the coordinate is on the canvas,
        typically because the loop bounds came from `width`/`height`.

        `get_pixel` stays the checked entry point, and returns opaque
        black off-canvas rather than reading out of range. Whole-image
        passes -- downsampling, encoding a file -- derive every
        coordinate from the canvas's dimensions, so the check
        re-establishes what the loop already guarantees.

        Args:
            x: Column to read. Must already be known in-bounds.
            y: Row to read. Must already be known in-bounds.

        Returns:
            The pixel's color.
        """
        var idx = ((y - self._row_origin) * self.width + x) * BYTES_PER_PIXEL
        var p = self.pixels.unsafe_ptr()
        return Color(
            p[unsafe_offset=idx],
            p[unsafe_offset=idx + 1],
            p[unsafe_offset=idx + 2],
            p[unsafe_offset=idx + 3],
        )

    def draw_image(
        mut self,
        image: Canvas,
        x: Float64,
        y: Float64,
        width: Float64 = 0.0,
        height: Float64 = 0.0,
    ) raises:
        """Draw `image` as a block of cells with its top-left at
        (x, y), scaled to `width x height` (its own pixel size when
        0), under the current transform: `DrawTarget`'s image
        primitive, the method form of `draw_image` in
        canvas/compose.mojo, which says how the cells land.

        Args:
            image: The cells to draw. Unchanged.
            x: Left edge, in user coordinates.
            y: Top edge.
            width: Drawn width, or 0 for `image.width`.
            height: Drawn height, or 0 for `image.height`.

        Raises:
            Error: The canvas transform is singular.
        """
        draw_image(self, image, x, y, width, height)

    def fill(mut self, color: Color):
        """Fill the whole canvas (or the active clip region, if any)
        with `color`.

        Args:
            color: Color to fill with, blended over existing pixels if
                translucent.
        """
        self._flush_batch()
        var region = self.effective_fill_rect(0, 0, self.width, self.height)
        # The whole buffer, opaque, source-over, no clip path: the fill
        # is one contiguous run of stores, which is the one shape that
        # can be split across bands. Every other case -- a clip cutting
        # the region down, a translucent color, another blend mode --
        # goes to `_fill_region` as before.
        if (
            color.a == 255
            and self._blend.is_source_over()
            and self._clip_mask_count == 0
            and region[0] == 0
            and region[1] == 0
            and region[2] == self.width
            and region[3] == self.height
        ):
            _clear_packed(
                self.pixels,
                self.width * self.height,
                _pack_rgba(color),
                self._max_workers,
            )
            return
        self._fill_region_top(region[0], region[1], region[2], region[3], color)

    def _fill_region_top(
        mut self, rx: Int, ry: Int, rw: Int, rh: Int, color: Color
    ):
        """`_fill_region` for a call that is not already inside a band
        task -- `Canvas.fill` and `canvas.shapes.rects.fill_rect` --
        split across rows when the work is arithmetic rather than
        stores.

        The distinction matters and is not the usual one. An opaque
        source-over fill is one store per pixel with no reads, so it is
        limited by memory rather than by the core, and below one L3
        slice bands make it *slower* (see `_clear_packed`). Every other
        case -- another blend mode, a translucent color, an active clip
        mask -- reads each destination pixel and does per-pixel
        arithmetic on it. That is ALU-bound and scales: the multiply
        span measured 199 us serial and 60 us across bands over a
        600x400 rectangle, and the same kernel is what `#350` had
        priced against a floor 6.4x too cheap to notice.

        Only the three top-level callers reach this. `aa_area`'s span
        writer keeps calling `_fill_region` directly, since it already
        runs inside a band of its own.
        """
        if rw <= 0 or rh <= 0:
            return
        var stores_only = (
            self._clip_mask_count == 0
            and self._blend.is_source_over()
            and (color.a == 255 or color.a == 0)
        )
        var bands = 1
        if not stores_only:
            bands = _bands_for(rw * rh, rh, self._max_workers)
        if bands == 1:
            self._fill_region(rx, ry, rw, rh, color)
            return

        var per_band = (rh + bands - 1) // bands
        var tg = TaskGroup()
        for b in range(bands):
            var band_y = ry + b * per_band
            var band_h = min(per_band, ry + rh - band_y)
            if band_h <= 0:
                continue
            tg.create_task(
                _fill_region_band_async(self, rx, band_y, rw, band_h, color)
            )
        tg.wait()

    def _fill_region(
        mut self, rx: Int, ry: Int, rw: Int, rh: Int, color: Color
    ):
        """Fill an already-clipped, already-bounds-checked rectangle --
        the region `effective_fill_rect` returns, so every coordinate in
        it is known drawable and no per-pixel check is needed.

        The translucent case blends per pixel but hoists what does not
        vary: the source color's premultiplied terms and the
        complementary alpha are computed once for the whole rectangle,
        leaving one multiply-add and one `_div255` per channel where the
        destination is opaque. That branch is `blend_over_opaque`
        inlined, with the same arithmetic. A translucent destination
        falls back to `blend_over` and its per-pixel divide.
        """
        if rw <= 0 or rh <= 0:
            return

        # A clip path modulates each pixel individually, which neither
        # the bulk copy nor the hoisted blend below can express -- so
        # with one active this falls back to the checked per-pixel
        # path, which already consults the mask. Nothing pays for this
        # until a clip path is actually pushed.
        if self._clip_mask_count > 0:
            for y in range(ry, ry + rh):
                for x in range(rx, rx + rw):
                    self.set_pixel(x, y, color)
            return

        # Both shortcuts below are source-over identities -- an opaque
        # color replaces the pixel, a fully transparent one leaves it
        # -- and neither holds for the other modes, so those take the
        # general blend per pixel. The coordinates are already known
        # drawable, so this goes straight to the blend rather than
        # through set_pixel or write_pixel.
        if not self._blend.is_source_over():
            for y in range(ry, ry + rh):
                _blend_span(
                    self._blend,
                    self.pixels,
                    (y - self._row_origin) * self.width + rx,
                    rw,
                    color,
                )
            return

        var p = self.pixels.unsafe_ptr()
        var stride = self.width * BYTES_PER_PIXEL

        if color.a == 255:
            # One 32-bit store per pixel of the packed color, and no
            # scratch span to allocate per call -- fill_circle_aa and
            # fill_ellipse_aa call this once per interior row.
            var packed = _pack_rgba(color)
            for y in range(ry, ry + rh):
                self._store_packed(
                    (y - self._row_origin) * self.width + rx, rw, packed
                )
            return

        if color.a == 0:
            return

        if self._space.is_linear():
            for y in range(ry, ry + rh):
                for x in range(rx, rx + rw):
                    self.write_pixel(x, y, color)
            return

        # Carry the index through a unit-stride inner loop. Four opaque
        # destination pixels at a time go through one
        # sixteen-lane vector of the same hoisted arithmetic, `_div255`
        # as the same multiply and shift; a group with a translucent pixel
        # takes the scalar loop below.
        var sa = Int(color.a)
        var inv = 255 - sa
        var cr = Int(color.r) * sa
        var cg = Int(color.g) * sa
        var cb = Int(color.b) * sa
        comptime W = 16
        var src_v = SIMD[DType.uint32, W]()
        var inv_v = SIMD[DType.uint32, W](UInt32(inv))
        for k in range(W):
            var ch = k % 4
            if ch == 0:
                src_v[k] = UInt32(cr)
            elif ch == 1:
                src_v[k] = UInt32(cg)
            elif ch == 2:
                src_v[k] = UInt32(cb)
            else:
                # The alpha lane comes out 255 whatever it held: full
                # source-over weight on an opaque destination.
                src_v[k] = UInt32(255 * sa)
        for y in range(ry, ry + rh):
            var idx = (y - self._row_origin) * stride + rx * BYTES_PER_PIXEL
            var remaining = rw
            while remaining >= 4:
                if not (
                    p[unsafe_offset=idx + 3] == 255
                    and p[unsafe_offset=idx + 7] == 255
                    and p[unsafe_offset=idx + 11] == 255
                    and p[unsafe_offset=idx + 15] == 255
                ):
                    break
                var dst = (
                    p.unsafe_offset(idx)
                    .unsafe_load[width=W]()
                    .cast[DType.uint32]()
                )
                var t = src_v + dst * inv_v
                var out = (t * UInt32(_DIV255_MUL)) >> UInt32(_DIV255_SHIFT)
                p.unsafe_offset(idx).unsafe_store(out.cast[DType.uint8]())
                idx += 4 * BYTES_PER_PIXEL
                remaining -= 4
            for _ in range(remaining):
                if p[unsafe_offset=idx + 3] == 255:
                    # Opaque destination: the hoisted division-free
                    # form, and the result stays opaque.
                    p[unsafe_offset=idx] = UInt8(
                        _div255(cr + Int(p[unsafe_offset=idx]) * inv)
                    )
                    p[unsafe_offset=idx + 1] = UInt8(
                        _div255(cg + Int(p[unsafe_offset=idx + 1]) * inv)
                    )
                    p[unsafe_offset=idx + 2] = UInt8(
                        _div255(cb + Int(p[unsafe_offset=idx + 2]) * inv)
                    )
                else:
                    # Translucent destination: the general src-over,
                    # which needs the per-pixel divide.
                    var blended = color.blend_over(
                        Color(
                            p[unsafe_offset=idx],
                            p[unsafe_offset=idx + 1],
                            p[unsafe_offset=idx + 2],
                            p[unsafe_offset=idx + 3],
                        )
                    )
                    p[unsafe_offset=idx] = blended.r
                    p[unsafe_offset=idx + 1] = blended.g
                    p[unsafe_offset=idx + 2] = blended.b
                    p[unsafe_offset=idx + 3] = blended.a
                idx += BYTES_PER_PIXEL

    def begin_annotated_group(mut self, title: String):
        """`DrawTarget`'s group label, which a raster canvas has
        nowhere to put: a no-op, so code written against the trait runs
        unchanged on any backend. `SvgCanvas` emits `<g><title>` here
        and `PdfCanvas` a marked-content sequence.

        Args:
            title: Ignored.
        """
        pass

    def end_annotated_group(mut self):
        """Closes what `begin_annotated_group` did not open: a no-op,
        for the same reason.
        """
        pass

    def fill_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, color: Color
    ):
        """Same as `canvas.shapes.rects.fill_rect`, callable as a
        method.

        Args:
            x: Rectangle's left edge.
            y: Rectangle's top edge.
            width: Rectangle's width.
            height: Rectangle's height.
            color: Fill color.
        """
        fill_rect(self, x, y, width, height, color)

    def fill_rect(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        color: Color,
    ):
        fill_rect(self, x, y, width, height, color)

    def fill_rect_gradient(
        mut self,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        gradient: LinearGradient,
    ):
        """Same as `canvas.shapes.rects.fill_rect_gradient`,
        callable as a method.

        Args:
            x: Rectangle's left edge.
            y: Rectangle's top edge.
            width: Rectangle's width.
            height: Rectangle's height.
            gradient: Fill source, projected across the rectangle.
        """
        fill_rect_gradient(self, x, y, width, height, gradient)

    def fill_rect_gradient(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        gradient: LinearGradient,
    ):
        fill_rect_gradient(self, x, y, width, height, gradient)

    def draw_line_aa(
        mut self,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int,
        color: Color,
        width: Float64 = 1.0,
        dashes: List[Float64] = List[Float64](),
        dash_offset: Float64 = 0.0,
        cap: LineCap = LineCap.ROUND,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """Same as `canvas.shapes.lines.draw_line_aa`, callable as
        a method.

        Args:
            x0: Start point's x.
            y0: Start point's y.
            x1: End point's x.
            y1: End point's y.
            color: Stroke color.
            width: Stroke width in pixels.
            dashes: On/off segment lengths in user-space pixels, cycled
                along the line. Empty (default) draws a solid line.
            dash_offset: Distance into the dash pattern the line starts
                at.
            cap: How the two ends are finished -- see LineCap.
            join: Unused for a single segment, which has no corners.
            miter_limit: Unused for a single segment.
        """
        draw_line_aa(
            self,
            x0,
            y0,
            x1,
            y1,
            color,
            width=width,
            dashes=dashes,
            dash_offset=dash_offset,
            cap=cap,
            join=join,
            miter_limit=miter_limit,
        )

    def draw_line_aa(
        mut self,
        x0: Float64,
        y0: Float64,
        x1: Float64,
        y1: Float64,
        color: Color,
        width: Float64 = 1.0,
        dashes: List[Float64] = List[Float64](),
        dash_offset: Float64 = 0.0,
        cap: LineCap = LineCap.ROUND,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """Same as `canvas.shapes.lines.draw_line_aa`, callable as
        a method.

        Args:
            x0: Start point's x.
            y0: Start point's y.
            x1: End point's x.
            y1: End point's y.
            color: Stroke color.
            width: Stroke width in pixels.
            dashes: On/off segment lengths in user-space pixels, cycled
                along the line. Empty (default) draws a solid line.
            dash_offset: Distance into the dash pattern the line starts
                at.
            cap: How the two ends are finished -- see LineCap.
            join: Unused for a single segment, which has no corners.
            miter_limit: Unused for a single segment.
        """
        draw_line_aa(
            self,
            x0,
            y0,
            x1,
            y1,
            color,
            width=width,
            dashes=dashes,
            dash_offset=dash_offset,
            cap=cap,
            join=join,
            miter_limit=miter_limit,
        )

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        """Same as `canvas.shapes.circles.fill_circle_aa`,
        callable as a method.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Circle radius in pixels.
            color: Fill color.
        """
        fill_circle_aa(self, cx, cy, radius, color)

    def fill_circles_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        color: Color,
    ) raises:
        """`DrawTarget`'s batched disks: the canvas is split across
        cores rather than the markers. See `canvas.shapes.circles`.

        Args:
            centers: Sub-pixel centre of each marker, in draw order.
            radius: Radius shared by every marker, in pixels.
            color: Fill color shared by every marker.
        """
        from canvas.shapes.circles import fill_circles_aa as _batch

        _batch(self, centers, radius, color)

    def fill_circles_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        colors: List[Color],
    ) raises:
        """`fill_circles_aa` with a color per marker.

        Args:
            centers: Sub-pixel centre of each marker, in draw order.
            radius: Radius shared by every marker, in pixels.
            colors: One color per centre, same length as `centers`.

        Raises:
            Error: If `colors` is not the same length as `centers`.
        """
        from canvas.shapes.circles import fill_circles_aa as _batch

        _batch(self, centers, radius, colors)

    def fill_circle_aa(
        mut self, cx: Float64, cy: Float64, radius: Float64, color: Color
    ):
        fill_circle_aa(self, cx, cy, radius, color)

    def fill_ellipses_aa(
        mut self,
        centers: List[FPoint],
        rx: Float64,
        ry: Float64,
        color: Color,
    ) raises:
        """`DrawTarget`'s batched ellipses: the canvas is split across
        cores rather than the markers. See `canvas.shapes.ellipses`.

        Args:
            centers: Sub-pixel centre of each marker, in draw order.
            rx: Horizontal radius shared by every marker, in pixels.
            ry: Vertical radius shared by every marker, in pixels.
            color: Fill color shared by every marker.
        """
        from canvas.shapes.ellipses import fill_ellipses_aa as _batch

        _batch(self, centers, rx, ry, color)

    def fill_ellipses_aa(
        mut self,
        centers: List[FPoint],
        rx: Float64,
        ry: Float64,
        colors: List[Color],
    ) raises:
        """`fill_ellipses_aa` with a color per marker.

        Args:
            centers: Sub-pixel centre of each marker, in draw order.
            rx: Horizontal radius shared by every marker, in pixels.
            ry: Vertical radius shared by every marker, in pixels.
            colors: One color per centre, same length as `centers`.
        """
        from canvas.shapes.ellipses import fill_ellipses_aa as _batch

        _batch(self, centers, rx, ry, colors)

    def draw_circle_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """Same as `canvas.shapes.circles.draw_circle_aa`, callable as
        a method.

        Args:
            cx: Center x, sub-pixel.
            cy: Center y, sub-pixel.
            radius: Circle radius in pixels, to the middle of the
                stroke.
            color: Outline color.
            width: Stroke width in pixels.
        """
        draw_circle_aa(self, cx, cy, radius, color, width=width)

    def fill_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """Same as `canvas.shapes.ellipses.fill_ellipse_aa`,
        callable as a method.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius in pixels.
            ry: Vertical radius in pixels.
            color: Fill color.
        """
        fill_ellipse_aa(self, cx, cy, rx, ry, color)

    def fill_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
    ):
        fill_ellipse_aa(self, cx, cy, rx, ry, color)

    def draw_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """Same as `canvas.shapes.ellipses.draw_ellipse_aa`,
        callable as a method.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius in pixels.
            ry: Vertical radius in pixels.
            color: Outline color.
        """
        draw_ellipse_aa(self, cx, cy, rx, ry, color)

    def draw_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """Same as `canvas.shapes.ellipses.draw_ellipse_aa`, callable
        as a method.

        Args:
            cx: Center x, sub-pixel.
            cy: Center y, sub-pixel.
            rx: Horizontal radius in pixels, to the middle of the
                stroke.
            ry: Vertical radius in pixels, to the middle of the
                stroke.
            color: Outline color.
            width: Stroke width in pixels.
        """
        draw_ellipse_aa(self, cx, cy, rx, ry, color, width=width)

    def fill_arc_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        """Same as `canvas.shapes.arcs.fill_arc_aa`, callable as a
        method.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Wedge radius in pixels.
            start_angle: Sweep start, radians, 0 pointing along +x.
            end_angle: Sweep end, radians.
            color: Fill color.
        """
        fill_arc_aa(self, cx, cy, radius, start_angle, end_angle, color)

    def fill_arcs_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ) raises:
        """`DrawTarget`'s batched wedges: the canvas is split across
        cores rather than the wedges. See `canvas.shapes.arcs`.

        Args:
            centers: Sub-pixel centre of each wedge, in draw order.
            radius: Radius shared by every wedge, in pixels.
            start_angle: Start of the sweep, radians, shared.
            end_angle: End of the sweep, radians, shared.
            color: Fill color shared by every wedge.
        """
        from canvas.shapes.arcs import fill_arcs_aa as _batch

        _batch(self, centers, radius, start_angle, end_angle, color)

    def fill_arcs_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        colors: List[Color],
    ) raises:
        """`fill_arcs_aa` with a color per wedge.

        Args:
            centers: Sub-pixel centre of each wedge, in draw order.
            radius: Radius shared by every wedge, in pixels.
            start_angle: Start of the sweep, radians, shared.
            end_angle: End of the sweep, radians, shared.
            colors: One color per centre, same length as `centers`.
        """
        from canvas.shapes.arcs import fill_arcs_aa as _batch

        _batch(self, centers, radius, start_angle, end_angle, colors)

    def fill_ring_sector_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        inner_radius: Float64,
        outer_radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        """Same as `canvas.shapes.arcs.fill_ring_sector_aa`,
        callable as a method.

        Args:
            cx: Center x.
            cy: Center y.
            inner_radius: Ring's inner edge, in pixels.
            outer_radius: Ring's outer edge, in pixels.
            start_angle: Sweep start, radians, 0 pointing along +x.
            end_angle: Sweep end, radians.
            color: Fill color.
        """
        fill_ring_sector_aa(
            self,
            cx,
            cy,
            inner_radius,
            outer_radius,
            start_angle,
            end_angle,
            color,
        )

    def stroke_path_aa(
        mut self,
        path: Path,
        color: Color,
        width: Float64 = 1.0,
        dashes: List[Float64] = List[Float64](),
        dash_offset: Float64 = 0.0,
        cap: LineCap = LineCap.ROUND,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """Same as `canvas.path.stroke_path_aa`, callable as a
        method.

        Args:
            path: Path to stroke.
            color: Stroke color.
            width: Stroke width in pixels.
            dashes: On/off segment lengths in user-space pixels, cycled
                along the stroke. Empty (default) draws a solid line.
            dash_offset: Distance into the dash pattern the stroke
                starts at.
            cap: How an open sub-path's two ends are finished -- see
                LineCap.
            join: How corners are turned -- see LineJoin.
            miter_limit: Ratio past which a MITER join falls back to
                BEVEL, as a multiple of half the stroke width.
        """
        stroke_path_aa(
            self,
            path,
            color,
            width=width,
            dashes=dashes,
            dash_offset=dash_offset,
            cap=cap,
            join=join,
            miter_limit=miter_limit,
        )

    def fill_path_aa(
        mut self,
        path: Path,
        color: Color,
        fill_rule: FillRule = FillRule.EVEN_ODD,
    ):
        """Same as `canvas.path.fill_path_aa`, callable as a
        method.

        Args:
            path: Path to fill.
            color: Fill color.
            fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
        """
        fill_path_aa(self, path, color, fill_rule)

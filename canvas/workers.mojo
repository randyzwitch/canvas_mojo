"""How a parallel pass decides how many row bands to split itself into.

Every banded pass in this package writes disjoint rows and reads
shared input, so the only questions are how much work is worth a task
and how many tasks a caller will allow.

The second used to have no answer at all: an application rendering
several canvases at once had each of them fan out to every thread.
`Canvas.set_max_workers` is that answer, and it is what `_bands_for`
respects. The cap is a per-render ceiling rather than a budget across
renders: two canvases each capped at 8 may use 16 threads between
them, which is the point -- a knob for keeping one render from taking
the machine, not an allocator.

The first mostly answers itself. Measured band by band on a 64-thread
machine, the sweep, the source fills and the transformed composite go
on improving to the core count and past the sizes anyone renders: an
800x600 even-odd fill runs 4669 us on one band and 760 on sixty-four,
a gradient rectangle 5567 and 486. So the default is the count the
limit allows, and the floor below which a pass runs inline is what
keeps a glyph off the task queue.

`_bands_for_work` is for the exception. Blur is one: its bands
recompute a halo of rows for their neighbours, so past sixteen the
duplicated work costs more than the split saves (1123 us at sixteen,
1306 at sixty-four). A kernel only takes it with a figure measured for
that kernel.
"""

from std.runtime.asyncrt import parallelism_level

# Below this much work a pass runs inline rather than dispatching
# tasks at all: task setup is not free and the shapes this package
# fills most often are glyph-sized. Set by benchmark (#92) and
# re-measured for #292 -- re-benchmark before changing it.
comptime _MIN_PARALLEL_WORK = 40000


def _worker_limit(requested: Int) -> Int:
    """How many workers a pass may use.

    Args:
        requested: The caller's cap, 0 or less for no cap of its own.

    Returns:
        The cap when the caller set one below what the runtime offers,
        the runtime's count otherwise.
    """
    var available = parallelism_level()
    if requested <= 0 or requested > available:
        return available
    return requested


def _bands_for(work: Int, rows: Int, cap: Int) -> Int:
    """How many row bands to split `work` over.

    One band below `_MIN_PARALLEL_WORK`, where dispatching costs more
    than the work does. Above it, as many as the worker limit and the
    rows allow, which is what the measurements support for every
    kernel here but blur.

    Args:
        work: The pass's own measure of how much there is to do.
        rows: Rows available to divide, which bounds the band count.
        cap: The caller's worker cap, from `Canvas.max_workers`.

    Returns:
        The band count, at least 1.
    """
    if work < _MIN_PARALLEL_WORK:
        return 1
    var bands = _worker_limit(cap)
    if bands > rows:
        bands = rows
    if bands < 1:
        bands = 1
    return bands


def _bands_for_work(work: Int, rows: Int, work_per_band: Int, cap: Int) -> Int:
    """`_bands_for` for a kernel measured to want fewer bands than the
    limit -- one whose bands duplicate work, as blur's halo does.

    Args:
        work: The pass's own measure of how much there is to do, in
            whatever unit its `work_per_band` is expressed in.
        rows: Rows available to divide, which bounds the band count.
        work_per_band: How much work is worth one task, measured for
            that kernel.
        cap: The caller's worker cap, from `Canvas.max_workers`.

    Returns:
        The band count, at least 1.
    """
    var bands = _bands_for(work, rows, cap)
    var by_work = work // max(work_per_band, 1)
    if by_work < bands:
        bands = by_work
    if bands < 1:
        bands = 1
    return bands

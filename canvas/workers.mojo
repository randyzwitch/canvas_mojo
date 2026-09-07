"""How a parallel pass decides how many row bands to split itself into.

Every banded pass in this package writes disjoint rows and reads
shared input, so the only questions are how much work is worth a task
and how many tasks a caller will allow.

Both answers used to be implicit. A pass either ran inline or fanned
out to `parallelism_level()`, which on a 64-thread machine means 64
tasks for a fill barely over the threshold; and an application
rendering several canvases at once had no way to say that each should
take a share rather than all of it.

`_bands_for` answers the first from a per-kernel figure for how much
work is worth a task, and `Canvas.set_max_workers` answers the second.
The cap is a per-render ceiling rather than a budget across renders:
two canvases each capped at 8 may use 16 threads between them, which
is the point -- it is a knob for keeping one render from taking the
machine, not an allocator.
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


def _bands_for(work: Int, rows: Int, work_per_band: Int, cap: Int) -> Int:
    """How many row bands to split `work` over.

    One band below `_MIN_PARALLEL_WORK`, where dispatching costs more
    than the work does. Above it, enough bands to give each about
    `work_per_band`, never more than the worker limit and never more
    than there are rows to divide.

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
    if work < _MIN_PARALLEL_WORK:
        return 1
    var bands = work // max(work_per_band, 1)
    var limit = _worker_limit(cap)
    if bands > limit:
        bands = limit
    if bands > rows:
        bands = rows
    if bands < 1:
        bands = 1
    return bands

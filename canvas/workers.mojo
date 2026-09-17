"""Helpers for splitting parallel passes into row bands, and the one
place the library runs a band as a task.

`run_bands` is the only caller of `TaskGroup` in `canvas/`, so the
private `std.runtime._asyncrt` import lives here alone in the library
(#472; the roofline benchmarks import it too, to price the runtime
itself), and so do the two rules that make banding safe: what a task borrows must
outlive the wait (#263), and no heap-owning aggregate may cross
`create_task` by value, since the runtime delivers it corrupted
(#97). A band is a closure that captures its context by reference
and takes only the band index, so nothing aggregate crosses the task
boundary; the #97 reproducer rewritten that way is clean where the
by-value form corrupts or crashes, on Mojo 1.1 as on 1.0.
"""

from std.runtime import parallelism_level
from std.runtime._asyncrt import TaskGroup

# Below this much work, a pass runs inline instead of dispatching tasks.
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

    Uses one band below `_MIN_PARALLEL_WORK`; otherwise uses up to the
    worker limit and available row count.

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
    """Choose bands while requiring at least `work_per_band` work per band.

    Args:
        work: The pass's own measure of how much there is to do, in
            whatever unit its `work_per_band` is expressed in.
        rows: Rows available to divide, which bounds the band count.
        work_per_band: Minimum work assigned to each band.
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


async def _band_task(work: Some[def(Int) -> None], b: Int):
    """`work(b)` as a task; see `run_bands`."""
    work(b)


def run_bands(bands: Int, work: Some[def(Int) -> None]):
    """Run `work(b)` for every band `b` in `0 <= b < bands` and return
    once all have finished. One band runs on the caller's thread, so
    the serial case costs no task; more run as tasks on the runtime's
    pool. `work` is typically a closure over the pass's context with a
    capture list naming each value it reads or writes, and the bands
    must write disjoint rows or slots, which is each pass's own
    argument to make. `work` cannot raise: a task is a non-raising
    coroutine, so a band reports a failure through what it writes.

    Args:
        bands: How many bands; from `_bands_for` or `_bands_for_work`.
        work: The band body, given the band index.
    """
    if bands <= 1:
        work(0)
        return
    var tg = TaskGroup()
    for b in range(bands):
        tg.create_task(_band_task(work, b))
    tg.wait()
    # `work` and everything it captures must outlive the wait; naming
    # it here keeps it alive past the last task (#263).
    _ = bands

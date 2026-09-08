"""Helpers for splitting parallel passes into row bands."""

from std.runtime.asyncrt import parallelism_level

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

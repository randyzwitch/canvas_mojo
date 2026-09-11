"""What the CPU this process is running on looks like, for the few
thresholds that depend on it.

Most of this package's parallelism decisions are work counts, which
are machine-independent enough to be constants. Two are not: whether a
buffer still fits the last-level cache the writing core owns decides
whether banding a pure-store pass helps or hurts (`_clear_bands` in
buffer.mojo), and the same question about a source decides how far a
read-heavy pass should spread (`_read_local_bands` in resize.mojo).
Both were measured on one machine and were written as that machine's
number, 16 MB, which is one L3 slice of a Threadripper 3970X. On a
laptop with 8 MB of L3 that constant keeps a 12 MB clear serial when
banding would win, and on a part with larger slices it bands a clear
that would have been faster left alone (#399).

`l3_slice_bytes` asks the operating system instead. The quantity
wanted is not the chip's total L3 but the share one core can reach
without crossing to another complex, which is exactly what both
platforms report: Linux names the last-level cache of cpu0 in sysfs
together with the CPUs sharing it (on the 3970X, 16384K shared by four
cores and their SMT siblings, the CCX), and macOS reports
`hw.l3cachesize`. Where neither answers, or answers something outside
the range any real cache occupies, the measured constant stands.

The value cannot change while the process runs, so it is read once
into a process-wide global and every later call is a lookup: 12.7 ns
against the 23 us clear of an 800x600 canvas, the smallest fill it
gates. `Canvas.fill` is not `raises` and neither is
`_read_local_bands`, so nothing here raises either: a failure is the
fallback, not an error.

Not a `comptime` value, for two reasons. This Mojo cannot evaluate
either mechanism at compile time -- both `num_physical_cores()` and a
file read fail to interpret -- and even where it could, a comptime
constant describes the machine that *built* the package rather than
the one running it, which is the same bug one step removed as soon as
anything is built in a container or shipped as a binary.
"""

from std.ffi import _Global, external_call
from std.sys import size_of
from std.sys.info import CompilationTarget

# One L3 slice of the AMD Ryzen Threadripper 3970X the thresholds were
# measured on, and what `l3_slice_bytes` returns when the machine will
# not say. See benchmarks/roofline.md for the sweep behind it.
comptime _L3_SLICE_FALLBACK = 16 << 20

# A probe answering outside this range is not describing a cache this
# package can plan around -- 0 from a platform that does not know, or
# a total across sockets -- so the fallback stands instead. Every
# last-level cache in the machines this runs on sits well inside it.
comptime _L3_MIN_PLAUSIBLE = 1 << 20
comptime _L3_MAX_PLAUSIBLE = 1 << 30

# Where Linux names the last-level cache of the first CPU. index3 is
# L3 on every part that has one; a part without L3 has no index3 and
# the fallback stands, which is the right answer for a chip whose
# last level is a small L2 anyway.
comptime _LINUX_L3_PATH = "/sys/devices/system/cpu/cpu0/cache/index3/size"


def _parse_cache_size(text: String) -> Int:
    """The bytes in a sysfs cache size: digits, then an optional K, M
    or G, as in "16384K". Anything else gives 0, which the caller
    reads as "the machine did not say".

    Args:
        text: The file's contents.

    Returns:
        The size in bytes, or 0.
    """
    var n = 0
    var digits = 0
    for b in text.as_bytes():
        var c = Int(b)
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
            digits += 1
        elif c == 75 or c == 107:  # K
            return n * 1024
        elif c == 77 or c == 109:  # M
            return n * 1024 * 1024
        elif c == 71 or c == 103:  # G
            return n * 1024 * 1024 * 1024
        else:
            break
    return n if digits > 0 else 0


def _probe_l3_slice_bytes() -> Int:
    """Ask the operating system for the last-level cache one core
    reaches locally, in bytes, or 0 when it will not say. Called once
    per process through `l3_slice_bytes`.

    Returns:
        The size in bytes, or 0.
    """
    comptime if CompilationTarget.is_macos():
        # `hw.l3cachesize` is 0 on a part with no conventional L3,
        # Apple Silicon among them, where the last level a core reaches
        # on its own is its cluster's L2.
        var size = _sysctl_int("hw.l3cachesize")
        if size <= 0:
            size = _sysctl_int("hw.l2cachesize")
        return size
    comptime if CompilationTarget.is_linux():
        try:
            var f = open(_LINUX_L3_PATH, "r")
            var text = f.read()
            f.close()
            return _parse_cache_size(text)
        except:
            return 0
    return 0


def _sysctl_int(name: StaticString) -> Int:
    """One integer `sysctl` by name, or 0 if the key is absent. The
    call shape is `_macos_version`'s in the standard library.

    Args:
        name: The sysctl key, such as "hw.l3cachesize".

    Returns:
        The value, or 0.
    """
    comptime if not CompilationTarget.is_macos():
        return 0
    var value = Int(0)
    var size = size_of[Int]()
    # `newp` is NULL and `newlen` 0 for a read, passed as integer
    # zeros: a null pointer and 0 occupy the same register on both
    # ABIs this builds for, and this version has no spelling for a
    # null `Pointer` that type-checks in a call this shape.
    var err = external_call["sysctlbyname", Int32](
        name.as_c_string_slice().unsafe_ptr(),
        Pointer(to=value),
        Pointer(to=size),
        Int(0),
        Int(0),
    )
    return 0 if err else value


def _init_l3_slice_bytes() -> Int:
    """The global's initializer: probe once, and keep the fallback
    unless the answer is plausible.

    Returns:
        The size in bytes this process will use.
    """
    var probed = _probe_l3_slice_bytes()
    if probed < _L3_MIN_PLAUSIBLE or probed > _L3_MAX_PLAUSIBLE:
        return _L3_SLICE_FALLBACK
    return probed


comptime _L3_SLICE_GLOBAL = _Global[
    StorageType=Int,
    name="canvas_mojo_l3_slice_bytes",
    init_fn=_init_l3_slice_bytes,
]


def l3_slice_bytes() -> Int:
    """The bytes of last-level cache one core reaches without crossing
    to another complex: the threshold at which a pure-store pass is
    worth banding and a read-heavy one should stop spreading.

    Read from the machine once per process and cached, so this is a
    lookup. Never raises; a machine that will not answer gets the
    constant the thresholds were measured with.

    Returns:
        The size in bytes.
    """
    try:
        return _L3_SLICE_GLOBAL.get_or_create_ptr()[]
    except:
        return _L3_SLICE_FALLBACK

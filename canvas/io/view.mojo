"""A pointer that knows, in a checked build, how far it may reach.

The decoders' hot loops read and write through raw pointers, since a
bounds check per byte is what makes `list[i]` slow, and every index is
argued in bounds by the length checks around the loop. That argument
is what a fuzzer cannot see: a read past a buffer through a raw
pointer does not fault, it returns whatever byte is at that address,
until the address is unmapped. So the loops go through these two
views instead. In the production build a view is the pointer and
nothing else, and every method is the pointer operation it wraps. In
a build with `-D CANVAS_CHECKED_READS` (`pixi run fuzz` passes it), a
view also carries how many elements lie past it, and an access
outside that aborts the process naming the index, which is what turns
a silent read into a finding (#430).

`_ReadView` is over a borrowed `List`; `_WriteView` over a mutable
one, and reads too, since a filter reads the bytes it just wrote.
`offset(k)` is a view over the tail from `k`, which is how a row or a
block gets its own pointer. `load` and `store` are the vector forms,
`W` elements from `i`, for element types that are scalars.

A view is only ever built from a `List` that outlives it; the origin
parameter makes the compiler check that. In the production build the
length field is dead, and the loops compile as they did with the raw
pointer -- `benchmarks/micro_canvas.mojo` has the decoder rows that
pin it.
"""

from std.os import abort
from std.sys import is_defined

comptime CHECKED_READS = is_defined["CANVAS_CHECKED_READS"]()
"""True in a build made with `-D CANVAS_CHECKED_READS`: every view
access is bounds-checked and aborts on a miss. False, the default,
compiles the checks away."""


@always_inline
def _check(i: Int, count: Int, n: Int):
    """Abort unless elements `i` through `i + count - 1` lie inside a
    view of `n`. Compiled away in the production build."""
    comptime if CHECKED_READS:
        if i < 0 or i + count > n:
            abort(
                String(
                    "checked read: elements ",
                    i,
                    " through ",
                    i + count - 1,
                    " of a view holding ",
                    n,
                )
            )


struct _ReadView[T: ImplicitlyCopyable, origin: ImmOrigin](
    ImplicitlyCopyable, Movable
):
    """A read-only pointer into a borrowed `List`; see the module
    docstring."""

    var _p: Pointer[Self.T, Self.origin]
    var _n: Int

    @always_inline
    def __init__(out self, ref[Self.origin] list: List[Self.T]):
        """A view over all of `list`.

        Args:
            list: The list to read through; must outlive the view.
        """
        self._p = list.unsafe_ptr()
        self._n = len(list)

    @always_inline
    def __init__(out self, p: Pointer[Self.T, Self.origin], n: Int):
        """A view over `n` elements from `p`; `offset` builds these.

        Args:
            p: First element.
            n: Elements reachable from it.
        """
        self._p = p
        self._n = n

    @always_inline
    def __getitem__(self, i: Int) -> Self.T:
        _check(i, 1, self._n)
        return self._p[unsafe_offset=i]

    @always_inline
    def offset(self, k: Int) -> Self:
        """The view from element `k` on.

        Args:
            k: Elements to skip; may equal the length, for an empty
                tail.
        """
        _check(k, 0, self._n)
        return Self(self._p.unsafe_offset(k), self._n - k)

    @always_inline
    def load[dt: DType, W: Int](self, i: Int) -> SIMD[dt, W]:
        """`W` scalars from element `i`, for a `T` that is
        `Scalar[dt]`.

        Args:
            i: First element.
        """
        _check(i, W, self._n)
        return (
            self._p.unsafe_offset(i)
            .unsafe_bitcast[Scalar[dt]]()
            .unsafe_load[width=W]()
        )


struct _WriteView[T: ImplicitlyCopyable & Deinitable, origin: MutOrigin](
    ImplicitlyCopyable, Movable
):
    """A pointer into a mutable `List`, read and written through; see
    the module docstring."""

    var _p: Pointer[Self.T, Self.origin]
    var _n: Int

    @always_inline
    def __init__(out self, ref[Self.origin] list: List[Self.T]):
        """A view over all of `list`.

        Args:
            list: The list to write through; must outlive the view.
        """
        self._p = list.unsafe_ptr()
        self._n = len(list)

    @always_inline
    def __init__(out self, p: Pointer[Self.T, Self.origin], n: Int):
        """A view over `n` elements from `p`; `offset` builds these.

        Args:
            p: First element.
            n: Elements reachable from it.
        """
        self._p = p
        self._n = n

    @always_inline
    def __getitem__(self, i: Int) -> Self.T:
        _check(i, 1, self._n)
        return self._p[unsafe_offset=i]

    @always_inline
    def __setitem__(self, i: Int, value: Self.T):
        _check(i, 1, self._n)
        self._p[unsafe_offset=i] = value

    @always_inline
    def offset(self, k: Int) -> Self:
        """The view from element `k` on.

        Args:
            k: Elements to skip; may equal the length, for an empty
                tail.
        """
        _check(k, 0, self._n)
        return Self(self._p.unsafe_offset(k), self._n - k)

    @always_inline
    def load[dt: DType, W: Int](self, i: Int) -> SIMD[dt, W]:
        """`W` scalars from element `i`, for a `T` that is
        `Scalar[dt]`.

        Args:
            i: First element.
        """
        _check(i, W, self._n)
        return (
            self._p.unsafe_offset(i)
            .unsafe_bitcast[Scalar[dt]]()
            .unsafe_load[width=W]()
        )

    @always_inline
    def store[dt: DType, W: Int](self, i: Int, value: SIMD[dt, W]):
        """Write `W` scalars from element `i`, for a `T` that is
        `Scalar[dt]`.

        Args:
            i: First element.
            value: The scalars.
        """
        _check(i, W, self._n)
        self._p.unsafe_offset(i).unsafe_bitcast[Scalar[dt]]().unsafe_store(
            value
        )

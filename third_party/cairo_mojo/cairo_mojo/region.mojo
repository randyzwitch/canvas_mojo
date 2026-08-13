"""Region wrappers for pixel-aligned set operations."""

from std.ffi import c_int
from . import _bindings as bindings
from .cairo_enums import RegionOverlap, Status
from .cairo_types import RectangleInt
from .common import _ensure_success


struct Region(Movable):
    var _ptr: UnsafePointer[bindings.cairo_region_t, MutExternalOrigin]

    def __init__(out self) raises:
        self._ptr = bindings.cairo_region_create()
        _ensure_success(
            bindings.cairo_region_status(self._ptr), "cairo_region_create"
        )

    def __init__(out self, rectangle: RectangleInt) raises:
        var rect_ptr = alloc[bindings.cairo_rectangle_int_t](1)
        rect_ptr[] = rectangle.to_ffi()
        var rect_ro = rect_ptr.unsafe_mut_cast[
            target_mut=False
        ]().unsafe_origin_cast[ImmutExternalOrigin]()
        self._ptr = bindings.cairo_region_create_rectangle(rect_ro)
        rect_ptr.free()
        _ensure_success(
            bindings.cairo_region_status(self._ptr),
            "cairo_region_create_rectangle",
        )

    def __del__(deinit self):
        try:
            bindings.cairo_region_destroy(self._ptr)
        except _:
            pass

    def status(self) raises -> Status:
        return Status._from_ffi(bindings.cairo_region_status(self._ptr))

    def extents(self) raises -> RectangleInt:
        var rect_ptr = alloc[bindings.cairo_rectangle_int_t](1)
        bindings.cairo_region_get_extents(self._ptr, rect_ptr)
        _ensure_success(
            bindings.cairo_region_status(self._ptr), "cairo_region_get_extents"
        )
        var out = RectangleInt.from_ffi(rect_ptr[])
        rect_ptr.free()
        return out

    def num_rectangles(self) raises -> Int:
        return Int(bindings.cairo_region_num_rectangles(self._ptr))

    def get_rectangle(self, index: Int) raises -> RectangleInt:
        var rect_ptr = alloc[bindings.cairo_rectangle_int_t](1)
        bindings.cairo_region_get_rectangle(self._ptr, c_int(index), rect_ptr)
        _ensure_success(
            bindings.cairo_region_status(self._ptr),
            "cairo_region_get_rectangle",
        )
        var out = RectangleInt.from_ffi(rect_ptr[])
        rect_ptr.free()
        return out

    def is_empty(self) raises -> Bool:
        return Int(bindings.cairo_region_is_empty(self._ptr)) != 0

    def contains_point(self, x: Int, y: Int) raises -> Bool:
        return (
            Int(
                bindings.cairo_region_contains_point(
                    self._ptr, c_int(x), c_int(y)
                )
            )
            != 0
        )

    def contains_rectangle(
        self, rectangle: RectangleInt
    ) raises -> RegionOverlap:
        var rect_ptr = alloc[bindings.cairo_rectangle_int_t](1)
        rect_ptr[] = rectangle.to_ffi()
        var rect_ro = rect_ptr.unsafe_mut_cast[
            target_mut=False
        ]().unsafe_origin_cast[ImmutExternalOrigin]()
        var overlap = RegionOverlap._from_ffi(
            bindings.cairo_region_contains_rectangle(self._ptr, rect_ro)
        )
        rect_ptr.free()
        return overlap

    def copy(self) raises -> Self:
        return Self(
            unsafe_raw_ptr=bindings.cairo_region_copy(
                self._ptr.unsafe_mut_cast[
                    target_mut=False
                ]().unsafe_origin_cast[ImmutExternalOrigin]()
            )
        )

    def __init__(
        out self,
        *,
        unsafe_raw_ptr: UnsafePointer[
            bindings.cairo_region_t, MutExternalOrigin
        ],
    ) raises:
        self._ptr = unsafe_raw_ptr
        _ensure_success(bindings.cairo_region_status(self._ptr), "cairo_region")

    def equal(self, ref other: Self) raises -> Bool:
        return (
            Int(
                bindings.cairo_region_equal(
                    self._ptr.unsafe_mut_cast[
                        target_mut=False
                    ]().unsafe_origin_cast[ImmutExternalOrigin](),
                    other._ptr.unsafe_mut_cast[
                        target_mut=False
                    ]().unsafe_origin_cast[ImmutExternalOrigin](),
                )
            )
            != 0
        )

    def translate(self, dx: Int, dy: Int) raises:
        bindings.cairo_region_translate(self._ptr, c_int(dx), c_int(dy))
        _ensure_success(
            bindings.cairo_region_status(self._ptr), "cairo_region_translate"
        )

    def union(self, ref other: Self) raises:
        _ensure_success(
            bindings.cairo_region_union(
                self._ptr,
                other._ptr.unsafe_mut_cast[
                    target_mut=False
                ]().unsafe_origin_cast[ImmutExternalOrigin](),
            ),
            "cairo_region_union",
        )

    def intersect(self, ref other: Self) raises:
        _ensure_success(
            bindings.cairo_region_intersect(
                self._ptr,
                other._ptr.unsafe_mut_cast[
                    target_mut=False
                ]().unsafe_origin_cast[ImmutExternalOrigin](),
            ),
            "cairo_region_intersect",
        )

    def subtract(self, ref other: Self) raises:
        _ensure_success(
            bindings.cairo_region_subtract(
                self._ptr,
                other._ptr.unsafe_mut_cast[
                    target_mut=False
                ]().unsafe_origin_cast[ImmutExternalOrigin](),
            ),
            "cairo_region_subtract",
        )

    def xor(self, ref other: Self) raises:
        _ensure_success(
            bindings.cairo_region_xor(
                self._ptr,
                other._ptr.unsafe_mut_cast[
                    target_mut=False
                ]().unsafe_origin_cast[ImmutExternalOrigin](),
            ),
            "cairo_region_xor",
        )

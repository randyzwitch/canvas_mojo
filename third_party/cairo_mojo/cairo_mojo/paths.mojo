"""Path wrappers for copy/append style Cairo APIs."""

from std.ffi import c_int
from . import _bindings as bindings
from .cairo_enums import PathDataType, Status
from .cairo_types import Point2D
from .common import _ensure_success


@fieldwise_init
struct PathSegment(Copyable, ImplicitlyCopyable, Movable):
    var kind: PathDataType
    var point_count: Int
    var p0: Point2D
    var p1: Point2D
    var p2: Point2D


struct Path(Movable):
    """Owns a copied cairo path object."""

    var _ptr: UnsafePointer[bindings.cairo_path_t, MutExternalOrigin]

    def __init__(
        out self,
        *,
        unsafe_raw_ptr: UnsafePointer[bindings.cairo_path_t, MutExternalOrigin],
    ) raises:
        self._ptr = unsafe_raw_ptr
        _ensure_success(self._ptr[].status, "cairo_copy_path")

    def __del__(deinit self):
        try:
            bindings.cairo_path_destroy(self._ptr)
        except _:
            pass

    def status(self) -> Status:
        return Status._from_ffi(self._ptr[].status)

    def num_data(self) -> Int:
        return Int(self._ptr[].num_data)

    def segments(self) -> List[PathSegment]:
        var out: List[PathSegment] = []
        var i = 0
        while i < self.num_data():
            var header = rebind[bindings.cairo_path_data_t__anon_struct_1](
                self._ptr[].data[i]
            ).copy()
            var kind = PathDataType._from_ffi(header.type)
            var point_count = 0
            var p0 = Point2D(x=0.0, y=0.0)
            var p1 = Point2D(x=0.0, y=0.0)
            var p2 = Point2D(x=0.0, y=0.0)
            if (
                kind._value == PathDataType.MOVE_TO._value
                or kind._value == PathDataType.LINE_TO._value
            ):
                var raw_p0 = rebind[bindings.cairo_path_data_t__anon_struct_2](
                    self._ptr[].data[i + 1]
                ).copy()
                p0 = Point2D(x=Float64(raw_p0.x), y=Float64(raw_p0.y))
                point_count = 1
            elif kind._value == PathDataType.CURVE_TO._value:
                var cp0 = rebind[bindings.cairo_path_data_t__anon_struct_2](
                    self._ptr[].data[i + 1]
                ).copy()
                var cp1 = rebind[bindings.cairo_path_data_t__anon_struct_2](
                    self._ptr[].data[i + 2]
                ).copy()
                var cp2 = rebind[bindings.cairo_path_data_t__anon_struct_2](
                    self._ptr[].data[i + 3]
                ).copy()
                p0 = Point2D(x=Float64(cp0.x), y=Float64(cp0.y))
                p1 = Point2D(x=Float64(cp1.x), y=Float64(cp1.y))
                p2 = Point2D(x=Float64(cp2.x), y=Float64(cp2.y))
                point_count = 3
            out.append(
                PathSegment(
                    kind=kind,
                    point_count=point_count,
                    p0=p0,
                    p1=p1,
                    p2=p2,
                )
            )
            i = i + Int(header.length)
        return out^

    def unsafe_raw_ptr(
        self,
    ) -> UnsafePointer[bindings.cairo_path_t, MutExternalOrigin]:
        return self._ptr

    @staticmethod
    def unsafe_from_owned_raw(
        unsafe_raw_ptr: UnsafePointer[bindings.cairo_path_t, MutExternalOrigin]
    ) raises -> Self:
        return Self(unsafe_raw_ptr=unsafe_raw_ptr)

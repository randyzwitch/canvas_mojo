"""Device wrappers for backend synchronization and status."""

from . import _bindings as bindings
from .cairo_enums import Status
from .common import _ensure_success


struct Device(Movable):
    var _ptr: UnsafePointer[bindings.cairo_device_t, MutExternalOrigin]

    def __init__(
        out self,
        *,
        unsafe_raw_ptr: UnsafePointer[
            bindings.cairo_device_t, MutExternalOrigin
        ],
    ) raises:
        self._ptr = unsafe_raw_ptr
        _ensure_success(
            bindings.cairo_device_status(self._ptr), "cairo_surface_get_device"
        )

    @staticmethod
    def unsafe_from_borrowed(
        unsafe_borrowed_ptr: UnsafePointer[
            bindings.cairo_device_t, MutExternalOrigin
        ]
    ) raises -> Self:
        return Self(
            unsafe_raw_ptr=bindings.cairo_device_reference(unsafe_borrowed_ptr)
        )

    def __del__(deinit self):
        try:
            bindings.cairo_device_destroy(self._ptr)
        except _:
            pass

    def status(self) raises -> Status:
        return Status._from_ffi(bindings.cairo_device_status(self._ptr))

    def acquire(self) raises:
        _ensure_success(
            bindings.cairo_device_acquire(self._ptr), "cairo_device_acquire"
        )

    def release(self) raises:
        bindings.cairo_device_release(self._ptr)
        _ensure_success(
            bindings.cairo_device_status(self._ptr), "cairo_device_release"
        )

    def flush(self) raises:
        bindings.cairo_device_flush(self._ptr)
        _ensure_success(
            bindings.cairo_device_status(self._ptr), "cairo_device_flush"
        )

    def finish(self) raises:
        bindings.cairo_device_finish(self._ptr)
        _ensure_success(
            bindings.cairo_device_status(self._ptr), "cairo_device_finish"
        )


struct ScriptDevice(Movable):
    """Linux-first parity placeholder for script devices."""

    var _device: Device

    def __init__(out self, filename: String) raises:
        _ = filename
        raise Error(
            "ScriptDevice is not available: generated FFI does not expose"
            " cairo_script_create/cairo_script_create_for_stream."
        )

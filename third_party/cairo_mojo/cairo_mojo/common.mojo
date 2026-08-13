"""Internal shared helpers for Cairo status checks and allocations."""

from std.ffi import c_double
from . import _bindings as bindings


def _status_name(status: bindings.cairo_status_t) -> String:
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_SUCCESS.value:
        return "CAIRO_STATUS_SUCCESS"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_NO_MEMORY.value:
        return "CAIRO_STATUS_NO_MEMORY"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_READ_ERROR.value:
        return "CAIRO_STATUS_READ_ERROR"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_WRITE_ERROR.value:
        return "CAIRO_STATUS_WRITE_ERROR"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_FILE_NOT_FOUND.value
    ):
        return "CAIRO_STATUS_FILE_NOT_FOUND"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_PNG_ERROR.value:
        return "CAIRO_STATUS_PNG_ERROR"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_RESTORE.value
    ):
        return "CAIRO_STATUS_INVALID_RESTORE"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_POP_GROUP.value
    ):
        return "CAIRO_STATUS_INVALID_POP_GROUP"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_NO_CURRENT_POINT.value
    ):
        return "CAIRO_STATUS_NO_CURRENT_POINT"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_MATRIX.value
    ):
        return "CAIRO_STATUS_INVALID_MATRIX"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_STATUS.value
    ):
        return "CAIRO_STATUS_INVALID_STATUS"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_NULL_POINTER.value:
        return "CAIRO_STATUS_NULL_POINTER"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_STRING.value
    ):
        return "CAIRO_STATUS_INVALID_STRING"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_PATH_DATA.value
    ):
        return "CAIRO_STATUS_INVALID_PATH_DATA"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_SURFACE_FINISHED.value
    ):
        return "CAIRO_STATUS_SURFACE_FINISHED"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_SURFACE_TYPE_MISMATCH.value
    ):
        return "CAIRO_STATUS_SURFACE_TYPE_MISMATCH"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_PATTERN_TYPE_MISMATCH.value
    ):
        return "CAIRO_STATUS_PATTERN_TYPE_MISMATCH"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_CONTENT.value
    ):
        return "CAIRO_STATUS_INVALID_CONTENT"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_FORMAT.value
    ):
        return "CAIRO_STATUS_INVALID_FORMAT"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_VISUAL.value
    ):
        return "CAIRO_STATUS_INVALID_VISUAL"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_INVALID_DASH.value:
        return "CAIRO_STATUS_INVALID_DASH"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_DSC_COMMENT.value
    ):
        return "CAIRO_STATUS_INVALID_DSC_COMMENT"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_INVALID_INDEX.value:
        return "CAIRO_STATUS_INVALID_INDEX"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_CLIP_NOT_REPRESENTABLE.value
    ):
        return "CAIRO_STATUS_CLIP_NOT_REPRESENTABLE"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_TEMP_FILE_ERROR.value
    ):
        return "CAIRO_STATUS_TEMP_FILE_ERROR"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_STRIDE.value
    ):
        return "CAIRO_STATUS_INVALID_STRIDE"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_FONT_TYPE_MISMATCH.value
    ):
        return "CAIRO_STATUS_FONT_TYPE_MISMATCH"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_USER_FONT_IMMUTABLE.value
    ):
        return "CAIRO_STATUS_USER_FONT_IMMUTABLE"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_USER_FONT_ERROR.value
    ):
        return "CAIRO_STATUS_USER_FONT_ERROR"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_NEGATIVE_COUNT.value
    ):
        return "CAIRO_STATUS_NEGATIVE_COUNT"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_CLUSTERS.value
    ):
        return "CAIRO_STATUS_INVALID_CLUSTERS"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_INVALID_SLANT.value:
        return "CAIRO_STATUS_INVALID_SLANT"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_WEIGHT.value
    ):
        return "CAIRO_STATUS_INVALID_WEIGHT"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_INVALID_SIZE.value:
        return "CAIRO_STATUS_INVALID_SIZE"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_USER_FONT_NOT_IMPLEMENTED.value
    ):
        return "CAIRO_STATUS_USER_FONT_NOT_IMPLEMENTED"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_DEVICE_TYPE_MISMATCH.value
    ):
        return "CAIRO_STATUS_DEVICE_TYPE_MISMATCH"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_DEVICE_ERROR.value:
        return "CAIRO_STATUS_DEVICE_ERROR"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_INVALID_MESH_CONSTRUCTION.value
    ):
        return "CAIRO_STATUS_INVALID_MESH_CONSTRUCTION"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_DEVICE_FINISHED.value
    ):
        return "CAIRO_STATUS_DEVICE_FINISHED"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_JBIG2_GLOBAL_MISSING.value
    ):
        return "CAIRO_STATUS_JBIG2_GLOBAL_MISSING"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_FREETYPE_ERROR.value
    ):
        return "CAIRO_STATUS_FREETYPE_ERROR"
    if (
        status.value
        == bindings.cairo_status_t.CAIRO_STATUS_WIN32_GDI_ERROR.value
    ):
        return "CAIRO_STATUS_WIN32_GDI_ERROR"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_TAG_ERROR.value:
        return "CAIRO_STATUS_TAG_ERROR"
    if status.value == bindings.cairo_status_t.CAIRO_STATUS_LAST_STATUS.value:
        return "CAIRO_STATUS_LAST_STATUS"
    return "CAIRO_STATUS_UNKNOWN"


def _ensure_success(status: bindings.cairo_status_t, operation: String) raises:
    if status.value != bindings.cairo_status_t.CAIRO_STATUS_SUCCESS.value:
        var status_text_ptr = bindings.cairo_status_to_string(status)
        var status_text = String(status_text_ptr)
        raise Error(
            "{} failed with {} (code {}, detail: {})".format(
                operation,
                _status_name(status),
                status.value,
                status_text,
            )
        )


def _alloc_double_pair(
    mut x_ptr: UnsafePointer[c_double, MutExternalOrigin],
    mut y_ptr: UnsafePointer[c_double, MutExternalOrigin],
):
    x_ptr = alloc[c_double](1)
    y_ptr = alloc[c_double](1)


def _alloc_double_quad(
    mut x1_ptr: UnsafePointer[c_double, MutExternalOrigin],
    mut y1_ptr: UnsafePointer[c_double, MutExternalOrigin],
    mut x2_ptr: UnsafePointer[c_double, MutExternalOrigin],
    mut y2_ptr: UnsafePointer[c_double, MutExternalOrigin],
):
    x1_ptr = alloc[c_double](1)
    y1_ptr = alloc[c_double](1)
    x2_ptr = alloc[c_double](1)
    y2_ptr = alloc[c_double](1)

"""Minimal FreeType FFI -- loads a font file (typically one
`font_discovery.resolve_font_file` just resolved) into a real `FT_Face`
handle. Real font-file parsing (TrueType/CFF/etc., whichever the file
actually is) is FreeType's own job here, not something this package
re-implements -- see `font_discovery.mojo`'s own docstring for the
same "link directly against the mature C library" reasoning (FreeType
License, BSD-style + credit clause, or GPLv2 as an alternative --
either way permissive enough for a direct FFI dependency the same
category as libcairo/libfontconfig already are).

This module only *loads* a face -- it doesn't read glyph outlines,
metrics, or do any hinting. `FreeTypeFace` exposes the raw `FT_Face`
pointer (`unsafe_raw_face_ptr`) specifically so a caller can hand it to
something else that does -- today that's `canvas_mojo/text.mojo`,
which passes it to Cairo's own `cairo_ft_font_face_create_for_ft_face`
so Cairo renders using a face this package resolved and loaded itself,
bypassing Cairo's internal fontconfig lookup. A future native glyph-
outline/metrics/hinting module (reading `FT_Face`'s own glyph slot
after `FT_Load_Glyph`) would use this same loader.

Deliberately has zero imports from third_party/cairo_mojo -- see
font_discovery.mojo's own docstring for why that independence matters
here too. `_FT_FaceRec`/`_FT_LibraryRec` are opaque local duplicates of
concepts cairo_mojo's own `_bindings.mojo` also declares (as
`FT_FaceRec_`) for its `cairo_ft_*` bindings -- callers that need to
hand this module's `FT_Face` pointer to a cairo_mojo function do a
pointer bitcast at that call site (both are zero-field marker types
representing the same underlying C pointer), not an import from here.
"""

from std.ffi import OwnedDLHandle, RTLD, c_char, c_int, c_long, c_uint
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.subprocess import run
from std.sys.info import CompilationTarget

comptime _FREETYPE_LIB_ENV_VAR = "FREETYPE_LIB"


@fieldwise_init
struct _FT_FaceRec(Copyable, Movable):
    pass


@fieldwise_init
struct _FT_LibraryRec(Copyable, Movable):
    pass


# --- Runtime loader --------------------------------------------------------
# Same shape as font_discovery.mojo's own loader (itself modeled on
# third_party/cairo_mojo/cairo_mojo/cairo_runtime.mojo) -- duplicated a
# second time rather than factored into a shared helper, to keep this
# change reviewable; consolidating the two (and cairo_runtime.mojo's
# own copy, vendored and out of reach anyway) into one generic loader
# is a reasonable follow-up, not done here.


def _append_unique(mut candidates: List[String], value: String):
    var trimmed = String(value.strip())
    if trimmed.byte_length() == 0:
        return
    if trimmed not in candidates:
        candidates.append(trimmed)


def _append_lines(mut candidates: List[String], output: String):
    for line in output.split("\n"):
        _append_unique(candidates, String(line))


def _append_linux_ldconfig_hints(mut candidates: List[String]):
    try:
        var output = run(
            "ldconfig -p 2>/dev/null | awk '/libfreetype\\.so/ { if (NF >= 1)"
            " print $1; if (NF >= 4) print $NF }'"
        )
        _append_lines(candidates, output)
    except:
        pass


def _append_macos_homebrew_hints(mut candidates: List[String]):
    try:
        var prefix = String(run("brew --prefix freetype 2>/dev/null").strip())
        if prefix.byte_length() > 0:
            _append_unique(candidates, String(prefix, "/lib/libfreetype.6.dylib"))
            _append_unique(candidates, String(prefix, "/lib/libfreetype.dylib"))
    except:
        pass


def _append_pkg_config_hints(mut candidates: List[String], is_macos: Bool):
    try:
        var output = run(
            "pkg-config --libs-only-L freetype2 2>/dev/null | tr ' ' '\\n' |"
            " sed -n 's/^-L//p'"
        )
        for directory_slice in output.split("\n"):
            var directory = String(directory_slice.strip())
            if directory.byte_length() == 0:
                continue
            if is_macos:
                _append_unique(candidates, String(directory, "/libfreetype.6.dylib"))
                _append_unique(candidates, String(directory, "/libfreetype.dylib"))
            else:
                _append_unique(candidates, String(directory, "/libfreetype.so.6"))
                _append_unique(candidates, String(directory, "/libfreetype.so"))
    except:
        pass


def _discover_freetype_candidates() raises -> List[String]:
    var candidates: List[String] = []
    _append_unique(candidates, getenv(_FREETYPE_LIB_ENV_VAR))

    if CompilationTarget.is_linux():
        _append_unique(candidates, "libfreetype.so.6")
        _append_unique(candidates, "libfreetype.so")
        _append_linux_ldconfig_hints(candidates)
        _append_pkg_config_hints(candidates, False)
    elif CompilationTarget.is_macos():
        _append_unique(candidates, "libfreetype.6.dylib")
        _append_unique(candidates, "libfreetype.dylib")
        _append_macos_homebrew_hints(candidates)
        _append_pkg_config_hints(candidates, True)
    else:
        _append_unique(candidates, "libfreetype.so.6")
        _append_unique(candidates, "libfreetype.so")
        _append_pkg_config_hints(candidates, False)

    return candidates^


def _open_freetype_library() raises -> OwnedDLHandle:
    var candidates = _discover_freetype_candidates()
    var errors: List[String] = []
    for candidate in candidates:
        try:
            return OwnedDLHandle(candidate, RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE)
        except err:
            errors.append(String(candidate, " -> ", String(err)))

    var message = String(
        "Unable to load libfreetype. Tried candidates discovered from ",
        _FREETYPE_LIB_ENV_VAR,
        ", platform defaults, and optional platform hints.",
    )
    for error_text in errors:
        message = String(message, "\n - ", error_text)
    raise Error(message)


def _c_string(text: String) -> Pointer[c_char, MutUntrackedOrigin]:
    # Duplicated from font_discovery.mojo's own _c_string -- same
    # "stay independent, don't import across these small FFI modules
    # just to save a few lines" reasoning as font_discovery.mojo's own
    # docstring gives for duplicating it from canvas_mojo/text.mojo.
    var bytes = text.as_bytes()
    var n = len(bytes)
    var buf = unsafe_alloc[c_char](n + 1)
    for i in range(n):
        buf[unsafe_offset=i] = c_char(bytes[i])
    buf[unsafe_offset=n] = c_char(0)
    return buf


def _imm(ptr: Pointer[c_char, MutUntrackedOrigin]) -> Pointer[c_char, ImmUntrackedOrigin]:
    return ptr.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[ImmUntrackedOrigin]()


struct FreeTypeFace(Movable):
    """Owns one `FT_Library` + `FT_Face` pair for a single font file,
    both released together in `__del__` (`FT_Done_Face` then
    `FT_Done_FreeType` -- FreeType's own required teardown order).

    A fresh `FT_Library` per face, not a shared/global one -- the same
    "no global handle available yet" constraint
    third_party/cairo_mojo/cairo_mojo/cairo_runtime.mojo's own docstring
    already documents for Cairo, not a new limitation this module
    introduces.
    """

    var _library: Pointer[_FT_LibraryRec, MutUntrackedOrigin]
    var _face: Pointer[_FT_FaceRec, MutUntrackedOrigin]

    def __init__(out self, file_path: String) raises:
        var handle = _open_freetype_library()

        var lib_ptr_out = unsafe_alloc[Pointer[_FT_LibraryRec, MutUntrackedOrigin]](1)
        var init_err = handle.call[
            "FT_Init_FreeType",
            c_int,
            Pointer[Pointer[_FT_LibraryRec, MutUntrackedOrigin], MutUntrackedOrigin],
        ](lib_ptr_out)
        if Int(init_err) != 0:
            lib_ptr_out.unsafe_free()
            raise Error(String("FT_Init_FreeType failed with error code ", Int(init_err)))
        var library = lib_ptr_out[]
        lib_ptr_out.unsafe_free()

        var path_buf = _c_string(file_path)
        var face_ptr_out = unsafe_alloc[Pointer[_FT_FaceRec, MutUntrackedOrigin]](1)
        var new_face_err = handle.call[
            "FT_New_Face",
            c_int,
            Pointer[_FT_LibraryRec, MutUntrackedOrigin],
            Pointer[c_char, ImmUntrackedOrigin],
            c_long,
            Pointer[Pointer[_FT_FaceRec, MutUntrackedOrigin], MutUntrackedOrigin],
        ](library, _imm(path_buf), 0, face_ptr_out)
        path_buf.unsafe_free()
        if Int(new_face_err) != 0:
            face_ptr_out.unsafe_free()
            _ = handle.call[
                "FT_Done_FreeType", c_int, Pointer[_FT_LibraryRec, MutUntrackedOrigin]
            ](library)
            raise Error(
                String(
                    "FT_New_Face failed to load '",
                    file_path,
                    "' with error code ",
                    Int(new_face_err),
                )
            )

        self._library = library
        self._face = face_ptr_out[]
        face_ptr_out.unsafe_free()

    def __deinit__(deinit self):
        try:
            var handle = _open_freetype_library()
            _ = handle.call["FT_Done_Face", c_int, Pointer[_FT_FaceRec, MutUntrackedOrigin]](
                self._face
            )
            _ = handle.call[
                "FT_Done_FreeType", c_int, Pointer[_FT_LibraryRec, MutUntrackedOrigin]
            ](self._library)
        except:
            pass

    def set_pixel_size(self, pixel_size: Int) raises:
        """Set this face's own active rasterization size via
        `FT_Set_Pixel_Sizes`, required before handing it to Cairo's
        `cairo_ft_font_face_create_for_ft_face`.

        Confirmed necessary via probe, not assumed: without this, a
        face loaded straight from `FT_New_Face` renders glyphs at
        whatever small size FreeType defaults an unsized face to
        (~20px tall regardless of the requested point size), while
        Cairo's own *measurement* (`text_extents`) still reports the
        correctly-scaled size -- text_extents and the actual rendered
        ink silently disagreeing, not merely both being wrong the same
        way. This is exactly the gap `cairo_select_font_face`'s
        internal fontconfig/FreeType path doesn't have, since Cairo
        sets an active size on any face *it* creates internally before
        ever rendering with it.
        """
        var handle = _open_freetype_library()
        var err = handle.call[
            "FT_Set_Pixel_Sizes",
            c_int,
            Pointer[_FT_FaceRec, MutUntrackedOrigin],
            c_uint,
            c_uint,
        ](self._face, c_uint(0), c_uint(pixel_size))
        if Int(err) != 0:
            raise Error(String("FT_Set_Pixel_Sizes failed with error code ", Int(err)))

    def unsafe_raw_face_ptr(self) -> Pointer[_FT_FaceRec, MutUntrackedOrigin]:
        """Expose the raw `FT_Face` pointer for a caller (e.g.
        canvas_mojo/text.mojo) to hand to something else -- Cairo's own
        `cairo_ft_font_face_create_for_ft_face`, or a future native
        glyph-outline reader. Borrowed, not transferred: `self` still
        owns and will free it in `__del__`, so the caller must keep
        `self` alive for as long as anything holds this pointer.
        """
        return self._face

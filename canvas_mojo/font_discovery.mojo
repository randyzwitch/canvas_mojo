"""Font discovery via libfontconfig -- resolves a family/slant/weight
request to an actual font file path on disk, the same job Cairo's own
`select_font_face` currently does invisibly (via fontconfig underneath
it) in `canvas_mojo/text.mojo`. This is "job 1" of a 4-job breakdown
for eventually removing the Cairo dependency: font discovery (this
module, via fontconfig), glyph resolution & metrics + hinting (both
FreeType, not yet built), and rasterization (already covered natively
by this package's own `fill_path_aa` -- see `path.mojo`).

Deliberately linked directly against libfontconfig rather than
translated from its source: fontconfig is MIT-licensed, a small,
stable, mature C API, and the actual system font database (install
locations, aliasing, per-language fallback) is its own mature,
continuously-updated subsystem, not something worth re-deriving. This
module never imports anything from
`third_party/cairo_mojo` or `canvas_mojo.text` -- the entire point is
to be usable, and eventually keep working, independent of Cairo. That
independence is also why `FontSlant`/`FontWeight` and the raw C-string
helpers below are small local duplicates of concepts that already
exist elsewhere in this codebase (`cairo_mojo`'s own `FontSlant`/
`FontWeight`, `canvas_mojo/text.mojo`'s own `_c_string`) rather than
imports of them -- importing either would pull in `cairo_mojo`'s own
top-level dependency chain transitively, the same "a struct's method
surface (and whatever it imports) resolves eagerly, not lazily"
lesson `draw_target.mojo`'s own docstring documents for `DrawTarget`
excluding `draw_text`.

This module resolves a font *file*, nothing more -- it does not parse
that file, measure text, hint, or rasterize anything. `canvas_mojo.text`
still does all of that via Cairo today; this is a standalone building
block, not yet wired into `draw_text`/`measure_text`.
"""

from std.ffi import OwnedDLHandle, RTLD, c_char, c_int, c_uint
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.subprocess import run
from std.sys.info import CompilationTarget

comptime _FONTCONFIG_LIB_ENV_VAR = "FONTCONFIG_LIB"


struct FontSlant(Copyable, ImplicitlyCopyable, Movable):
    """Mirrors `cairo_mojo.FontSlant`'s own three values -- a local,
    cairo-free duplicate (see this module's own docstring for why).
    """

    var _value: Int

    comptime NORMAL = Self(0)
    comptime ITALIC = Self(1)
    comptime OBLIQUE = Self(2)

    def __init__(out self, value: Int):
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value


struct FontWeight(Copyable, ImplicitlyCopyable, Movable):
    """Mirrors `cairo_mojo.FontWeight`'s own two values -- a local,
    cairo-free duplicate (see this module's own docstring for why).
    """

    var _value: Int

    comptime NORMAL = Self(0)
    comptime BOLD = Self(1)

    def __init__(out self, value: Int):
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value


# fontconfig's own <fontconfig/fontconfig.h> integer scale for the
# "slant"/"weight" pattern properties -- not Cairo's enum values, a
# separate, fontconfig-specific numbering fontconfig itself defines
# and documents. FC_WEIGHT_REGULAR/FC_WEIGHT_BOLD (not the 100-900
# OpenType-style scale fontconfig also supports via FcWeightFromOpenType)
# since only NORMAL/BOLD are exposed here, matching what
# canvas_mojo/text.mojo's own FontWeight currently offers.
comptime _FC_SLANT_ROMAN = c_int(0)
comptime _FC_SLANT_ITALIC = c_int(100)
comptime _FC_SLANT_OBLIQUE = c_int(110)

comptime _FC_WEIGHT_REGULAR = c_int(80)
comptime _FC_WEIGHT_BOLD = c_int(200)

# FcMatchKind -- only FcMatchPattern (0) is used here (FcConfigSubstitute's
# own "substitute for a pattern being matched against available fonts"
# mode, the same mode Cairo's own toy API uses internally).
comptime _FC_MATCH_PATTERN = c_int(0)

# FcResult -- only FcResultMatch (0) is checked; every other value
# (NoMatch/TypeMismatch/NoId/OutOfMemory) is treated as failure alike,
# since none of them leave a usable "file" property to read.
comptime _FC_RESULT_MATCH = c_int(0)


def _fc_slant_value(slant: FontSlant) -> c_int:
    if slant == FontSlant.ITALIC:
        return _FC_SLANT_ITALIC
    if slant == FontSlant.OBLIQUE:
        return _FC_SLANT_OBLIQUE
    return _FC_SLANT_ROMAN


def _fc_weight_value(weight: FontWeight) -> c_int:
    if weight == FontWeight.BOLD:
        return _FC_WEIGHT_BOLD
    return _FC_WEIGHT_REGULAR


# --- Runtime loader ------------------------------------------------------
# Same discovery shape as third_party/cairo_mojo/cairo_mojo/cairo_runtime.mojo
# (explicit env var override, then canonical names, then optional
# ldconfig/Homebrew/pkg-config hints) -- deliberately not imported from
# there (see this module's own docstring: no cairo_mojo dependency,
# anywhere, ever, in this file).


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
            "ldconfig -p 2>/dev/null | awk '/libfontconfig\\.so/ { if (NF >="
            " 1) print $1; if (NF >= 4) print $NF }'"
        )
        _append_lines(candidates, output)
    except:
        pass


def _append_macos_homebrew_hints(mut candidates: List[String]):
    try:
        var prefix = String(run("brew --prefix fontconfig 2>/dev/null").strip())
        if prefix.byte_length() > 0:
            _append_unique(candidates, String(prefix, "/lib/libfontconfig.1.dylib"))
            _append_unique(candidates, String(prefix, "/lib/libfontconfig.dylib"))
    except:
        pass


def _append_pkg_config_hints(mut candidates: List[String], is_macos: Bool):
    try:
        var output = run(
            "pkg-config --libs-only-L fontconfig 2>/dev/null | tr ' ' '\\n' |"
            " sed -n 's/^-L//p'"
        )
        for directory_slice in output.split("\n"):
            var directory = String(directory_slice.strip())
            if directory.byte_length() == 0:
                continue
            if is_macos:
                _append_unique(candidates, String(directory, "/libfontconfig.1.dylib"))
                _append_unique(candidates, String(directory, "/libfontconfig.dylib"))
            else:
                _append_unique(candidates, String(directory, "/libfontconfig.so.1"))
                _append_unique(candidates, String(directory, "/libfontconfig.so"))
    except:
        pass


def _discover_fontconfig_candidates() raises -> List[String]:
    var candidates: List[String] = []
    _append_unique(candidates, getenv(_FONTCONFIG_LIB_ENV_VAR))

    if CompilationTarget.is_linux():
        _append_unique(candidates, "libfontconfig.so.1")
        _append_unique(candidates, "libfontconfig.so")
        _append_linux_ldconfig_hints(candidates)
        _append_pkg_config_hints(candidates, False)
    elif CompilationTarget.is_macos():
        _append_unique(candidates, "libfontconfig.1.dylib")
        _append_unique(candidates, "libfontconfig.dylib")
        _append_macos_homebrew_hints(candidates)
        _append_pkg_config_hints(candidates, True)
    else:
        _append_unique(candidates, "libfontconfig.so.1")
        _append_unique(candidates, "libfontconfig.so")
        _append_pkg_config_hints(candidates, False)

    return candidates^


def _open_fontconfig_library() raises -> OwnedDLHandle:
    var candidates = _discover_fontconfig_candidates()
    var errors: List[String] = []
    for candidate in candidates:
        try:
            return OwnedDLHandle(candidate, RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE)
        except err:
            errors.append(String(candidate, " -> ", String(err)))

    var message = String(
        "Unable to load libfontconfig. Tried candidates discovered from ",
        _FONTCONFIG_LIB_ENV_VAR,
        ", platform defaults, and optional platform hints.",
    )
    for error_text in errors:
        message = String(message, "\n - ", error_text)
    raise Error(message)


# --- Raw C-string helpers -------------------------------------------------
# Duplicated from canvas_mojo/text.mojo's own _c_string, deliberately --
# see this module's own docstring for why importing it instead isn't an
# option. Same manually-built-NUL-terminated-buffer approach that
# module's own docstring documents working around a real, root-caused
# Mojo/cairo_mojo marshaling bug for -- applied here too on the "don't
# trust a shortcut that's already bitten this codebase once" principle,
# not because this specific bug is confirmed present in fontconfig calls.


def _c_string(text: String) -> Pointer[c_char, MutUntrackedOrigin]:
    var bytes = text.as_bytes()
    var n = len(bytes)
    var buf = unsafe_alloc[c_char](n + 1)
    for i in range(n):
        buf[unsafe_offset=i] = c_char(bytes[i])
    buf[unsafe_offset=n] = c_char(0)
    return buf


def _string_from_c_string(ptr: Pointer[c_char, ImmUntrackedOrigin]) -> String:
    """Read a NUL-terminated C string back into a Mojo String.

    Confirmed necessary, not assumed: `String(ptr)` for a raw
    `Pointer[c_char, ImmUntrackedOrigin]` does NOT decode the
    pointee bytes in this Mojo version -- it formats the pointer's own
    address instead. Verified against cairo_mojo's own
    `cairo_version_string()` (a real, already-shipping `char*`-
    returning binding) printing a bare hex address, not a version
    string, before writing this byte-walking replacement.
    """
    var out = String()
    var i = 0
    while True:
        var b = UInt8(ptr[unsafe_offset=i])
        if b == 0:
            break
        out += chr(Int(b))
        i += 1
    return out


def _imm(ptr: Pointer[c_char, MutUntrackedOrigin]) -> Pointer[c_char, ImmUntrackedOrigin]:
    return ptr.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[ImmUntrackedOrigin]()


# --- Opaque fontconfig types -----------------------------------------------
# `FcConfig`/`FcPattern` are incomplete C structs in fontconfig's own
# header -- used only as pointer targets, the same convention
# third_party/cairo_mojo/cairo_mojo/_bindings.mojo uses for Cairo's own
# opaque types (`_cairo`, `_cairo_surface`, ...).
@fieldwise_init
struct _FcConfig(Copyable, Movable):
    pass


@fieldwise_init
struct _FcPattern(Copyable, Movable):
    pass


@fieldwise_init
struct _FcCharSet(Copyable, Movable):
    pass


def resolve_font_file(
    family: String,
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
) raises -> String:
    """Resolve `family`/`slant`/`weight` to an absolute font file path,
    via fontconfig's own family-name matching/aliasing/fallback --
    the same resolution Cairo's `select_font_face` does internally.

    Raises if libfontconfig can't be loaded, or if fontconfig itself
    reports no match (FcResultMatch is the only success code accepted --
    fontconfig's own generic "sans-serif"/"serif"/"monospace" aliases
    and per-system default-substitution mean an actual "no match at
    all" is rare in practice, but not impossible on a font-less
    system).
    """
    return _resolve_font_file_impl(family, slant, weight, -1)


def resolve_font_file_for_char(
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    codepoint: Int,
) raises -> String:
    """Like `resolve_font_file`, but also constrains the match to a
    font that actually contains `codepoint` (via `FC_CHARSET`) -- the
    font-fallback lookup `canvas_mojo/text.mojo` uses when the
    caller's own requested family lacks a glyph for some character
    (e.g. CJK text requested under a Latin-only "Sans" family):
    fontconfig's own family/generic-alias fallback chain (the same
    system-wide configuration real desktop text stacks already rely
    on) picks a *different* font that actually has the glyph, if one
    is installed.

    Verified against real, contrasting behavior, not assumed from the
    API alone: on a system where the "Ubuntu" font lacks a glyph (a
    snowman symbol) that "DejaVu Sans" happens to have,
    `resolve_font_file_for_char("Ubuntu", ..., snowman)` returns
    DejaVu Sans's file, while the identical call for a character
    "Ubuntu" *does* have (a plain "A") returns Ubuntu's own file
    unchanged -- real, contrasting fallback, not just "always returns
    the same thing regardless of the charset constraint."

    If no installed font has `codepoint` at all, fontconfig's own
    default-substitution still returns its best-effort closest match
    (confirmed directly: requesting a font for a CJK character with no
    CJK font installed anywhere on the system still returns a real
    font file, just one that -- like every other installed font --
    doesn't actually contain that glyph). Callers that need to
    distinguish "found a font with the glyph" from "fontconfig gave up
    and returned its best guess" should check the *result* (e.g. via
    `glyph_outline.has_glyph`) against whatever this returns, not
    trust the return value alone.
    """
    return _resolve_font_file_impl(family, slant, weight, codepoint)


def _resolve_font_file_impl(
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    char_constraint: Int,
) raises -> String:
    """Shared implementation for `resolve_font_file`/
    `resolve_font_file_for_char` -- `char_constraint == -1` means "no
    charset constraint" (plain family/slant/weight matching); any
    other value adds an `FC_CHARSET` containing exactly that one
    codepoint to the pattern before matching.
    """
    var handle = _open_fontconfig_library()

    var init_ok = handle.call["FcInit", c_int]()
    if Int(init_ok) == 0:
        raise Error("FcInit failed")

    var config = handle.call["FcConfigGetCurrent", Pointer[_FcConfig, MutUntrackedOrigin]]()

    var pattern = handle.call["FcPatternCreate", Pointer[_FcPattern, MutUntrackedOrigin]]()

    var family_obj = _c_string("family")
    var family_val = _c_string(family)
    _ = handle.call[
        "FcPatternAddString",
        c_int,
        Pointer[_FcPattern, MutUntrackedOrigin],
        Pointer[c_char, ImmUntrackedOrigin],
        Pointer[UInt8, ImmUntrackedOrigin],
    ](pattern, _imm(family_obj), _imm(family_val).unsafe_bitcast[UInt8]())
    family_obj.unsafe_free()
    family_val.unsafe_free()

    var slant_obj = _c_string("slant")
    _ = handle.call[
        "FcPatternAddInteger",
        c_int,
        Pointer[_FcPattern, MutUntrackedOrigin],
        Pointer[c_char, ImmUntrackedOrigin],
        c_int,
    ](pattern, _imm(slant_obj), _fc_slant_value(slant))
    slant_obj.unsafe_free()

    var weight_obj = _c_string("weight")
    _ = handle.call[
        "FcPatternAddInteger",
        c_int,
        Pointer[_FcPattern, MutUntrackedOrigin],
        Pointer[c_char, ImmUntrackedOrigin],
        c_int,
    ](pattern, _imm(weight_obj), _fc_weight_value(weight))
    weight_obj.unsafe_free()

    # Always create a real FcCharSet (cheap) rather than a conditionally-
    # initialized pointer variable -- only *attaching* it to the pattern
    # is conditional, sidestepping any need for a placeholder/null value
    # for the "no constraint" path (constructing a null pointer to a
    # custom opaque struct type isn't straightforward here -- see
    # freetype_face.mojo's own history with this exact issue).
    var have_charset = char_constraint != -1
    var charset = handle.call["FcCharSetCreate", Pointer[_FcCharSet, MutUntrackedOrigin]]()
    if have_charset:
        _ = handle.call[
            "FcCharSetAddChar", c_int, Pointer[_FcCharSet, MutUntrackedOrigin], c_uint
        ](charset, c_uint(char_constraint))
        var charset_obj = _c_string("charset")
        _ = handle.call[
            "FcPatternAddCharSet",
            c_int,
            Pointer[_FcPattern, MutUntrackedOrigin],
            Pointer[c_char, ImmUntrackedOrigin],
            Pointer[_FcCharSet, MutUntrackedOrigin],
        ](pattern, _imm(charset_obj), charset)
        charset_obj.unsafe_free()

    handle.call["FcDefaultSubstitute", NoneType, Pointer[_FcPattern, MutUntrackedOrigin]](pattern)

    _ = handle.call[
        "FcConfigSubstitute",
        c_int,
        Pointer[_FcConfig, MutUntrackedOrigin],
        Pointer[_FcPattern, MutUntrackedOrigin],
        c_int,
    ](config, pattern, _FC_MATCH_PATTERN)

    var result_code = unsafe_alloc[c_int](1)
    var matched = handle.call[
        "FcFontMatch",
        Pointer[_FcPattern, MutUntrackedOrigin],
        Pointer[_FcConfig, MutUntrackedOrigin],
        Pointer[_FcPattern, MutUntrackedOrigin],
        Pointer[c_int, MutUntrackedOrigin],
    ](config, pattern, result_code)
    var match_result = result_code[]
    result_code.unsafe_free()

    handle.call["FcPatternDestroy", NoneType, Pointer[_FcPattern, MutUntrackedOrigin]](pattern)
    handle.call["FcCharSetDestroy", NoneType, Pointer[_FcCharSet, MutUntrackedOrigin]](charset)

    if Int(match_result) != Int(_FC_RESULT_MATCH):
        raise Error(
            String("fontconfig found no font matching family '", family, "'")
        )

    var file_obj = _c_string("file")
    var file_ptr_out = unsafe_alloc[Pointer[c_char, ImmUntrackedOrigin]](1)
    var get_result = handle.call[
        "FcPatternGetString",
        c_int,
        Pointer[_FcPattern, MutUntrackedOrigin],
        Pointer[c_char, ImmUntrackedOrigin],
        c_int,
        Pointer[Pointer[c_char, ImmUntrackedOrigin], MutUntrackedOrigin],
    ](matched, _imm(file_obj), 0, file_ptr_out)
    file_obj.unsafe_free()

    var resolved_path = String()
    if Int(get_result) == Int(_FC_RESULT_MATCH):
        resolved_path = _string_from_c_string(file_ptr_out[])
    file_ptr_out.unsafe_free()

    handle.call["FcPatternDestroy", NoneType, Pointer[_FcPattern, MutUntrackedOrigin]](matched)

    if resolved_path == "":
        raise Error(
            String(
                "fontconfig matched family '",
                family,
                "' but reported no 'file' property",
            )
        )
    return resolved_path

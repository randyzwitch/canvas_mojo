"""Font discovery via libfontconfig -- resolves a family/slant/weight
request to an actual font file path on disk. This is one of three jobs
text rendering needs: font discovery (this module, via fontconfig),
glyph resolution & metrics (native, `ttf.mojo`), and rasterization
(also native, `fill_path_aa` -- see `path.mojo`).

Deliberately linked directly against libfontconfig rather than
translated from its source: fontconfig is MIT-licensed, a small,
stable, mature C API, and the actual system font database (install
locations, aliasing, per-language fallback) is its own mature,
continuously-updated subsystem, not something worth re-deriving.

This module imports nothing from `canvas_mojo.text`, and that
independence is why `FontSlant`/`FontWeight` and the raw C-string
helpers below live here rather than being imported from a module that
uses them -- a struct's method surface (and whatever it imports)
resolves eagerly, not lazily, the same lesson `canvas_mojo/vector/
draw_target.mojo` documents for `DrawTarget` excluding
`draw_text`.

This module resolves a font *file*, nothing more -- it does not parse
that file, measure text, hint, or rasterize anything. `render.mojo`
drives it, together with `ttf.mojo` and `fill_path_aa`, to actually
draw text.
"""

from std.ffi import OwnedDLHandle, RTLD, c_char, c_int, c_uint
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.subprocess import run
from std.sys.info import CompilationTarget

comptime _FONTCONFIG_LIB_ENV_VAR = "FONTCONFIG_LIB"


struct FontSlant(Copyable, ImplicitlyCopyable, Movable):
    """A font's upright/italic/oblique style, as requested of
    fontconfig. Defined here to keep this module independent of
    `canvas_mojo.text`; `render.mojo` re-exports it.
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
    """A font's normal/bold weight, as requested of fontconfig, defined
    here for the same reason FontSlant is.
    """

    var _value: Int

    comptime NORMAL = Self(0)
    comptime BOLD = Self(1)

    def __init__(out self, value: Int):
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value


def _fc_slant_value(slant: FontSlant) -> c_int:
    # fontconfig's <fontconfig/fontconfig.h> integer scale for the
    # "slant" pattern property -- its own numbering, unrelated to this
    # module's FontSlant.
    comptime _FC_SLANT_ROMAN = c_int(0)
    comptime _FC_SLANT_ITALIC = c_int(100)
    comptime _FC_SLANT_OBLIQUE = c_int(110)

    if slant == FontSlant.ITALIC:
        return _FC_SLANT_ITALIC
    if slant == FontSlant.OBLIQUE:
        return _FC_SLANT_OBLIQUE
    return _FC_SLANT_ROMAN


def _fc_weight_value(weight: FontWeight) -> c_int:
    # fontconfig's integer scale for the "weight" pattern property --
    # FC_WEIGHT_REGULAR/FC_WEIGHT_BOLD, not the 100-900 OpenType scale
    # fontconfig also accepts via FcWeightFromOpenType, since only
    # NORMAL/BOLD are exposed.
    comptime _FC_WEIGHT_REGULAR = c_int(80)
    comptime _FC_WEIGHT_BOLD = c_int(200)

    if weight == FontWeight.BOLD:
        return _FC_WEIGHT_BOLD
    return _FC_WEIGHT_REGULAR


# --- Runtime loader ------------------------------------------------------
# Explicit env var override, then each platform's canonical library
# names, then -- only if all of those fail to dlopen -- optional
# ldconfig/Homebrew/pkg-config hints. See _cheap_fontconfig_candidates
# and _expensive_fontconfig_hint_candidates below for the split.


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
            _append_unique(
                candidates, String(prefix, "/lib/libfontconfig.1.dylib")
            )
            _append_unique(
                candidates, String(prefix, "/lib/libfontconfig.dylib")
            )
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
                _append_unique(
                    candidates, String(directory, "/libfontconfig.1.dylib")
                )
                _append_unique(
                    candidates, String(directory, "/libfontconfig.dylib")
                )
            else:
                _append_unique(
                    candidates, String(directory, "/libfontconfig.so.1")
                )
                _append_unique(
                    candidates, String(directory, "/libfontconfig.so")
                )
    except:
        pass


def _cheap_fontconfig_candidates() -> List[String]:
    """The zero-subprocess candidates: an explicit env var override,
    then each platform's canonical library name, which almost every
    real installation already resolves through the dynamic linker's
    search path (ld.so.cache on Linux, dyld on macOS).
    _open_fontconfig_library tries these before paying for
    _expensive_fontconfig_hint_candidates' subprocess spawns. Measured:
    a raw dlopen of "libfontconfig.so.1" ~12ms, against ~17ms for the
    ldconfig hint and ~28ms for pkg-config -- ~45ms of subprocess cost
    a normal installation skips.
    """
    var candidates: List[String] = []
    _append_unique(candidates, getenv(_FONTCONFIG_LIB_ENV_VAR))

    if CompilationTarget.is_linux():
        _append_unique(candidates, "libfontconfig.so.1")
        _append_unique(candidates, "libfontconfig.so")
    elif CompilationTarget.is_macos():
        _append_unique(candidates, "libfontconfig.1.dylib")
        _append_unique(candidates, "libfontconfig.dylib")
    else:
        _append_unique(candidates, "libfontconfig.so.1")
        _append_unique(candidates, "libfontconfig.so")

    return candidates^


def _expensive_fontconfig_hint_candidates(mut candidates: List[String]) raises:
    """The subprocess-derived candidates (ldconfig/Homebrew/pkg-config),
    appended only once every _cheap_fontconfig_candidates entry has
    failed to dlopen -- an installation on a nonstandard prefix the
    dynamic linker's search path doesn't cover.
    """
    if CompilationTarget.is_linux():
        _append_linux_ldconfig_hints(candidates)
        _append_pkg_config_hints(candidates, False)
    elif CompilationTarget.is_macos():
        _append_macos_homebrew_hints(candidates)
        _append_pkg_config_hints(candidates, True)
    else:
        _append_pkg_config_hints(candidates, False)


def _open_fontconfig_library() raises -> OwnedDLHandle:
    var errors: List[String] = []

    for candidate in _cheap_fontconfig_candidates():
        try:
            return OwnedDLHandle(
                candidate, RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE
            )
        except err:
            errors.append(String(candidate, " -> ", String(err)))

    # Reached only once every zero-subprocess candidate has failed:
    # the tier that pays for ldconfig/Homebrew/pkg-config spawns,
    # computed here rather than up front.
    var hints = List[String]()
    _expensive_fontconfig_hint_candidates(hints)
    for candidate in hints:
        try:
            return OwnedDLHandle(
                candidate, RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE
            )
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
# Local, so this module depends on nothing in `canvas_mojo.text`. A
# manually-built NUL-terminated buffer rather than a String-to-`char*`
# shortcut, which isn't trustworthy at an FFI boundary here.


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

    `String(ptr)` on a raw `Pointer[c_char, ImmUntrackedOrigin]` does
    NOT decode the pointee bytes in this Mojo version -- it formats the
    pointer's address, which a real `char*`-returning C binding prints
    as a bare hex number. Hence walking the bytes.
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


def _imm(
    ptr: Pointer[c_char, MutUntrackedOrigin]
) -> Pointer[c_char, ImmUntrackedOrigin]:
    return ptr.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[
        ImmUntrackedOrigin
    ]()


# --- Opaque fontconfig types -----------------------------------------------
# `FcConfig`/`FcPattern`/`FcCharSet` are incomplete C structs in
# fontconfig's header, declared as empty structs here and used
# only as pointer targets, never dereferenced.
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
    via fontconfig's family-name matching/aliasing/fallback.

    Raises if libfontconfig can't be loaded, or if fontconfig reports
    no match (FcResultMatch is the only accepted success code). Its
    generic "sans-serif"/"serif"/"monospace" aliases and per-system
    default substitution make a true no-match rare, though possible on
    a font-less system.
    """
    return _resolve_font_file_impl(family, slant, weight, -1)


def resolve_font_file_for_char(
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    codepoint: Int,
) raises -> String:
    """Like `resolve_font_file`, but constrained (via `FC_CHARSET`) to
    a font that actually contains `codepoint`. This is the fallback
    lookup `render.mojo` uses when the requested family has no glyph
    for a character -- CJK text under a Latin-only "Sans", say -- and
    it goes through the same system-wide fallback chain desktop text
    stacks rely on.

    If no installed font has `codepoint`, fontconfig's default
    substitution still returns a best-effort match: a real font file
    that, like every other installed font, lacks the glyph. A caller
    that must distinguish "found a font with the glyph" from
    "fontconfig gave up" checks the result with
    `glyph_outline.has_glyph` rather than trusting the return value.
    """
    return _resolve_font_file_impl(family, slant, weight, codepoint)


def _resolve_font_file_impl(
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    char_constraint: Int,
) raises -> String:
    """Shared implementation for `resolve_font_file`/
    `resolve_font_file_for_char`. `char_constraint == -1` means plain
    family/slant/weight matching; any other value adds an `FC_CHARSET`
    holding that one codepoint before matching.
    """
    # FcMatchKind: only FcMatchPattern (0) is used, FcConfigSubstitute's
    # "substitute for a pattern being matched against available fonts".
    comptime _FC_MATCH_PATTERN = c_int(0)

    # FcResult: only FcResultMatch (0) counts as success. NoMatch/
    # TypeMismatch/NoId/OutOfMemory all fail alike, since none leave a
    # usable "file" property.
    comptime _FC_RESULT_MATCH = c_int(0)

    var handle = _open_fontconfig_library()

    var init_ok = handle.call["FcInit", c_int]()
    if Int(init_ok) == 0:
        raise Error("FcInit failed")

    var config = handle.call[
        "FcConfigGetCurrent", Pointer[_FcConfig, MutUntrackedOrigin]
    ]()

    var pattern = handle.call[
        "FcPatternCreate", Pointer[_FcPattern, MutUntrackedOrigin]
    ]()

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

    # Always create a real FcCharSet (cheap) and make only the
    # *attaching* conditional: the no-constraint path then needs no
    # null pointer, which isn't straightforward to construct for a
    # custom opaque struct type here.
    var have_charset = char_constraint != -1
    var charset = handle.call[
        "FcCharSetCreate", Pointer[_FcCharSet, MutUntrackedOrigin]
    ]()
    if have_charset:
        _ = handle.call[
            "FcCharSetAddChar",
            c_int,
            Pointer[_FcCharSet, MutUntrackedOrigin],
            c_uint,
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

    handle.call[
        "FcDefaultSubstitute", NoneType, Pointer[_FcPattern, MutUntrackedOrigin]
    ](pattern)

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

    handle.call[
        "FcPatternDestroy", NoneType, Pointer[_FcPattern, MutUntrackedOrigin]
    ](pattern)
    handle.call[
        "FcCharSetDestroy", NoneType, Pointer[_FcCharSet, MutUntrackedOrigin]
    ](charset)

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

    handle.call[
        "FcPatternDestroy", NoneType, Pointer[_FcPattern, MutUntrackedOrigin]
    ](matched)

    if resolved_path == "":
        raise Error(
            String(
                "fontconfig matched family '",
                family,
                "' but reported no 'file' property",
            )
        )
    return resolved_path

"""
Central runtime loader boundary for cairo wrapper internals.

Design:
- Prefer an explicit override via CAIRO_LIB.
- Prefer canonical runtime library names before any tool-driven path probing.
- Treat platform-specific probes (ldconfig, Homebrew, pkg-config) as optional hints.
- Keep discovery separate from loading.
"""

from std.ffi import OwnedDLHandle, RTLD
from std.os import getenv
from std.subprocess import run
from std.sys.info import CompilationTarget


# TODO: FIX: currently there is no way to have a global handle to the cairo library. so every time we need to use cairo, we need to open the library again.
# This if quite inefficient and we should be changed as soon as mojo supports global handles.

comptime _CAIRO_LIB_ENV_VAR = "CAIRO_LIB"


def _append_unique(mut candidates: List[String], value: String):
    var trimmed = String(value.strip())
    if trimmed.byte_length() == 0:
        return
    if trimmed not in candidates:
        candidates.append(trimmed)


def _append_lines(mut candidates: List[String], output: String):
    for line in output.split("\n"):
        _append_unique(candidates, String(line))


def _append_linux_default_names(mut candidates: List[String]):
    # Prefer the runtime soname first.
    _append_unique(candidates, "libcairo.so.2")
    _append_unique(candidates, "libcairo.so")


def _append_macos_default_names(mut candidates: List[String]):
    _append_unique(candidates, "libcairo.2.dylib")
    _append_unique(candidates, "libcairo.dylib")


def _append_linux_ldconfig_hints(mut candidates: List[String]):
    # Optional Linux-specific hint source.
    #
    # We collect both the soname and resolved path when present. This is only a
    # fallback hint source; canonical leaf names should already have been tried.
    try:
        var output = run(
            "ldconfig -p 2>/dev/null | awk '/libcairo\\.so/ { if (NF >= 1)"
            " print $1; if (NF >= 4) print $NF }'"
        )
        _append_lines(candidates, output)
    except:
        pass


def _append_macos_homebrew_hints(mut candidates: List[String]):
    # Optional macOS convenience for common Homebrew setups.
    try:
        var cairo_prefix = String(
            run("brew --prefix cairo 2>/dev/null").strip()
        )
        if cairo_prefix.byte_length() > 0:
            _append_unique(
                candidates, String(cairo_prefix, "/lib/libcairo.2.dylib")
            )
            _append_unique(
                candidates, String(cairo_prefix, "/lib/libcairo.dylib")
            )
    except:
        pass


def _append_pkg_config_hints(mut candidates: List[String], is_macos: Bool):
    # Optional developer-machine fallback. pkg-config is not the primary runtime
    # discovery mechanism, but its library directories can provide useful hints.
    try:
        var output = run(
            "pkg-config --libs-only-L cairo 2>/dev/null | tr ' ' '\\n' | sed -n"
            " 's/^-L//p'"
        )
        for directory_slice in output.split("\n"):
            var directory = String(directory_slice.strip())
            if directory.byte_length() == 0:
                continue

            if is_macos:
                _append_unique(
                    candidates, String(directory, "/libcairo.2.dylib")
                )
                _append_unique(candidates, String(directory, "/libcairo.dylib"))
            else:
                _append_unique(candidates, String(directory, "/libcairo.so.2"))
                _append_unique(candidates, String(directory, "/libcairo.so"))
    except:
        pass


def discover_cairo_candidates() raises -> List[String]:
    var candidates: List[String] = []

    # 1) Explicit user override always wins.
    _append_unique(candidates, getenv(_CAIRO_LIB_ENV_VAR))

    # 2) Canonical runtime library names come next.
    if CompilationTarget.is_linux():
        _append_linux_default_names(candidates)

        # 3) Optional hint providers.
        _append_linux_ldconfig_hints(candidates)
        _append_pkg_config_hints(candidates, False)

    elif CompilationTarget.is_macos():
        _append_macos_default_names(candidates)

        # 3) Optional hint providers.
        _append_macos_homebrew_hints(candidates)
        _append_pkg_config_hints(candidates, True)

    else:
        # Conservative fallback: prefer ELF-style defaults.
        _append_linux_default_names(candidates)
        _append_pkg_config_hints(candidates, False)

    return candidates^


def try_open_cairo(candidate: String) raises -> OwnedDLHandle:
    return OwnedDLHandle(candidate, RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE)


def resolve_cairo_library_from_candidates(
    ref candidates: List[String],
) raises -> String:
    var errors: List[String] = []

    for candidate in candidates:
        try:
            var handle = try_open_cairo(candidate)
            _ = handle
            return candidate
        except err:
            errors.append(String(candidate, " -> ", String(err)))

    var message = String(
        "Unable to load libcairo. Tried candidates discovered from ",
        _CAIRO_LIB_ENV_VAR,
        ", platform defaults, and optional platform hints.",
    )
    for error_text in errors:
        message = String(message, "\n - ", error_text)
    raise Error(message)


def open_cairo_library_from_candidates(
    ref candidates: List[String],
) raises -> OwnedDLHandle:
    var errors: List[String] = []

    for candidate in candidates:
        try:
            return try_open_cairo(candidate)
        except err:
            errors.append(String(candidate, " -> ", String(err)))

    var message = String(
        "Unable to load libcairo. Tried candidates discovered from ",
        _CAIRO_LIB_ENV_VAR,
        ", platform defaults, and optional platform hints.",
    )
    for error_text in errors:
        message = String(message, "\n - ", error_text)
    raise Error(message)


def resolve_cairo_library() raises -> String:
    var candidates = discover_cairo_candidates()
    return resolve_cairo_library_from_candidates(candidates)


def open_cairo_library() raises -> OwnedDLHandle:
    var candidates = discover_cairo_candidates()
    return open_cairo_library_from_candidates(candidates)


def ensure_cairo_loader_handle() raises -> OwnedDLHandle:
    # Compatibility shim used by existing FFI/high-level call sites.
    return open_cairo_library()


def ensure_runtime_ready() raises:
    # Verifies that libcairo can be resolved and opened now.
    var handle = ensure_cairo_loader_handle()
    _ = handle

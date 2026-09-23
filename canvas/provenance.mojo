"""Identify the Mojo compiler that produced a committed reference."""

from std.os import getenv, listdir


def _mojo_version_from_entries(entries: List[String]) -> String:
    """Read the compiler version from the conda package filename."""
    for entry in entries:
        if (
            entry.startswith("mojo-")
            and not entry.startswith("mojo-compiler-")
            and not entry.startswith("mojo-python-")
            and entry.endswith("-release.json")
        ):
            return String(entry[byte = 5 : entry.byte_length() - 13])
    return "unknown"


def mojo_version() -> String:
    """The active pixi environment's Mojo version, or unknown outside it."""
    var prefix = getenv("CONDA_PREFIX", "")
    if prefix == "":
        return "unknown"
    try:
        return _mojo_version_from_entries(listdir(prefix + "/conda-meta"))
    except:
        return "unknown"


def require_release_compiler() raises:
    """Keep committed references from being recorded with a nightly."""
    var version = mojo_version()
    if version == "unknown":
        raise Error(
            "cannot identify the Mojo compiler; record under pixi release"
        )
    if version.find(".dev") >= 0:
        raise Error(
            "cannot record references with Mojo "
            + version
            + "; run this task with `pixi run -e release`"
        )

"""Compiler provenance parser and recording guard."""

from std.testing import assert_equal, TestSuite

from canvas.provenance import _mojo_version_from_entries


def test_mojo_package_name() raises:
    var entries: List[String] = [
        "mojo-compiler-1.1.0-release.json",
        "mojo-1.1.0-release.json",
        "mojo-python-1.1.0-release.json",
    ]
    assert_equal(_mojo_version_from_entries(entries), "1.1.0")


def test_nightly_package_name() raises:
    var entries: List[String] = ["mojo-1.2.0.dev2026092105-release.json"]
    assert_equal(_mojo_version_from_entries(entries), "1.2.0.dev2026092105")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

from __future__ import annotations

import unittest

from tools import build_native_dependencies, build_resolver


class BuildResolverSelectionTests(unittest.TestCase):
    def test_normalizes_only_implemented_platforms(self) -> None:
        self.assertEqual(
            "linux-x86_64-glibc",
            build_resolver.normalize_platform("Linux"),
        )
        self.assertEqual(
            "windows-x86_64",
            build_resolver.normalize_platform("Windows"),
        )
        with self.assertRaisesRegex(build_resolver.SelectionError, "unsupported"):
            build_resolver.normalize_platform("Darwin")

    def test_native_dependency_plan_does_not_build_linux_tls_on_windows(self) -> None:
        self.assertEqual(["resolver"], build_native_dependencies.plan("Windows"))
        self.assertEqual(
            ["tls-provider", "resolver"],
            build_native_dependencies.plan("Linux"),
        )
        with self.assertRaisesRegex(ValueError, "unsupported"):
            build_native_dependencies.plan("Plan9")


if __name__ == "__main__":
    unittest.main()

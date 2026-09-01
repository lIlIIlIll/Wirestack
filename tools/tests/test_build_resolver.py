from __future__ import annotations

from tools import evidence_digest

import unittest
import tempfile
from pathlib import Path

from tools import build_native_dependencies, build_resolver, build_windows_resolver


class BuildResolverSelectionTests(unittest.TestCase):
    def test_windows_source_digest_is_line_ending_stable_and_content_bound(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "resolver.c"
            source.write_bytes(b"one\ntwo\n")
            lf_digest = evidence_digest.text_evidence_sha256(source)
            source.write_bytes(b"one\r\ntwo\r\n")
            self.assertEqual(lf_digest, evidence_digest.text_evidence_sha256(source))
            source.write_bytes(b"one\r\nchanged\r\n")
            self.assertNotEqual(lf_digest, evidence_digest.text_evidence_sha256(source))

    def test_normalizes_only_implemented_platforms(self) -> None:
        self.assertEqual(
            "linux-x86_64-glibc",
            build_resolver.normalize_platform("Linux"),
        )
        self.assertEqual(
            "windows-x86_64",
            build_resolver.normalize_platform("Windows"),
        )
        self.assertEqual(
            "macos-arm64",
            build_resolver.normalize_platform("Darwin"),
        )
        self.assertEqual(
            "ios-simulator-arm64",
            build_resolver.normalize_platform("ios-simulator-arm64"),
        )
        with self.assertRaisesRegex(build_resolver.SelectionError, "unsupported"):
            build_resolver.normalize_platform("Plan9")

    def test_native_dependency_plan_does_not_build_linux_tls_on_windows(self) -> None:
        self.assertEqual(["resolver"], build_native_dependencies.plan("Windows"))
        self.assertEqual(["resolver"], build_native_dependencies.plan("Darwin"))
        self.assertEqual(
            ["tls-provider", "resolver"],
            build_native_dependencies.plan("Linux"),
        )
        with self.assertRaisesRegex(ValueError, "unsupported"):
            build_native_dependencies.plan("Plan9")

    def test_darwin_resolver_selection_uses_the_cjpm_target_path(self) -> None:
        build_script = Path("build.cj").read_text(encoding="utf-8")
        self.assertIn('"--cjpm-script-path", scriptPath', build_script)
        self.assertIn("buildNativeDependencies(args[0])", build_script)
        self.assertEqual(
            "ios-simulator-arm64",
            build_native_dependencies.resolver_platform(
                "Darwin",
                "/repo/build-script-cache/arm64-apple-ios11-simulator/release/wirestack/bin/build-script",
                None,
            ),
        )
        self.assertEqual(
            "macos-arm64",
            build_native_dependencies.resolver_platform(
                "Darwin",
                "/repo/build-script-cache/release/wirestack/bin/build-script",
                None,
            ),
        )
        with self.assertRaisesRegex(ValueError, "identity is unavailable"):
            build_native_dependencies.resolver_platform("Darwin", None, None)
        with self.assertRaisesRegex(ValueError, "identity is unavailable"):
            build_native_dependencies.resolver_platform(
                "Darwin",
                "/repo/build-script-cache/android-aarch64/release/wirestack/bin/build-script",
                None,
            )


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "tools/tls_provider_poc/run_windows.py"
spec = importlib.util.spec_from_file_location("provider_windows", MODULE)
windows = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(windows)


class WindowsProviderPocTests(unittest.TestCase):
    def test_platform_id_is_native_windows_cell(self) -> None:
        self.assertEqual("windows-x86_64", windows.platform_id())

    def test_forbidden_tls_dlls_are_detected(self) -> None:
        output = """
            DLL Name: KERNEL32.dll
            DLL Name: libssl-3-x64.dll
            DLL Name: LIBCRYPTO-3-x64.DLL
            DLL Name: libwinpthread-1.dll
        """
        self.assertEqual(
            ["LIBCRYPTO-3-x64.DLL", "libssl-3-x64.dll"],
            windows.forbidden_windows_dependencies(output),
        )

    def test_unrelated_runtime_dlls_are_allowed(self) -> None:
        output = """
            DLL Name: KERNEL32.dll
            DLL Name: ucrtbase.dll
            DLL Name: libwinpthread-1.dll
        """
        self.assertEqual([], windows.forbidden_windows_dependencies(output))

    def test_git_tree_command_avoids_msys_brace_rewrite(self) -> None:
        command = windows.git_tree_command(Path("C:/work/provider"))
        self.assertEqual(
            [
                "git", "-C", "C:/work/provider", "show", "-s",
                "--format=%T", "HEAD",
            ],
            command,
        )
        self.assertNotIn("HEAD^{tree}", command)

    def test_canonical_hooks_are_saved_before_replacement(self) -> None:
        self.assertIsNot(windows.CANONICAL_SOURCE_PROVIDER, windows.source_provider)
        self.assertIsNot(windows.CANONICAL_BUILD_PROVIDER, windows.build_provider)

    def test_mbedtls_links_windows_cng_entropy(self) -> None:
        libraries = windows.mbedtls_system_libraries()
        self.assertIn("-lbcrypt", libraries)
        self.assertIn("-lws2_32", libraries)
        self.assertFalse(any("ssl" in item.lower() for item in libraries))
        self.assertFalse(any("crypto" in item.lower() for item in libraries))


if __name__ == "__main__":
    unittest.main()

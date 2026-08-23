from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "tools"))

import architecture_guard as guard  # noqa: E402


class ArchitectureGuardTests(unittest.TestCase):
    def fixture(self) -> tempfile.TemporaryDirectory[str]:
        return tempfile.TemporaryDirectory(prefix="wirestack-architecture-guard-")

    @staticmethod
    def write(root: Path, relative: str, content: str) -> Path:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def rules(self, root: Path) -> set[str]:
        return {item.rule for item in guard.run_guard(root)}

    def test_valid_packages_and_allowed_std_net_adapter_pass(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "src/package.cj", "package wirestack\n")
            self.write(root, "src/internal/transport_stdnet/package.cj",
                       "package wirestack.internal.transport_stdnet\n\nimport std.net.*\n")
            self.assertEqual([], guard.run_guard(root))

    def test_package_must_match_source_path(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "src/internal/transport/package.cj",
                       "package wirestack.internal.common\n")
            self.assertIn("package-path-mismatch", self.rules(root))

    def test_std_net_import_outside_adapter_is_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "src/internal/transport/socket.cj",
                       "package wirestack.internal.transport\n\nimport std.net.TcpSocket\n")
            self.assertIn("std-net-boundary", self.rules(root))

    def test_fully_qualified_std_net_type_in_public_api_is_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "src/tls/api.cj",
                       "package wirestack.tls\n\npublic func wrap(value: std.net.StreamingSocket): Unit {}\n")
            self.assertIn("std-net-boundary", self.rules(root))

    def test_private_runtime_and_legacy_stack_are_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            content = (
                "package wirestack.internal.transport\n\n"
                "import stdx.net.tls.common.*\n"
                "foreign { func CJ_MRT_SockRead(): Int64 }\n"
                "func bridge(): Unit { CJ_TLS_DYN_Load() }\n"
            )
            self.write(root, "src/internal/transport/native.cj", content)
            rules = self.rules(root)
            self.assertIn("private-runtime-socket-abi", rules)
            self.assertIn("legacy-stdx-network-stack", rules)
            self.assertIn("legacy-tls-dynamic-bridge", rules)

    def test_source_comments_and_literals_do_not_trigger(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            content = (
                "package wirestack.internal.transport\n\n"
                "// import std.net.*\n"
                "/* stdx.net.tls CJ_MRT_SockRead */\n"
                "let ordinary = \"CJ_TLS_DYN_Load std.net.TcpSocket\"\n"
                "let multiline = \"\"\"stdx.net.http\nCJ_MRT_SockWrite\"\"\"\n"
            )
            self.write(root, "src/internal/transport/notes.cj", content)
            self.assertEqual([], guard.run_guard(root))

    def test_build_configuration_rejects_openssl_loader_and_tls_ffi(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "cjpm.toml",
                       '[package]\nname = "wirestack"\ncompile-option = "-lcangjie-dynamicLoader-opensslFFI -lstdx.net.tlsFFI"\n')
            rules = self.rules(root)
            self.assertIn("openssl-dynamic-loader-bridge", rules)
            self.assertIn("legacy-tls-ffi", rules)

    def test_build_configuration_rejects_system_openssl(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "CMakeLists.txt",
                       "target_link_options(wirestack PRIVATE -lssl -lcrypto)\n")
            self.assertIn("system-openssl-link", self.rules(root))

    def test_pinned_static_provider_archive_is_allowed(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "src/package.cj", "package wirestack\n")
            self.write(root, "cjpm.toml",
                       '[package]\nname = "wirestack"\nlink-option = "-lstdc++ -lpthread -ldl -lm"\n'
                       '[ffi.c]\nwirestack_tls_provider = { path = "./target/native/current/lib" }\n')
            self.assertEqual([], guard.run_guard(root))

    def test_config_scan_covers_nested_build_files(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "native/provider/CMakeLists.txt",
                       "target_link_libraries(provider PRIVATE libssl.so)\n")
            self.assertIn("system-openssl-link", self.rules(root))

    def test_generated_and_build_directories_are_ignored(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "target/generated/bad.cj", "package bad\nimport std.net.*\n")
            self.write(root, "src/package.cj", "package wirestack\n")
            self.assertEqual([], guard.run_guard(root))

    def test_multiple_rules_on_one_config_line_are_all_reported(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "cjpm.toml",
                       'compile-option = "-lcangjie-dynamicLoader-opensslFFI -lstdx.net.tlsFFI -lssl"\n')
            rules = self.rules(root)
            expected = {"openssl-dynamic-loader-bridge", "legacy-tls-ffi", "system-openssl-link"}
            self.assertTrue(expected.issubset(rules))

    def test_json_mode_has_stable_machine_readable_shape(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "src/http/api.cj", "package wrong.package\n")
            completed = subprocess.run(
                [sys.executable, str(REPOSITORY_ROOT / "tools" / "architecture_guard.py"),
                 "--root", str(root), "--format", "json"],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(1, completed.returncode)
            payload = json.loads(completed.stdout)
            self.assertEqual(guard.SCHEMA_VERSION, payload["schema_version"])
            self.assertFalse(payload["ok"])
            self.assertEqual(1, payload["violation_count"])
            self.assertEqual("package-path-mismatch", payload["violations"][0]["rule"])


if __name__ == "__main__":
    unittest.main()

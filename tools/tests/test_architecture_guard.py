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

    def test_repository_rejects_raw_hashlib_digest_outside_control_plane(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "import hashlib\nvalue = hashlib.sha256(b'evidence').hexdigest()\n",
            )
            self.assertIn("untyped-evidence-digest", self.rules(root))

    def test_repository_rejects_direct_sha256_import(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "from hashlib import sha256\nvalue = sha256(b'evidence').hexdigest()\n",
            )
            self.assertIn("untyped-evidence-digest", self.rules(root))

    def test_repository_rejects_alternate_hashlib_constructor_import(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "from hashlib import new\nvalue = new('sha256', b'evidence').hexdigest()\n",
            )
            self.assertIn("untyped-evidence-digest", self.rules(root))

    def test_non_python_digest_requires_explicit_domain_marker(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            path = self.write(root, "scripts/check-report", "sha256sum report.json\n")
            self.assertIn("untyped-non-python-digest", self.rules(root))
            path.write_text(
                "# wirestack-digest-domain: artifact-bytes-v1\nsha256sum report.json\n",
                encoding="utf-8",
            )
            rules = self.rules(root)
            self.assertNotIn("untyped-non-python-digest", rules)
            self.assertIn("text-evidence-raw-digest", rules)
            path.write_text(
                "# wirestack-digest-domain: artifact-bytes-v1\nsha256sum payload.tar.gz\n",
                encoding="utf-8",
            )
            self.assertNotIn("text-evidence-raw-digest", self.rules(root))

    def test_non_python_tool_digest_is_scanned(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "tools/new_gate.sh", "sha256sum report.json\n")
            self.assertIn("untyped-non-python-digest", self.rules(root))

    def test_composite_action_digest_is_scanned(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                ".github/actions/evidence/action.yml",
                "runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: sha256sum report.json\n",
            )
            self.assertIn("untyped-non-python-digest", self.rules(root))

    def test_text_domain_marker_cannot_approve_raw_digest_command(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "scripts/check-report",
                "# wirestack-digest-domain: text-utf8-lf-v1\nsha256sum report.json\n",
            )
            self.assertIn("text-evidence-raw-digest", self.rules(root))

    def test_python_digest_alias_and_raw_subprocess_are_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "import subprocess\n"
                "from tools.evidence_digest import artifact_byte_sha256 as digest\n"
                "value = digest(report_path)\n"
                "subprocess.run(['sha256sum', 'report.json'])\n",
            )
            rules = self.rules(root)
            self.assertIn("text-evidence-byte-digest", rules)
            self.assertIn("untyped-evidence-digest-command", rules)

    def test_non_python_domain_manifest_matches_exact_command(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            path = self.write(root, "scripts/check-report", "sha256sum report.json\n")
            self.write(
                root,
                "tools/evidence-digest-non-python.json",
                json.dumps({
                    "schema_version": 1,
                    "entries": [{
                        "path": "scripts/check-report",
                        "command": "sha256sum report.json",
                        "domain": "artifact-bytes-v1",
                    }],
                }),
            )
            self.assertNotIn("untyped-non-python-digest", self.rules(root))
            path.write_text("sha256sum other.json\n", encoding="utf-8")
            self.assertIn("untyped-non-python-digest", self.rules(root))

    def test_repository_rejects_ambiguous_digest_helper(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "tools/gates/evidence.py", "def sha256_bytes(value):\n    return value\n")
            self.assertIn("untyped-evidence-digest-helper", self.rules(root))

    def test_text_path_rejects_artifact_byte_entry_outside_control_plane(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "def digest(report_path):\n    return artifact_byte_sha256(report_path)\n",
            )
            self.assertIn("text-evidence-byte-digest", self.rules(root))

    def test_assigned_text_path_rejects_artifact_byte_digest(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "from pathlib import Path\n"
                "from tools.evidence_digest import artifact_byte_sha256\n"
                "path = Path('report.json')\n"
                "value = artifact_byte_sha256(path)\n",
            )
            self.assertIn("text-evidence-byte-digest", self.rules(root))

    def test_keyword_text_path_rejects_artifact_byte_digest(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "from pathlib import Path\n"
                "from tools.evidence_digest import artifact_byte_sha256\n"
                "value = artifact_byte_sha256(path=Path('report.json'))\n",
            )
            self.assertIn("text-evidence-byte-digest", self.rules(root))

    def test_assigned_subprocess_and_os_system_commands_are_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "import os\nimport subprocess\n"
                "command = ['sha256sum', 'report.json']\n"
                "subprocess.run(command)\n"
                "os.system('sha256sum report.json')\n",
            )
            violations = guard.run_guard(root)
            self.assertEqual(
                2,
                sum(item.rule == "untyped-evidence-digest-command" for item in violations),
            )

    def test_scripts_python_is_scanned_for_digest_violations(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "scripts/new_gate.py", "import hashlib\n")
            self.assertIn("untyped-evidence-digest", self.rules(root))

    def test_local_digest_wrapper_cannot_hide_text_path_domain(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "from pathlib import Path\n"
                "from tools.evidence_digest import artifact_byte_sha256\n"
                "def digest(path):\n    return artifact_byte_sha256(path)\n"
                "value = digest(Path('report.json'))\n",
            )
            self.assertIn("text-evidence-byte-digest", self.rules(root))

    def test_assigned_digest_callable_cannot_hide_text_path_domain(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "from pathlib import Path\n"
                "from tools import evidence_digest\n"
                "digest = evidence_digest.artifact_byte_sha256\n"
                "value = digest(Path('report.json'))\n",
            )
            self.assertIn("text-evidence-byte-digest", self.rules(root))

    def test_openssl_and_embedded_python_digest_commands_are_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "scripts/check-report",
                "openssl dgst -sha256 docs/evidence/report.json\n"
                "python3 -c 'import hashlib; print(hashlib.sha256(open(\"report.json\", \"rb\").read()))'\n",
            )
            violations = guard.run_guard(root)
            self.assertEqual(
                2,
                sum(item.rule == "untyped-non-python-digest" for item in violations),
            )

    def test_repository_evidence_rejects_untyped_digest_comparison(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/gates/evidence.py",
                "def compare(item, expected):\n    return item.get('sha256') == expected\n",
            )
            self.assertIn("untyped-evidence-digest-comparison", self.rules(root))

    def test_text_evidence_rejects_artifact_digest_and_utf8_fallback(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "tools/repository/evidence.py",
                "def digest(report_path):\n"
                "    try:\n"
                "        return report_path.read_text(encoding='utf-8')\n"
                "    except UnicodeDecodeError:\n"
                "        return artifact_byte_digest(report_path)\n",
            )
            rules = self.rules(root)
            self.assertIn("text-evidence-byte-digest", rules)
            self.assertIn("text-evidence-byte-fallback", rules)

    def test_concrete_provider_is_rejected_from_generic_tls_and_http(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "src/internal/tls_engine/core.cj",
                       "package wirestack.internal.tls_engine\nlet value: AwsLcTlsProvider\n")
            self.assertIn("generic-provider-specific-type", self.rules(root))

    def test_root_build_rejects_provider_specific_paths(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "build.cj", 'let path = "native/tls/aws_lc"\n')
            self.assertIn("provider-specific-root-build", self.rules(root))

    def test_test_provider_is_rejected_from_production_source(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "src/internal/tls_engine/core.cj",
                       "package wirestack.internal.tls_engine\nlet value: TestTlsProvider\n")
            self.assertIn("test-provider-in-production", self.rules(root))

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

    def test_unqualified_low_level_and_native_types_in_public_api_are_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/http/api.cj",
                "package wirestack.http\n\n"
                "public func socket(value: StreamingSocket): SSL_CTX {}\n",
            )
            rules = self.rules(root)
            self.assertIn("public-low-level-socket-type", rules)
            self.assertIn("public-native-provider-type", rules)

    def test_public_alias_to_internal_import_is_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/http/api.cj",
                "package wirestack.http\n\n"
                "import wirestack.internal.transport as transport\n\n"
                "public type Deadline = transport.Deadline\n",
            )
            self.assertIn("public-internal-alias", self.rules(root))

    def test_public_header_with_internal_import_is_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/tls/api.cj",
                "package wirestack.tls\n\n"
                "import wirestack.internal.transport as transport\n\n"
                "public func wrap(value: transport.DuplexTransport): Unit {}\n",
            )
            self.assertIn("public-internal-type", self.rules(root))

    def test_public_member_of_public_class_with_internal_type_is_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/http/api.cj",
                "package wirestack.http\n\n"
                "import wirestack.internal.transport as transport\n\n"
                "public class Client {\n"
                "    public func use(value: transport.DuplexTransport): Unit {}\n"
                "}\n",
            )
            self.assertIn("public-internal-type", self.rules(root))

    def test_public_member_of_private_class_is_not_exported(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/http/adapter.cj",
                "package wirestack.http\n\n"
                "import wirestack.internal.transport as transport\n\n"
                "private class Adapter {\n"
                "    public func use(value: transport.DuplexTransport): Unit {}\n"
                "}\n",
            )
            self.assertEqual([], guard.run_guard(root))

    def test_public_alias_to_public_owner_is_allowed(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(root, "src/package.cj", "package wirestack\n\npublic struct Deadline {}\n")
            self.write(
                root,
                "src/http/api.cj",
                "package wirestack.http\n\nimport wirestack as api\n\n"
                "public type Deadline = api.Deadline\n",
            )
            self.assertEqual([], guard.run_guard(root))

    def test_public_internal_dependency_cycle_is_rejected_deterministically(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/http/api.cj",
                "package wirestack.http\n\n"
                "import wirestack.internal.connector.ClientConnector\n",
            )
            self.write(
                root,
                "src/internal/connector/package.cj",
                "package wirestack.internal.connector\n\n"
                "import wirestack.http.HttpClient\n",
            )
            violations = [
                item for item in guard.run_guard(root)
                if item.rule == "public-internal-dependency-cycle"
            ]
            self.assertEqual(1, len(violations))
            self.assertEqual("src/http/api.cj", violations[0].path)
            self.assertIn(
                "wirestack.http -> wirestack.internal.connector -> wirestack.http",
                violations[0].message,
            )

    def test_one_way_public_to_internal_dependency_is_allowed(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/tls/api.cj",
                "package wirestack.tls\n\n"
                "import wirestack.internal.tls_engine.Engine\n",
            )
            self.write(
                root,
                "src/internal/tls_engine/package.cj",
                "package wirestack.internal.tls_engine\n",
            )
            self.assertEqual([], guard.run_guard(root))

    def test_internal_names_in_comments_and_literals_do_not_trigger(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/http/api.cj",
                "package wirestack.http\n\n"
                "// public type Deadline = wirestack.internal.transport.Deadline\n"
                "let note = \"wirestack.internal.transport.Deadline\"\n",
            )
            self.assertEqual([], guard.run_guard(root))

    def test_low_level_names_in_public_comments_and_literals_do_not_trigger(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/http/api.cj",
                "package wirestack.http\n\n"
                "// StreamingSocket and SSL_CTX are forbidden public types.\n"
                "let note = \"TcpSocket X509\"\n",
            )
            self.assertEqual([], guard.run_guard(root))

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

    def test_legacy_global_tls_provider_is_rejected(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "src/internal/tls_engine/global.cj",
                "package wirestack.internal.tls_engine\n\n"
                "func setGlobalTlsKit(value: Int64): Unit {}\n",
            )
            self.assertIn("legacy-global-tls-provider", self.rules(root))

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

    def test_native_code_rejects_system_openssl_runtime_loader(self) -> None:
        with self.fixture() as directory:
            root = Path(directory)
            self.write(
                root,
                "native/tls/loader.c",
                'void *load(void) { return dlopen("libssl.so", 1); }\n',
            )
            rules = self.rules(root)
            self.assertIn("system-openssl-loader", rules)
            self.assertIn("system-openssl-link", rules)

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

from __future__ import annotations

import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
VALIDATE_MODULE = ROOT / "tools/tls_provider_poc/validate.py"
validate_spec = importlib.util.spec_from_file_location("provider_validate", VALIDATE_MODULE)
validator = importlib.util.module_from_spec(validate_spec)
assert validate_spec.loader
validate_spec.loader.exec_module(validator)

RUN_MODULE = ROOT / "tools/tls_provider_poc/run.py"
run_spec = importlib.util.spec_from_file_location("provider_run", RUN_MODULE)
runner = importlib.util.module_from_spec(run_spec)
assert run_spec.loader
run_spec.loader.exec_module(runner)


class ProviderPocValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = json.loads((ROOT / "tools/tls_provider_poc/providers.json").read_text())
        cls.matrix = json.loads((ROOT / "docs/evidence/M0-016/platform-matrix.json").read_text())

    def test_canonical_spec_and_matrix(self):
        validator.validate_spec(self.spec)
        validator.validate_matrix(self.matrix, self.spec)
        validator.validate_retained_results(self.matrix, self.spec, ROOT)

    def test_missing_archive_digest_fails(self):
        value = copy.deepcopy(self.spec)
        value["providers"][1].pop("sha256")
        with self.assertRaises(validator.ValidationError):
            validator.validate_spec(value)

    def test_archive_provider_requires_exact_commit(self):
        value = copy.deepcopy(self.spec)
        value["providers"][2].pop("commit")
        value["providers"][2]["commit_resolution_url"] = (
            "https://api.github.com/repos/openssl/openssl/git/ref/tags/openssl-3.6.3"
        )
        with self.assertRaises(validator.ValidationError):
            validator.validate_spec(value)

    def test_missing_platform_cell_fails(self):
        value = copy.deepcopy(self.matrix)
        value["cells"].pop()
        with self.assertRaises(validator.ValidationError):
            validator.validate_matrix(value, self.spec)

    def test_partial_matrix_cell_requires_retained_result(self):
        value = copy.deepcopy(self.matrix)
        cell = value["cells"][0]
        cell["status"] = "PARTIAL"
        cell.pop("result", None)
        cell.pop("sha256", None)
        with self.assertRaises(validator.ValidationError):
            validator.validate_matrix(value, self.spec)

    def test_retained_result_digest_must_match(self):
        value = copy.deepcopy(self.matrix)
        cell = value["cells"][0]
        cell["status"] = "PARTIAL"
        cell["result"] = "synthetic-result.json"
        cell["sha256"] = "0" * 64
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        caps["external_signer"] = "BLOCKED"
        result = {
            "schema_version": 3,
            "task_id": "M0-016",
            "provider": cell["provider"],
            "platform": cell["platform"],
            "status": "PARTIAL",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "metrics": {
                "repeated_cleanup_cycles": 10000,
                "external_trust_calls": 4,
                "session_resumption_handshakes": 4,
                "session_resumption_tls12_handshakes": 2,
                "session_resumption_tls13_handshakes": 2,
            },
            "build": {
                "static_archives": ["libssl.a"],
                "system_tls_dependencies": [],
                "runtime_loader_library_strings": [],
            },
        }
        with mock.patch.object(validator, "load", return_value=result), \
             mock.patch.object(validator, "sha256_path", return_value="1" * 64), \
             self.assertRaisesRegex(validator.ValidationError, "sha256 mismatch"):
            validator.validate_retained_results(value, self.spec, ROOT)

    def test_blocked_capability_cannot_pass(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        caps["external_signer"] = "BLOCKED"
        result = {
            "schema_version": 1,
            "task_id": "M0-016",
            "provider": "aws-lc",
            "platform": "linux-glibc-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "build": {"static_archives": ["libssl.a"], "system_tls_dependencies": []},
        }
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(result, self.spec)

    def test_system_tls_dependency_fails(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        result = {
            "schema_version": 1,
            "task_id": "M0-016",
            "provider": "openssl",
            "platform": "linux-glibc-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "build": {
                "static_archives": ["libssl.a"],
                "system_tls_dependencies": ["libssl.so.3"],
            },
        }
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(result, self.spec)

    def test_pass_requires_measured_schema_v2(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        result = {
            "schema_version": 1,
            "task_id": "M0-016",
            "provider": "aws-lc",
            "platform": "linux-glibc-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "build": {
                "static_archives": ["libssl.a"],
                "system_tls_dependencies": [],
                "runtime_loader_library_strings": [],
            },
        }
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(result, self.spec)

    def test_schema_v2_cannot_claim_a_fully_measured_pass(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        result = {
            "schema_version": 2,
            "task_id": "M0-016",
            "provider": "aws-lc",
            "platform": "linux-glibc-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "metrics": {
                "repeated_cleanup_cycles": 9999,
                "external_signer_calls": 1,
            },
            "build": {
                "static_archives": ["libssl.a"],
                "system_tls_dependencies": [],
                "runtime_loader_library_strings": [],
            },
        }
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(result, self.spec)

        result["metrics"] = {
            "repeated_cleanup_cycles": 10000,
            "external_signer_calls": 2,
            "external_trust_calls": 4,
        }
        with self.assertRaisesRegex(validator.ValidationError, "schema v3"):
            validator.validate_result(result, self.spec)

    def test_schema_v3_requires_measured_session_resumption(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        result = {
            "schema_version": 3,
            "task_id": "M0-016",
            "provider": "aws-lc",
            "platform": "linux-glibc-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "metrics": {
                "repeated_cleanup_cycles": 10000,
                "external_signer_calls": 2,
                "session_resumption_handshakes": 1,
                "session_resumption_tls12_handshakes": 2,
                "session_resumption_tls13_handshakes": 2,
                "external_trust_calls": 4,
            },
            "build": {
                "static_archives": ["libssl.a"],
                "system_tls_dependencies": [],
                "runtime_loader_library_strings": [],
            },
        }
        with self.assertRaisesRegex(
            validator.ValidationError, "four measured handshakes"):
            validator.validate_result(result, self.spec)
        result["metrics"]["session_resumption_handshakes"] = 4
        validator.validate_result(result, self.spec)

    def test_metrics_require_dual_version_resumption_and_external_trust(self):
        caps = {name: "BLOCKED" for name in self.spec["required_capabilities"]}
        caps["external_trust"] = "PASS"
        caps["session_resumption"] = "PASS"
        complete = "\n".join([
            "METRIC repeated_cleanup_cycles=10000",
            "METRIC external_trust_calls=4",
            "METRIC session_resumption_handshakes=4",
            "METRIC session_resumption_tls12_handshakes=2",
            "METRIC session_resumption_tls13_handshakes=2",
        ])
        metrics = runner.parse_metrics(complete, "openssl", caps)
        self.assertEqual(4, metrics["session_resumption_handshakes"])
        with self.assertRaisesRegex(runner.PocError, "TLS 1.2 and TLS 1.3"):
            runner.parse_metrics(
                complete.replace("session_resumption_tls13_handshakes=2",
                                 "session_resumption_tls13_handshakes=0"),
                "openssl",
                caps,
            )
        with self.assertRaisesRegex(runner.PocError, "external trust"):
            runner.parse_metrics(
                complete.replace("external_trust_calls=4", "external_trust_calls=3"),
                "openssl",
                caps,
            )

    def test_native_pocs_expose_external_trust_as_a_distinct_capability(self):
        openssl_source = (ROOT / "tools/tls_provider_poc/openssl_memory_poc.c").read_text()
        mbedtls_source = (ROOT / "tools/tls_provider_poc/mbedtls_memory_poc.c").read_text()
        for source in (openssl_source, mbedtls_source):
            self.assertIn("CAP external_trust=%s", source)
            self.assertIn("external_trust_calls", source)

    def test_native_pocs_drive_provider_specific_session_and_trust_callbacks(self):
        openssl_source = (ROOT / "tools/tls_provider_poc/openssl_memory_poc.c").read_text()
        mbedtls_source = (ROOT / "tools/tls_provider_poc/mbedtls_memory_poc.c").read_text()
        self.assertIn(
            "SSL_CTX_sess_set_new_cb(client_ctx, capture_session_callback);",
            openssl_source,
        )
        self.assertIn("SSL_write(p->server, &marker, 1)", openssl_source)
        self.assertNotIn(
            "if (version == TLS1_3_VERSION) {\n"
            "        if (captured_session != NULL)",
            openssl_source,
        )
        self.assertIn(
            "configure(m, &client_conf, &server_conf, version, 0, 0)",
            mbedtls_source,
        )
        self.assertNotIn(
            "configure(m, &client_conf, &server_conf, version, 0, 1)",
            mbedtls_source,
        )
        self.assertIn(
            "mbedtls_ssl_conf_ca_chain(&client_conf, &m->client_cert, NULL);",
            mbedtls_source,
        )
        self.assertIn("Pair provider_rejected;", mbedtls_source)


class ProviderPocWindowsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = json.loads((ROOT / "tools/tls_provider_poc/providers.json").read_text())

    def test_windows_archive_names_cover_all_providers(self):
        self.assertEqual(
            (["ssl.lib", "libssl.lib"], ["crypto.lib", "libcrypto.lib"]),
            runner.provider_archive_names("aws-lc", True),
        )
        self.assertEqual(
            (["mbedtls.lib"], ["mbedx509.lib"], ["tfpsacrypto.lib", "mbedcrypto.lib"]),
            runner.provider_archive_names("mbedtls", True),
        )
        self.assertEqual(
            (["libssl.lib", "ssl.lib"], ["libcrypto.lib", "crypto.lib"]),
            runner.provider_archive_names("openssl", True),
        )

    def test_windows_cmake_and_poc_use_static_crt(self):
        self.assertEqual(
            [
                "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
                "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
            ],
            runner.cmake_runtime_args(True),
        )
        self.assertEqual([], runner.cmake_runtime_args(False))
        self.assertEqual(["-DMSVC_STATIC_RUNTIME=ON"], runner.mbedtls_runtime_args(True))
        self.assertEqual([], runner.mbedtls_runtime_args(False))

    def test_atomic_json_has_platform_stable_lf(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            runner.atomic_json(output, {"status": "PASS"})
            data = output.read_bytes()
            self.assertTrue(data.endswith(b"\n"))
            self.assertNotIn(b"\r\n", data)

    def test_windows_dependency_scan_rejects_versioned_tls_dll(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "provider-poc.exe"
            archive = root / "ssl.lib"
            log = root / "build.log"
            binary.write_bytes(b"PE fixture")
            archive.write_bytes(b"archive")
            completed = runner.subprocess.CompletedProcess(
                ["dumpbin"], 0, "LIBSSL-3-X64.DLL\nKERNEL32.dll\n", ""
            )
            with mock.patch.object(runner, "is_windows", return_value=True), \
                    mock.patch.object(runner, "run", return_value=completed) as run_mock:
                result = runner.inspect_binary(binary, [archive], root, log)
            self.assertEqual(["LIBSSL-3-X64.DLL"], result["system_tls_dependencies"])
            run_mock.assert_called_once_with(
                ["dumpbin", "/dependents", str(binary)], cwd=root, log=log, check=False
            )

    def test_windows_dependency_scan_rejects_prefixless_mbedtls_dlls(self):
        text = "mbedtls.dll\nMBEDX509.DLL\ntfpsacrypto.dll\nmbedcrypto.dll\n"
        self.assertEqual(
            ["MBEDX509.DLL", "mbedcrypto.dll", "mbedtls.dll", "tfpsacrypto.dll"],
            sorted(set(runner.FORBIDDEN_DEP_RE.findall(text))),
        )

    def test_windows_dependency_scan_rejects_prefixless_aws_lc_dlls(self):
        text = "ssl.dll\nCRYPTO.DLL\nlibssl-3-x64.dll\nKERNEL32.dll\n"
        self.assertEqual(
            ["CRYPTO.DLL", "libssl-3-x64.dll", "ssl.dll"],
            sorted(set(runner.FORBIDDEN_DEP_RE.findall(text))),
        )

    def test_windows_dependency_scan_fails_closed_when_dumpbin_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "provider-poc.exe"
            archive = root / "ssl.lib"
            binary.write_bytes(b"PE fixture")
            archive.write_bytes(b"archive")
            completed = runner.subprocess.CompletedProcess(["dumpbin"], 1, "error", "")
            with mock.patch.object(runner, "is_windows", return_value=True), \
                    mock.patch.object(runner, "run", return_value=completed):
                with self.assertRaisesRegex(runner.PocError, "dumpbin dependency inspection failed"):
                    runner.inspect_binary(binary, [archive], root, root / "build.log")

    def test_windows_compile_uses_msvc_and_no_posix_link_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            source_dir = repo / "tools/tls_provider_poc"
            source_dir.mkdir(parents=True)
            (source_dir / "openssl_memory_poc.c").write_text("int main(void){return 0;}\n")
            prefix = root / "prefix"
            (prefix / "include").mkdir(parents=True)
            archive = root / "ssl.lib"
            archive.write_bytes(b"archive")
            with mock.patch.object(runner, "is_windows", return_value=True), \
                    mock.patch.object(runner, "run") as run_mock:
                output = runner.compile_poc(
                    {"poc_family": "openssl-compatible"}, repo, prefix, [archive],
                    root / "work", root / "build.log"
                )
            command = run_mock.call_args.args[0]
            self.assertEqual("provider-poc.exe", output.name)
            self.assertEqual("cl", command[0])
            self.assertIn("/MT", command)
            self.assertNotIn("-pthread", command)
            self.assertNotIn("-lm", command)
            self.assertIn("bcrypt.lib", command)

    def test_windows_openssl_build_uses_vc_target_and_nmake(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "source"
            prefix = root / "prefix"
            src.mkdir()
            calls = []

            def fake_run(command, **kwargs):
                calls.append(list(command))
                return runner.subprocess.CompletedProcess(command, 0, "", "")

            with mock.patch.object(runner, "is_windows", return_value=True), \
                    mock.patch.object(runner, "run", side_effect=fake_run), \
                    mock.patch.object(runner, "find_provider_archives", return_value=[root / "libssl.lib"]):
                runner.build_provider({"id": "openssl"}, src, root, root / "build.log")
            self.assertEqual("perl", calls[0][0])
            self.assertIn("VC-WIN64A", calls[0])
            self.assertEqual(["nmake"], calls[1])
            self.assertEqual(["nmake", "install_sw"], calls[2])

    def test_windows_result_requires_native_hosted_runner_identity(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        result = {
            "schema_version": 3,
            "task_id": "M0-016",
            "provider": "aws-lc",
            "platform": "windows-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "metrics": {
                "repeated_cleanup_cycles": 10000,
                "external_signer_calls": 2,
                "external_trust_calls": 4,
                "session_resumption_handshakes": 4,
                "session_resumption_tls12_handshakes": 2,
                "session_resumption_tls13_handshakes": 2,
            },
            "build": {
                "static_archives": ["ssl.lib"],
                "system_tls_dependencies": [],
                "runtime_loader_library_strings": [],
            },
            "execution": {
                "repository_revision": "2" * 40,
                "runner_os": "Windows",
                "runner_arch": "X64",
                "image_os": "win25",
                "image_version": "20260824.239.3",
            },
        }
        validator.validate_result(result, self.spec, "2" * 40)
        result["execution"]["runner_os"] = "Linux"
        with self.assertRaisesRegex(validator.ValidationError, "native Windows runner"):
            validator.validate_result(result, self.spec, "2" * 40)

    def test_expected_revision_mismatch_fails(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        result = {
            "schema_version": 3,
            "task_id": "M0-016",
            "provider": "aws-lc",
            "platform": "windows-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "metrics": {
                "repeated_cleanup_cycles": 10000,
                "external_signer_calls": 2,
                "external_trust_calls": 4,
                "session_resumption_handshakes": 4,
                "session_resumption_tls12_handshakes": 2,
                "session_resumption_tls13_handshakes": 2,
            },
            "build": {
                "static_archives": ["ssl.lib"],
                "system_tls_dependencies": [],
                "runtime_loader_library_strings": [],
            },
            "execution": {
                "repository_revision": "2" * 40,
                "runner_os": "Windows",
                "runner_arch": "X64",
                "image_os": "win25",
                "image_version": "20260824.239.3",
            },
        }
        with self.assertRaisesRegex(validator.ValidationError, "revision mismatch"):
            validator.validate_result(result, self.spec, "3" * 40)


if __name__ == "__main__":
    unittest.main()

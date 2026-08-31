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

EMPTY_SYMBOL_INVENTORY = {
    "scope": "final-artifact-exports",
    "tool": "fixture-tool",
    "count": 0,
    "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "symbols": [],
}


def tool_identity_fixture(name="fixture-tool"):
    output = f"{name} 1.0"
    return {
        "argv": [name, "--version"],
        "exit_code": 0,
        "output": output,
        "output_sha256": validator.hashlib.sha256(output.encode()).hexdigest(),
    }


def build_provenance_fixture(provider, platform, *, diagnostic=False):
    triples = {
        "linux-glibc-x86_64": "x86_64-unknown-linux-gnu",
        "linux-musl-x86_64": "x86_64-unknown-linux-musl",
        "windows-x86_64": "x86_64-pc-windows-msvc",
        "macos-arm64": "arm64-apple-darwin",
    }
    if provider == "aws-lc":
        configure = [
            "cmake", "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF",
            "-DDISABLE_GO=ON", "<SOURCE>", "<BUILD>", "<PREFIX>",
        ]
    elif provider == "mbedtls":
        configure = [
            "cmake", "-DENABLE_TESTING=OFF", "-DENABLE_PROGRAMS=OFF",
            "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF",
            "-DMBEDTLS_USER_CONFIG_FILE=<REPOSITORY>/tools/tls_provider_poc/mbedtls_provider_profile_config.h",
            "-DTF_PSA_CRYPTO_USER_CONFIG_FILE=<REPOSITORY>/tools/tls_provider_poc/mbedtls_provider_profile_config.h",
            "<SOURCE>", "<BUILD>", "<PREFIX>",
        ]
    else:
        configure = [
            "Configure", "no-shared", "no-module", "no-tests", "no-zlib",
            "no-zstd", "<SOURCE>", "<BUILD>", "<PREFIX>",
        ]
    return {
        "target_triple": triples[platform],
        "compiler": tool_identity_fixture("cc"),
        "cxx_compiler": tool_identity_fixture("c++"),
        "cmake": tool_identity_fixture("cmake") if provider != "openssl" else None,
        "build_tool": tool_identity_fixture("build-tool"),
        "configure_argv": configure,
        "build_argv": [["build-tool", "<BUILD>"], ["build-tool", "<PREFIX>"]],
        "environment": {
            key: ("/usr/bin:/bin" if key == "PATH" else "")
            for key in runner.BUILD_ENVIRONMENT_KEYS
        },
        "patches": [],
        "patch_set_sha256": validator.hashlib.sha256(b"[]\n").hexdigest(),
        "instrumentation": (
            "address+undefined-sanitizer" if diagnostic else "none"
        ),
        "provider_instrumented": diagnostic,
    }


def complete_result(spec, *, provider="aws-lc", platform="linux-glibc-x86_64",
                    status="PASS"):
    provider_spec = next(item for item in spec["providers"]
                         if item["id"] == provider)
    caps = {name: "PASS" for name in spec["required_capabilities"]}
    if status == "PARTIAL":
        caps["external_signer"] = "BLOCKED"
    runner_os = "Windows" if platform == "windows-x86_64" else "Linux"
    image_os = "win25" if platform == "windows-x86_64" else "ubuntu24"
    execution = {
        "repository_revision": "2" * 40,
        "runner_os": runner_os,
        "runner_arch": "X64",
        "image_os": image_os,
        "image_version": "fixture-image",
        "container_image": "",
    }
    if platform == "linux-musl-x86_64":
        execution["image_os"] = "alpine"
        execution["image_version"] = "3.22.5"
        execution["container_image"] = (
            "alpine:3.22@sha256:" + "3" * 64
        )
    metrics = {
        "repeated_cleanup_cycles": 10000,
        "external_signer_calls": 2,
        "external_trust_calls": 4,
        "alpn_no_overlap_handshakes": 2,
        "alpn_malformed_inputs_rejected": 2,
        "certificate_negative_cases_rejected": 2,
        "session_resumption_handshakes": 4,
        "session_resumption_tls12_handshakes": 2,
        "session_resumption_tls13_handshakes": 2,
        "mtls_required_handshakes": 1,
        "mtls_optional_handshakes": 2,
        "memory_profile_peak_resident_bytes": 64 * 1024 * 1024,
        "memory_profile_bound_bytes": validator.MEMORY_PROFILE_BOUND_BYTES,
        "provider_allocation_calls": 200,
        "provider_allocation_call_bound": validator.PROVIDER_ALLOCATION_CALL_BOUND,
        "provider_allocation_bytes": 1024 * 1024,
        "provider_allocation_bound_bytes": validator.PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES,
        "provider_allocation_peak_live_bytes": 512 * 1024,
        "provider_allocation_live_before_cleanup_bytes": 64 * 1024,
        "provider_allocation_live_after_cleanup_bytes": 64 * 1024,
        "cancellation_wakeups": 1,
        "cancellation_latency_us": 1000,
        "cancellation_bound_us": validator.CANCELLATION_WAKE_BOUND_US,
    }
    diagnostic_status = (
        "PASS" if platform.startswith(("linux-glibc-", "macos-"))
        else "UNSUPPORTED"
    )
    return {
        "schema_version": validator.RESULT_SCHEMA_VERSION,
        "task_id": "M0-016",
        "provider": provider,
        "platform": platform,
        "status": status,
        "source": {
            "content_sha256": "0" * 64,
            "commit": provider_spec["commit"],
            "security_update": copy.deepcopy(provider_spec["security_update"]),
        },
        "capabilities": caps,
        "metrics": metrics,
        "build": {
            "static_archives": ["libssl.a"],
            "exported_symbol_inventory": EMPTY_SYMBOL_INVENTORY,
            "system_tls_dependencies": [],
            "runtime_loader_library_strings": [],
            "license_bundle": {
                "path": "license-bundle/manifest.json",
                "sha256": "4" * 64,
                "file_count": 1,
                "total_bytes": 100,
            },
            "provenance": build_provenance_fixture(provider, platform),
        },
        "execution": execution,
        "operational_evidence": {
            "native_memory_diagnostic": {
                "status": diagnostic_status,
                "tool": "address+undefined-sanitizer",
                "leak_detection": {
                    "status": (
                        "PASS"
                        if platform.startswith("linux-glibc-") and provider == "mbedtls"
                        else "UNSUPPORTED"
                    ),
                },
                **({
                    "provider_instrumented": True,
                    "provider_static_archives": [{
                        "name": "libprovider.a",
                        "bytes": 1,
                        "sha256": "5" * 64,
                    }],
                    "provider_build_provenance": build_provenance_fixture(
                        provider, platform, diagnostic=True),
                } if diagnostic_status == "PASS" else {}),
            },
            "memory_profile": {
                "method": "native-process-peak-resident-and-provider-allocation-hooks",
                "peak_resident_bytes": metrics["memory_profile_peak_resident_bytes"],
                "resident_bound_bytes": metrics["memory_profile_bound_bytes"],
                "provider_allocation_calls": metrics["provider_allocation_calls"],
                "provider_allocation_call_bound": metrics["provider_allocation_call_bound"],
                "provider_allocation_bytes": metrics["provider_allocation_bytes"],
                "provider_allocation_bound_bytes": metrics["provider_allocation_bound_bytes"],
                "provider_allocation_peak_live_bytes": metrics["provider_allocation_peak_live_bytes"],
                "provider_allocation_live_before_cleanup_bytes": metrics["provider_allocation_live_before_cleanup_bytes"],
                "provider_allocation_live_after_cleanup_bytes": metrics["provider_allocation_live_after_cleanup_bytes"],
                "payload_bytes_per_transfer": 32768,
            },
            "cancellation": {
                "method": "caller-owned-wait-thread-explicit-cancel-and-bounded-join",
                "wakeups": metrics["cancellation_wakeups"],
                "latency_us": metrics["cancellation_latency_us"],
                "bound_us": metrics["cancellation_bound_us"],
            },
        },
    }


def required_profile_metrics() -> list[str]:
    return [
        "METRIC memory_profile_peak_resident_bytes=67108864",
        f"METRIC memory_profile_bound_bytes={runner.MEMORY_PROFILE_BOUND_BYTES}",
        "METRIC provider_allocation_calls=200",
        f"METRIC provider_allocation_call_bound={runner.PROVIDER_ALLOCATION_CALL_BOUND}",
        "METRIC provider_allocation_bytes=1048576",
        f"METRIC provider_allocation_bound_bytes={runner.PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES}",
        "METRIC provider_allocation_peak_live_bytes=524288",
        "METRIC provider_allocation_live_before_cleanup_bytes=65536",
        "METRIC provider_allocation_live_after_cleanup_bytes=65536",
        "METRIC cancellation_wakeups=1",
        "METRIC cancellation_latency_us=1000",
        f"METRIC cancellation_bound_us={runner.CANCELLATION_WAKE_BOUND_US}",
    ]


class ProviderPocValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = json.loads((ROOT / "tools/tls_provider_poc/providers.json").read_text())
        cls.matrix = json.loads((ROOT / "docs/evidence/M0-016/platform-matrix.json").read_text())

    def test_canonical_spec_and_matrix(self):
        validator.validate_spec(self.spec)
        validator.validate_matrix(self.matrix, self.spec)
        validator.validate_retained_results(self.matrix, self.spec, ROOT)
        for provider in self.spec["providers"]:
            workflow = provider["security_update"]["update_workflow"]
            self.assertTrue((ROOT / workflow).is_file())

    def test_security_update_evidence_fails_closed(self):
        value = copy.deepcopy(self.spec)
        value["providers"][0]["security_update"]["source_committed_at"] = (
            "2020-01-01T00:00:00Z"
        )
        with self.assertRaisesRegex(validator.ValidationError, "source pin is stale"):
            validator.validate_spec(value)

        value = copy.deepcopy(self.spec)
        value["providers"][1]["security_update"]["advisory_urls"] = [
            "http://example.invalid/advisories"
        ]
        with self.assertRaisesRegex(validator.ValidationError,
                                    "advisory intake channels"):
            validator.validate_spec(value)

        value = copy.deepcopy(self.spec)
        value["providers"][0]["security_update"]["advisory_disposition"][
            "reviewed_through"
        ] = "2020-01-01T00:00:00Z"
        with self.assertRaisesRegex(validator.ValidationError,
                                    "advisory disposition is stale"):
            validator.validate_spec(value)

        value = copy.deepcopy(self.spec)
        value["providers"][0]["security_update"]["advisory_disposition"][
            "pin_commit"
        ] = "f" * 40
        with self.assertRaisesRegex(validator.ValidationError,
                                    "advisory disposition pin mismatch"):
            validator.validate_spec(value)

        value = copy.deepcopy(self.spec)
        disposition = value["providers"][0]["security_update"][
            "advisory_disposition"
        ]
        disposition["status"] = "affected"
        disposition["affected_advisory_ids"] = [
            disposition["reviewed_advisory_ids"][0]
        ]
        validator.validate_spec(value)
        with self.assertRaisesRegex(validator.ValidationError,
                                    "known affected provider pin"):
            validator.validate_result(complete_result(value), value)

        result = complete_result(self.spec)
        result["source"]["security_update"]["advisory_disposition"][
            "reviewed_advisory_ids"
        ] = ["GHSA-0000-0000-0000"]
        with self.assertRaisesRegex(validator.ValidationError,
                                    "source security-update disposition mismatch"):
            validator.validate_result(result, self.spec)

    def test_exported_symbol_inventory_is_bounded_and_digest_bound(self):
        self.assertEqual(runner.MAX_EXPORTED_SYMBOLS, validator.MAX_EXPORTED_SYMBOLS)
        validator.validate_exported_symbols({
            "exported_symbol_inventory": EMPTY_SYMBOL_INVENTORY,
        })
        bad = copy.deepcopy(EMPTY_SYMBOL_INVENTORY)
        bad["count"] = 1
        with self.assertRaisesRegex(validator.ValidationError, "count mismatch"):
            validator.validate_exported_symbols({"exported_symbol_inventory": bad})
        bad = copy.deepcopy(EMPTY_SYMBOL_INVENTORY)
        bad["symbols"] = ["wirestack_export"]
        bad["count"] = 1
        with self.assertRaisesRegex(validator.ValidationError, "digest mismatch"):
            validator.validate_exported_symbols({"exported_symbol_inventory": bad})

        static_link_symbols = [f"provider_symbol_{index:05d}" for index in range(10000)]
        encoded = "".join(f"{symbol}\n" for symbol in static_link_symbols).encode("utf-8")
        validator.validate_exported_symbols({
            "exported_symbol_inventory": {
                "scope": "final-artifact-exports",
                "tool": "fixture-tool",
                "count": len(static_link_symbols),
                "sha256": runner.hashlib.sha256(encoded).hexdigest(),
                "symbols": static_link_symbols,
            },
        })

        too_many_symbols = [
            f"provider_symbol_{index:05d}"
            for index in range(validator.MAX_EXPORTED_SYMBOLS + 1)
        ]
        with self.assertRaisesRegex(validator.ValidationError, "exceeds its bound"):
            validator.validate_exported_symbols({
                "exported_symbol_inventory": {
                    "scope": "final-artifact-exports",
                    "tool": "fixture-tool",
                    "count": len(too_many_symbols),
                    "sha256": "0" * 64,
                    "symbols": too_many_symbols,
                },
            })

    def test_missing_archive_digest_fails(self):
        value = copy.deepcopy(self.spec)
        value["providers"][1].pop("sha256")
        with self.assertRaises(validator.ValidationError):
            validator.validate_spec(value)

    def test_archive_provider_requires_exact_commit(self):
        value = copy.deepcopy(self.spec)
        value["providers"][2].pop("commit")
        value["providers"][2]["commit_resolution_url"] = (
            "https://api.github.com/repos/openssl/openssl/git/ref/tags/openssl-3.6.4"
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
        result = complete_result(
            self.spec, provider=cell["provider"], platform=cell["platform"],
            status="PARTIAL",
        )
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

    def test_schema_v1_partial_cannot_claim_unmeasured_external_trust(self):
        caps = {name: "BLOCKED" for name in self.spec["required_capabilities"]}
        caps["external_trust"] = "PASS"
        result = {
            "schema_version": 1,
            "task_id": "M0-016",
            "provider": "mbedtls",
            "platform": "linux-glibc-x86_64",
            "status": "PARTIAL",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "build": {
                "static_archives": ["libmbedtls.a"],
                "system_tls_dependencies": [],
                "runtime_loader_library_strings": [],
            },
        }
        with self.assertRaisesRegex(validator.ValidationError, "unsupported result schema"):
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
            "alpn_no_overlap_handshakes": 2,
            "alpn_malformed_inputs_rejected": 2,
        }
        with self.assertRaisesRegex(validator.ValidationError, "unsupported result schema"):
            validator.validate_result(result, self.spec)

    def test_schema_v5_requires_measured_session_resumption(self):
        result = complete_result(self.spec)
        result["metrics"]["session_resumption_handshakes"] = 1
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
            *required_profile_metrics(),
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

    def test_metrics_require_negative_alpn_coverage(self):
        caps = {name: "BLOCKED" for name in self.spec["required_capabilities"]}
        caps["sni_hostname_alpn"] = "PASS"
        complete = "\n".join([
            "METRIC repeated_cleanup_cycles=10000",
            "METRIC alpn_no_overlap_handshakes=2",
            "METRIC alpn_malformed_inputs_rejected=2",
            *required_profile_metrics(),
        ])
        metrics = runner.parse_metrics(complete, "openssl", caps)
        self.assertEqual(2, metrics["alpn_no_overlap_handshakes"])
        with self.assertRaisesRegex(runner.PocError, "ALPN evidence"):
            runner.parse_metrics(
                complete.replace("alpn_malformed_inputs_rejected=2",
                                 "alpn_malformed_inputs_rejected=1"),
                "openssl",
                caps,
            )

    def test_metrics_require_expired_and_malformed_certificate_coverage(self):
        caps = {name: "BLOCKED" for name in self.spec["required_capabilities"]}
        caps["negative_expired_certificate"] = "PASS"
        caps["negative_malformed_certificate"] = "PASS"
        complete = "\n".join([
            "METRIC repeated_cleanup_cycles=10000",
            "METRIC certificate_negative_cases_rejected=2",
            *required_profile_metrics(),
        ])
        metrics = runner.parse_metrics(complete, "openssl", caps)
        self.assertEqual(2, metrics["certificate_negative_cases_rejected"])
        with self.assertRaisesRegex(runner.PocError, "certificate evidence"):
            runner.parse_metrics(
                complete.replace("certificate_negative_cases_rejected=2",
                                 "certificate_negative_cases_rejected=1"),
                "openssl",
                caps,
            )

    def test_native_pocs_expose_external_trust_as_a_distinct_capability(self):
        openssl_source = (ROOT / "tools/tls_provider_poc/openssl_memory_poc.c").read_text()
        mbedtls_source = (ROOT / "tools/tls_provider_poc/mbedtls_memory_poc.c").read_text()
        for source in (openssl_source, mbedtls_source):
            self.assertIn("CAP external_trust=%s", source)
            self.assertIn("external_trust_calls", source)

    def test_metrics_require_required_and_optional_client_auth(self):
        caps = {name: "BLOCKED" for name in self.spec["required_capabilities"]}
        caps["mtls"] = "PASS"
        complete = "\n".join([
            "METRIC repeated_cleanup_cycles=10000",
            "METRIC mtls_required_handshakes=1",
            "METRIC mtls_optional_handshakes=2",
            *required_profile_metrics(),
        ])
        self.assertEqual(2, runner.parse_metrics(complete, "openssl", caps)[
            "mtls_optional_handshakes"
        ])
        with self.assertRaisesRegex(runner.PocError, "required and optional"):
            runner.parse_metrics(
                complete.replace("mtls_optional_handshakes=2",
                                 "mtls_optional_handshakes=1"),
                "openssl", caps,
            )

    def test_musl_result_requires_immutable_container_identity(self):
        result = complete_result(self.spec, platform="linux-musl-x86_64")
        validator.validate_result(result, self.spec, "2" * 40)
        result["execution"]["container_image"] = "alpine:3.22"
        with self.assertRaisesRegex(validator.ValidationError, "immutable Alpine"):
            validator.validate_result(result, self.spec, "2" * 40)

    def test_memory_diagnostic_records_provider_leak_detection_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "provider-poc-diagnostic"
            archive = root / "libprovider.a"
            archive.write_bytes(b"instrumented archive")
            fixtures = root / "fixtures"
            completed = runner.subprocess.CompletedProcess(
                [str(binary)], 0, "diagnostic pass\n", ""
            )
            with mock.patch.object(runner, "compile_poc", return_value=binary), \
                    mock.patch.object(runner, "build_provider") as build_mock, \
                    mock.patch.object(runner, "run", return_value=completed) as run_mock:
                def diagnostic_build(spec, *_args, **_kwargs):
                    return (
                        root,
                        [archive],
                        build_provenance_fixture(
                            spec["id"], "linux-glibc-x86_64", diagnostic=True),
                    )
                build_mock.side_effect = diagnostic_build
                aws = runner.run_native_memory_diagnostic(
                    {"id": "aws-lc"}, root, root / "src", root, root / "log",
                    fixtures, "linux-glibc-x86_64",
                )
                self.assertEqual("UNSUPPORTED", aws["leak_detection"]["status"])
                self.assertIn("detect_leaks=0", run_mock.call_args.kwargs["env"]["ASAN_OPTIONS"])
                openssl = runner.run_native_memory_diagnostic(
                    {"id": "openssl"}, root, root / "src", root, root / "log",
                    fixtures, "linux-glibc-x86_64",
                )
                self.assertEqual("UNSUPPORTED", openssl["leak_detection"]["status"])
                self.assertIn("detect_leaks=0", run_mock.call_args.kwargs["env"]["ASAN_OPTIONS"])
                mbedtls = runner.run_native_memory_diagnostic(
                    {"id": "mbedtls"}, root, root / "src", root, root / "log",
                    fixtures, "linux-glibc-x86_64",
                )
                self.assertEqual("PASS", mbedtls["leak_detection"]["status"])
                self.assertIn("detect_leaks=1", run_mock.call_args.kwargs["env"]["ASAN_OPTIONS"])

    def test_diagnostic_build_instruments_provider_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            calls = []

            def fake_run(command, **_kwargs):
                calls.append(list(command))
                output = "fixture tool 1.0" if "--version" in command else ""
                return runner.subprocess.CompletedProcess(command, 0, output, "")

            with mock.patch.object(runner, "is_windows", return_value=False), \
                    mock.patch.object(runner, "platform_id", return_value="linux-glibc-x86_64"), \
                    mock.patch.object(runner, "run", side_effect=fake_run), \
                    mock.patch.object(runner, "find_provider_archives",
                                      return_value=[root / "libssl.a"]):
                _prefix, _archives, provenance = runner.build_provider(
                    {"id": "aws-lc"}, source, root / "work", root / "build.log",
                    repo=ROOT, diagnostic=True)
            configure = calls[0]
            self.assertIn("-DOPENSSL_NO_ASM=ON", configure)
            self.assertIn(
                "-DCMAKE_C_FLAGS=-O1 -g -fsanitize=address,undefined "
                "-fno-omit-frame-pointer -Wno-error=array-bounds",
                configure,
            )
            self.assertTrue(provenance["provider_instrumented"])
            self.assertEqual("address+undefined-sanitizer", provenance["instrumentation"])

    def test_openssl_build_retains_musl_secure_heap_override_in_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            calls = []

            def fake_run(command, **_kwargs):
                calls.append(list(command))
                output = "fixture tool 1.0" if "--version" in command else ""
                return runner.subprocess.CompletedProcess(command, 0, output, "")

            with mock.patch.object(runner, "is_windows", return_value=False), \
                    mock.patch.object(runner, "platform_id",
                                      return_value="linux-musl-x86_64"), \
                    mock.patch.object(runner, "run", side_effect=fake_run), \
                    mock.patch.object(runner, "find_provider_archives",
                                      return_value=[root / "libssl.a"]):
                _prefix, _archives, provenance = runner.build_provider(
                    {"id": "openssl"}, source, root / "work", root / "build.log",
                    repo=ROOT, extra_configure_args=("no-secure-memory",))
            self.assertIn("no-secure-memory", calls[0])
            self.assertIn("no-secure-memory", provenance["configure_argv"])

    def test_platform_peak_resident_probes_are_native(self):
        openssl_source = (ROOT / "tools/tls_provider_poc/openssl_memory_poc.c").read_text()
        mbedtls_source = (ROOT / "tools/tls_provider_poc/mbedtls_memory_poc.c").read_text()
        musl_runner = (ROOT / "tools/tls_provider_poc/run_musl.py").read_text()
        cancel_header = (ROOT / "tools/tls_provider_poc/poc_cancel.h").read_text()
        for source in (openssl_source, mbedtls_source):
            self.assertIn("GetProcessMemoryInfo", source)
            self.assertIn("mach_task_basic_info_data_t", source)
            self.assertIn("getrusage(RUSAGE_SELF", source)
            self.assertIn("PROVIDER_ALLOCATION_CALL_BOUND 150000000ULL", source)
        self.assertEqual(150_000_000, runner.PROVIDER_ALLOCATION_CALL_BOUND)
        self.assertEqual(runner.PROVIDER_ALLOCATION_CALL_BOUND,
                         validator.PROVIDER_ALLOCATION_CALL_BOUND)
        self.assertIn("repo=repo, diagnostic=diagnostic", musl_runner)
        self.assertIn('extra_configure_args=("no-secure-memory",)', musl_runner)
        self.assertIn("typedef DWORD (WINAPI *PocThreadRoutine)(LPVOID);",
                      cancel_header)
        self.assertIn("typedef void *(*PocThreadRoutine)(void *);", cancel_header)

    def test_supported_diagnostic_requires_instrumented_provider_archives(self):
        result = complete_result(self.spec)
        result["operational_evidence"]["native_memory_diagnostic"][
            "provider_instrumented"] = False
        with self.assertRaisesRegex(validator.ValidationError, "instrument provider"):
            validator.validate_result(result, self.spec)

    def test_provider_allocation_and_cancellation_metrics_fail_closed(self):
        result = complete_result(self.spec)
        result["metrics"]["provider_allocation_calls"] = 0
        with self.assertRaisesRegex(validator.ValidationError, "provider allocation call"):
            validator.validate_result(result, self.spec)
        result = complete_result(self.spec)
        result["metrics"]["cancellation_latency_us"] = (
            validator.CANCELLATION_WAKE_BOUND_US + 1)
        with self.assertRaisesRegex(validator.ValidationError, "wake latency"):
            validator.validate_result(result, self.spec)
        result = complete_result(self.spec)
        result["operational_evidence"]["memory_profile"][
            "provider_allocation_live_after_cleanup_bytes"] = 65 * 1024
        result["metrics"]["provider_allocation_live_after_cleanup_bytes"] = 65 * 1024
        with self.assertRaisesRegex(validator.ValidationError, "live-allocation growth"):
            validator.validate_result(result, self.spec)

    def test_build_provenance_is_durable_and_fail_closed(self):
        result = complete_result(self.spec, platform="windows-x86_64")
        validator.validate_result(result, self.spec)
        result["build"]["provenance"]["configure_argv"] = []
        with self.assertRaisesRegex(validator.ValidationError, "configure argv"):
            validator.validate_result(result, self.spec)
        result = complete_result(self.spec, platform="windows-x86_64")
        result["build"]["provenance"]["compiler"]["exit_code"] = 1
        with self.assertRaisesRegex(validator.ValidationError, "identity command failed"):
            validator.validate_result(result, self.spec)
        result = complete_result(self.spec, platform="windows-x86_64")
        result["build"]["provenance"]["environment"].pop("PATH")
        with self.assertRaisesRegex(validator.ValidationError, "environment key set"):
            validator.validate_result(result, self.spec)
        result = complete_result(self.spec, platform="windows-x86_64")
        result["build"]["provenance"]["environment"]["PATH"] = ""
        with self.assertRaisesRegex(validator.ValidationError, "PATH required"):
            validator.validate_result(result, self.spec)

    def test_build_environment_captures_inherited_and_override_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            repo = root / "repo"
            inherited = {
                "PATH": f"{work.resolve()}/bin:/usr/bin",
                "CC": "clang",
                "INCLUDE": r"C:\\SDK\\include",
            }
            captured = runner.capture_build_environment(
                inherited,
                {"CFLAGS": "-O2 -fPIC"},
                {work: "<WORK>", repo: "<REPOSITORY>"},
            )
        self.assertEqual(set(runner.BUILD_ENVIRONMENT_KEYS), set(captured))
        self.assertEqual("<WORK>/bin:/usr/bin", captured["PATH"])
        self.assertEqual("clang", captured["CC"])
        self.assertEqual("-O2 -fPIC", captured["CFLAGS"])
        self.assertEqual(r"C:\\SDK\\include", captured["INCLUDE"])
        self.assertEqual("", captured["CXX"])

    def test_build_environment_snapshot_is_bounded(self):
        environment = {"PATH": "x" * (runner.MAX_BUILD_ENVIRONMENT_VALUE_BYTES + 1)}
        with self.assertRaisesRegex(runner.PocError, "value exceeds its bound"):
            runner.capture_build_environment(environment, {}, {})

    def test_pre_execution_fail_result_is_retained_without_metrics(self):
        result = complete_result(self.spec)
        result["status"] = "FAIL"
        result["source"] = {}
        result["capabilities"] = {
            name: "NOT_RUN" for name in self.spec["required_capabilities"]
        }
        result["build"] = {"static_archives": [], "system_tls_dependencies": []}
        result.pop("metrics")
        result.pop("operational_evidence")
        result["failure"] = {
            "stage": "source-acquisition",
            "error_type": "PocError",
            "message": "pinned source digest mismatch",
        }
        validator.validate_result(result, self.spec)
        result["failure"]["stage"] = "provider-build"
        with self.assertRaisesRegex(validator.ValidationError, "source identity"):
            validator.validate_result(result, self.spec)

    def test_failure_messages_are_bounded_by_utf8_bytes(self):
        message = runner.bounded_utf8("雪" * 2048, runner.MAX_FAILURE_MESSAGE_BYTES)
        self.assertLessEqual(
            len(message.encode("utf-8")), runner.MAX_FAILURE_MESSAGE_BYTES)
        self.assertTrue(message)

    def test_license_bundle_rejects_escape_and_stale_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = root / "license-bundle/files"
            files.mkdir(parents=True)
            license_path = files / "LICENSE"
            license_path.write_text("fixture license\n", encoding="utf-8")
            result = complete_result(self.spec)
            entry = {
                "path": "LICENSE",
                "bytes": license_path.stat().st_size,
                "sha256": validator.sha256_path(license_path),
            }
            manifest = {
                "schema_version": 1,
                "task_id": "M0-016",
                "provider": result["provider"],
                "source_content_sha256": result["source"]["content_sha256"],
                "file_count": 1,
                "total_bytes": entry["bytes"],
                "files": [entry],
            }
            manifest_path = root / "license-bundle/manifest.json"
            runner.atomic_json(manifest_path, manifest)
            result["build"]["license_bundle"] = {
                "path": "license-bundle/manifest.json",
                "sha256": validator.sha256_path(manifest_path),
                "file_count": 1,
                "total_bytes": entry["bytes"],
            }
            result_path = root / "result.json"
            validator.validate_license_bundle(result_path, result)
            result["build"]["license_bundle"]["path"] = "../manifest.json"
            with self.assertRaisesRegex(validator.ValidationError, "escapes"):
                validator.validate_license_bundle(result_path, result)
            result["build"]["license_bundle"]["path"] = "license-bundle/manifest.json"
            result["build"]["license_bundle"]["sha256"] = "f" * 64
            with self.assertRaisesRegex(validator.ValidationError, "digest mismatch"):
                validator.validate_license_bundle(result_path, result)

    def test_license_bundle_ignores_symlinks_outside_provider_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "LICENSE").write_text("inside\n", encoding="utf-8")
            outside = root / "NOTICE"
            outside.write_text("outside\n", encoding="utf-8")
            (source / "NOTICE").symlink_to(outside)
            output = root / "output"
            info = runner.create_license_bundle(
                source, output, "aws-lc", {"content_sha256": "0" * 64})
            manifest = json.loads((output / info["path"]).read_text())
            self.assertEqual(["LICENSE"], [entry["path"] for entry in manifest["files"]])

    def test_matrix_retained_result_validates_durable_license_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result_path = root / "results/aws-lc.json"
            result_path.parent.mkdir(parents=True)
            result = complete_result(self.spec)
            files = root / "licenses/aws-lc/files"
            files.mkdir(parents=True)
            license_path = files / "LICENSE"
            license_path.write_text("fixture license\n", encoding="utf-8")
            entry = {
                "path": "LICENSE",
                "bytes": license_path.stat().st_size,
                "sha256": validator.sha256_path(license_path),
            }
            manifest = {
                "schema_version": 1,
                "task_id": "M0-016",
                "provider": "aws-lc",
                "source_content_sha256": result["source"]["content_sha256"],
                "file_count": 1,
                "total_bytes": entry["bytes"],
                "files": [entry],
            }
            manifest_path = root / "licenses/aws-lc/manifest.json"
            runner.atomic_json(manifest_path, manifest)
            manifest_digest = validator.sha256_path(manifest_path)
            result["build"]["license_bundle"].update({
                "sha256": manifest_digest,
                "file_count": 1,
                "total_bytes": entry["bytes"],
            })
            runner.atomic_json(result_path, result)
            matrix = {"cells": [{
                "provider": "aws-lc",
                "platform": "linux-glibc-x86_64",
                "status": "PASS",
                "result": "results/aws-lc.json",
                "sha256": validator.sha256_path(result_path),
                "license_bundle": {
                    "manifest": "licenses/aws-lc/manifest.json",
                    "sha256": manifest_digest,
                },
            }]}
            validator.validate_retained_results(matrix, self.spec, root)
            license_path.write_text("tampered\n", encoding="utf-8")
            with self.assertRaisesRegex(validator.ValidationError, "mismatch"):
                validator.validate_retained_results(matrix, self.spec, root)

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
        external_trust_source = mbedtls_source[
            mbedtls_source.index("static int external_trust_version_case"):
            mbedtls_source.index("static int external_trust_case")
        ]
        self.assertIn(
            "configure(m, &client_conf, &server_conf, version, 0, 0)",
            external_trust_source,
        )
        self.assertNotIn(
            "configure(m, &client_conf, &server_conf, version, 0, 1)",
            external_trust_source,
        )
        self.assertIn(
            "mbedtls_ssl_conf_ca_chain(&client_conf, &m->client_cert, NULL);",
            mbedtls_source,
        )
        self.assertIn("Pair provider_rejected;", mbedtls_source)
        for source in (openssl_source, mbedtls_source):
            self.assertIn("#define _DARWIN_C_SOURCE", source)
            self.assertIn("alpn_no_overlap_version_case", source)
            self.assertIn("alpn_malformed_case", source)
            self.assertIn("METRIC alpn_no_overlap_handshakes=%d", source)
            self.assertIn("METRIC alpn_malformed_inputs_rejected=%d", source)
            self.assertIn("CAP negative_expired_certificate=%s", source)
            self.assertIn("CAP negative_malformed_certificate=%s", source)
            self.assertIn("METRIC certificate_negative_cases_rejected=%d", source)
            self.assertIn("METRIC mtls_required_handshakes=%d", source)
            self.assertIn("METRIC mtls_optional_handshakes=%d", source)
            self.assertIn("METRIC memory_profile_peak_resident_bytes=%llu", source)
            self.assertIn("METRIC provider_allocation_calls=%llu", source)
            self.assertIn("METRIC provider_allocation_peak_live_bytes=%llu", source)
            self.assertIn("METRIC cancellation_latency_us=%llu", source)
            self.assertIn("poc_cancel_trigger_and_join", source)
            self.assertIn("provider_allocation_calls", source)
            self.assertIn("provider_allocation_live_bytes", source)
        self.assertIn("CRYPTO_set_mem_functions", openssl_source)
        self.assertIn("mbedtls_platform_set_calloc_free", mbedtls_source)
        self.assertIn("char overlong_protocol[257]", openssl_source)
        self.assertNotIn("static const unsigned char truncated[]", openssl_source)
        self.assertIn("OPENSSL_thread_stop();", openssl_source)
        self.assertIn("OPENSSL_cleanup();", openssl_source)

        allocation_header = (
            ROOT / "tools/tls_provider_poc/poc_allocation_profile.h"
        ).read_text()
        self.assertIn("max_align_t alignment", allocation_header)
        self.assertIn("union __declspec(align(16)) PocAllocationHeader",
                      allocation_header)
        self.assertIn("unsigned char alignment[16]", allocation_header)
        self.assertIn('"-std=c11", *diagnostic_flags', RUN_MODULE.read_text())
        cancel_header = (ROOT / "tools/tls_provider_poc/poc_cancel.h").read_text()
        self.assertNotIn("WaitForSingleObject(thread, INFINITE)", cancel_header)
        self.assertNotIn("CLOCK_REALTIME", cancel_header)
        self.assertIn("pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC)",
                      cancel_header)
        self.assertIn("pthread_cond_timedwait_relative_np", cancel_header)
        self.assertIn("gate->joined", cancel_header)


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

    def test_digest_bound_license_bundles_disable_checkout_conversion(self):
        attributes = (ROOT / ".gitattributes").read_text(encoding="utf-8")
        self.assertIn(
            "docs/evidence/M0-016/license-bundles/** -text\n",
            attributes,
        )

    def test_windows_dependency_scan_rejects_versioned_tls_dll(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "provider-poc.exe"
            archive = root / "ssl.lib"
            log = root / "build.log"
            binary.write_bytes(b"PE fixture")
            archive.write_bytes(b"archive")
            dependents = runner.subprocess.CompletedProcess(
                ["dumpbin"], 0, "LIBSSL-3-X64.DLL\nKERNEL32.dll\n", ""
            )
            exports = runner.subprocess.CompletedProcess(
                ["dumpbin"], 0, "Dump of file provider-poc.exe\n\n  Summary\n", ""
            )
            with mock.patch.object(runner, "is_windows", return_value=True), \
                    mock.patch.object(runner, "run", side_effect=[dependents, exports]) as run_mock:
                result = runner.inspect_binary(binary, [archive], root, log)
            self.assertEqual(["LIBSSL-3-X64.DLL"], result["system_tls_dependencies"])
            self.assertEqual(2, run_mock.call_count)
            run_mock.assert_any_call(
                ["dumpbin", "/dependents", str(binary)], cwd=root, log=log, check=False
            )
            run_mock.assert_any_call(
                ["dumpbin", "/exports", str(binary)], cwd=root, log=log, check=False
            )

    def test_windows_export_scan_rejects_unrecognized_success_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "provider-poc.exe"
            binary.write_bytes(b"PE fixture")
            completed = runner.subprocess.CompletedProcess(["dumpbin"], 0, "", "")
            with mock.patch.object(runner, "is_windows", return_value=True), \
                    mock.patch.object(runner, "run", return_value=completed):
                with self.assertRaisesRegex(runner.PocError, "not recognized"):
                    runner.exported_symbol_inventory(binary, root, root / "build.log")

    def test_linux_export_scan_retains_symbols_from_multiline_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "provider-poc"
            completed = runner.subprocess.CompletedProcess(
                ["nm"], 0,
                "0000000000001000 T main\n0000000000002000 T wirestack_export\n", "",
            )
            with mock.patch.object(runner, "is_windows", return_value=False), \
                    mock.patch.object(runner.sys, "platform", "linux"), \
                    mock.patch.object(runner, "run", return_value=completed):
                inventory = runner.exported_symbol_inventory(
                    binary, root, root / "build.log"
                )
            self.assertEqual(2, inventory["count"])
            self.assertEqual(["main", "wirestack_export"], inventory["symbols"])

    def test_windows_export_scan_retains_symbols_from_multiline_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "provider-poc.exe"
            completed = runner.subprocess.CompletedProcess(
                ["dumpbin"], 0,
                "Dump of file provider-poc.exe\n\n"
                "          1    0 00011000 wirestack_export\n\n"
                "  Summary\n", "",
            )
            with mock.patch.object(runner, "is_windows", return_value=True), \
                    mock.patch.object(runner, "run", return_value=completed):
                inventory = runner.exported_symbol_inventory(
                    binary, root, root / "build.log"
                )
            self.assertEqual(1, inventory["count"])
            self.assertEqual(["wirestack_export"], inventory["symbols"])

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
            self.assertIn("psapi.lib", command)

    def test_windows_openssl_build_uses_vc_target_and_nmake(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "source"
            prefix = root / "prefix"
            src.mkdir()
            calls = []

            def fake_run(command, **kwargs):
                calls.append(list(command))
                output = "fixture tool 1.0" if (
                    "--version" in command or "/Bv" in command or "/?" in command
                ) else ""
                return runner.subprocess.CompletedProcess(command, 0, output, "")

            with mock.patch.object(runner, "is_windows", return_value=True), \
                    mock.patch.object(runner, "run", side_effect=fake_run), \
                    mock.patch.object(runner, "find_provider_archives", return_value=[root / "libssl.lib"]):
                runner.build_provider({"id": "openssl"}, src, root, root / "build.log")
            self.assertEqual("perl", calls[0][0])
            self.assertIn("VC-WIN64A", calls[0])
            self.assertEqual(["nmake"], calls[1])
            self.assertEqual(["nmake", "install_sw"], calls[2])
            self.assertEqual(2, calls.count(["cl", "/?"]))

    def test_windows_result_requires_native_hosted_runner_identity(self):
        result = complete_result(self.spec, platform="windows-x86_64")
        validator.validate_result(result, self.spec, "2" * 40)
        result["execution"]["runner_os"] = "Linux"
        with self.assertRaisesRegex(validator.ValidationError, "native Windows runner"):
            validator.validate_result(result, self.spec, "2" * 40)

    def test_expected_revision_mismatch_fails(self):
        result = complete_result(self.spec, platform="windows-x86_64")
        with self.assertRaisesRegex(validator.ValidationError, "revision mismatch"):
            validator.validate_result(result, self.spec, "3" * 40)


if __name__ == "__main__":
    unittest.main()

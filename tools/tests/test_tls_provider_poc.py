from __future__ import annotations

from tools import evidence_digest

import copy
import datetime as dt
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
        "output_sha256": evidence_digest.text_evidence_bytes_sha256(output.encode()),
    }


def build_provenance_fixture(provider, platform, *, diagnostic=False):
    triples = {
        "linux-glibc-x86_64": "x86_64-unknown-linux-gnu",
        "linux-musl-x86_64": "x86_64-unknown-linux-musl",
        "windows-x86_64": "x86_64-pc-windows-msvc",
        "macos-arm64": "arm64-apple-darwin",
        "android-aarch64": "aarch64-linux-android",
        "android-x86_64": "x86_64-linux-android",
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
        "assembler": (
            tool_identity_fixture("nasm")
            if provider == "aws-lc" and platform == "windows-x86_64" and
            not diagnostic else None
        ),
        "configure_argv": configure,
        "build_argv": [["build-tool", "<BUILD>"], ["build-tool", "<PREFIX>"]],
        "environment": {
            key: ("/usr/bin:/bin" if key == "PATH" else "")
            for key in runner.BUILD_ENVIRONMENT_KEYS
        },
        "patches": [],
        "patch_set_sha256": evidence_digest.text_evidence_bytes_sha256(b"[]\n"),
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
    if platform == "windows-x86_64":
        runner_os, runner_arch, image_os = "Windows", "X64", "win25"
    elif platform == "macos-arm64":
        runner_os, runner_arch, image_os = "macOS", "ARM64", "macos15"
    else:
        runner_os, runner_arch, image_os = "Linux", "X64", "ubuntu24"
    execution = {
        "repository_revision": "2" * 40,
        "runner_os": runner_os,
        "runner_arch": runner_arch,
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
        "local_close_operations": 2,
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
        "poc_exit_code": 0,
        "source": {
            "content_sha256": provider_spec.get(
                "sha256", provider_spec.get("content_sha256")),
            "commit": provider_spec["commit"],
            "kind": provider_spec["source_kind"],
            "security_update": copy.deepcopy(provider_spec["security_update"]),
            **({"tree": provider_spec["tree"]}
               if provider_spec["source_kind"] == "git" else {
                   "tag": provider_spec["tag"],
                   "tag_resolved_commit": provider_spec["commit"],
               }),
        },
        "capabilities": caps,
        "metrics": metrics,
        "build": {
            "binary_bytes": 1,
            "binary_sha256": "8" * 64,
            "static_archives": [{
                "name": "libssl.a",
                "bytes": 1,
                "sha256": "6" * 64,
            }],
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
                "cleanup_cycles": 10,
                "output_sha256": "7" * 64,
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
        "METRIC local_close_operations=2",
    ]


class ProviderPocValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = json.loads((ROOT / "tools/tls_provider_poc/providers.json").read_text())
        cls.matrix = json.loads((ROOT / "docs/evidence/M0-016/platform-matrix.json").read_text())

    def test_canonical_spec_and_matrix_reject_stale_license_digests(self):
        validator.validate_spec(self.spec)
        validator.validate_matrix(self.matrix, self.spec)
        with self.assertRaisesRegex(
                validator.ValidationError, "provider license file digest mismatch"):
            validator.validate_retained_results(self.matrix, self.spec, ROOT)
        for provider in self.spec["providers"]:
            workflow = provider["security_update"]["update_workflow"]
            self.assertTrue((ROOT / workflow).is_file())

    def test_matrix_contract_only_does_not_promote_stale_retained_results(self):
        matrix = ROOT / "docs/evidence/M0-016/platform-matrix.json"
        self.assertEqual(
            0, validator.main(["--matrix", str(matrix), "--matrix-contract-only"]))
        self.assertEqual(1, validator.main(["--matrix-contract-only"]))

        for workflow in (
                ROOT / ".github/workflows/tls-provider-poc.yml",
                ROOT / ".github/workflows/m0-016-windows-provider-poc.yml"):
            text = workflow.read_text(encoding="utf-8")
            self.assertIn("--matrix-contract-only", text)

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

        value = copy.deepcopy(self.spec)
        maximum_age = value["providers"][0]["security_update"][
            "maximum_source_pin_age_days"]
        value["providers"][0]["security_update"]["source_committed_at"] = (
            dt.datetime.now(dt.timezone.utc) -
            dt.timedelta(days=maximum_age, hours=1)
        ).isoformat()
        with self.assertRaisesRegex(validator.ValidationError,
                                    "source pin is stale"):
            validator.validate_spec(value)

        value = copy.deepcopy(self.spec)
        value["providers"][0]["security_update"]["advisory_disposition"][
            "reviewed_through"] = (
                dt.datetime.now(dt.timezone.utc) -
                dt.timedelta(days=31, hours=1)
            ).isoformat()
        with self.assertRaisesRegex(validator.ValidationError,
                                    "advisory disposition is stale"):
            validator.validate_spec(value)

    def test_retained_source_identity_matches_provider_pin(self):
        result = complete_result(self.spec)
        result["source"]["commit"] = "f" * 40
        with self.assertRaisesRegex(validator.ValidationError,
                                    "source commit does not match"):
            validator.validate_result(result, self.spec)

        result = complete_result(self.spec)
        result["source"]["tree"] = "f" * 40
        with self.assertRaisesRegex(validator.ValidationError,
                                    "source tree does not match"):
            validator.validate_result(result, self.spec)

        result = complete_result(self.spec, provider="openssl")
        result["source"]["content_sha256"] = "f" * 64
        with self.assertRaisesRegex(validator.ValidationError,
                                    "archive digest does not match"):
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
                "sha256": evidence_digest.text_evidence_bytes_sha256(encoded),
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
        with self.assertRaises(validator.ValidationError):
            validator.validate_spec(value)

    def test_archive_provider_requires_release_tag_resolution(self):
        value = copy.deepcopy(self.spec)
        value["providers"][1].pop("tag")
        with self.assertRaisesRegex(validator.ValidationError,
                                    "release tag required"):
            validator.validate_spec(value)

        value = copy.deepcopy(self.spec)
        value["providers"][1].pop("commit_resolution_url")
        with self.assertRaisesRegex(validator.ValidationError,
                                    "release tag resolution URL required"):
            validator.validate_spec(value)

    def test_archive_source_resolves_and_matches_release_tag_commit(self):
        provider = copy.deepcopy(self.spec["providers"][1])
        payload = b"archive fixture"
        provider["sha256"] = evidence_digest.artifact_bytes_sha256(payload)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            extracted = root / "extracted"
            extracted.mkdir()

            def write_archive(_url, destination):
                destination.write_bytes(payload)

            with mock.patch.object(runner, "download", side_effect=write_archive), \
                    mock.patch.object(runner, "safe_extract",
                                      return_value=extracted), \
                    mock.patch.object(runner, "resolve_git_tag",
                                      return_value=provider["commit"]) as resolve:
                source, identity = runner.source_provider(
                    provider, root / "work", root / "build.log")

            self.assertEqual(extracted, source)
            self.assertEqual(provider["tag"], identity["tag"])
            self.assertEqual(provider["commit"],
                             identity["tag_resolved_commit"])
            resolve.assert_called_once_with(provider["commit_resolution_url"])

            with mock.patch.object(runner, "download", side_effect=write_archive), \
                    mock.patch.object(runner, "safe_extract",
                                      return_value=extracted), \
                    mock.patch.object(runner, "resolve_git_tag",
                                      return_value="0" * 40):
                with self.assertRaisesRegex(runner.PocError,
                                            "release tag commit mismatch"):
                    runner.source_provider(
                        provider, root / "mismatch", root / "mismatch.log")

    def test_github_tag_resolution_uses_bounded_ephemeral_token(self):
        with mock.patch.dict(runner.os.environ,
                             {"WIRESTACK_GITHUB_TOKEN": "fixture-secret"}):
            headers = runner.github_api_headers()
        self.assertEqual("Bearer fixture-secret", headers["Authorization"])
        self.assertNotIn("WIRESTACK_GITHUB_TOKEN",
                         runner.BUILD_ENVIRONMENT_KEYS)

        with mock.patch.dict(runner.os.environ,
                             {"WIRESTACK_GITHUB_TOKEN": ""}):
            self.assertNotIn("Authorization", runner.github_api_headers())

        with mock.patch.dict(runner.os.environ,
                             {"WIRESTACK_GITHUB_TOKEN": "x" * 4097}):
            with self.assertRaisesRegex(runner.PocError,
                                        "token exceeds its bound"):
                runner.github_api_headers()

    def test_provider_subprocesses_cannot_inherit_github_token(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            completed = runner.subprocess.CompletedProcess(
                ["fixture"], 0, "", "")
            with mock.patch.dict(runner.os.environ,
                                 {"WIRESTACK_GITHUB_TOKEN": "fixture-secret"}), \
                    mock.patch.object(runner.subprocess, "run",
                                      return_value=completed) as execute:
                runner.run(["fixture"], cwd=root, log=root / "build.log")
            self.assertNotIn("WIRESTACK_GITHUB_TOKEN",
                             execute.call_args.kwargs["env"])

            with mock.patch.object(runner.subprocess, "run",
                                   return_value=completed) as execute:
                runner.run(
                    ["fixture"], cwd=root, log=root / "build.log",
                    env={"PATH": "/fixture", "WIRESTACK_GITHUB_TOKEN": "secret"},
                )
            self.assertEqual("/fixture", execute.call_args.kwargs["env"]["PATH"])
            self.assertNotIn("WIRESTACK_GITHUB_TOKEN",
                             execute.call_args.kwargs["env"])

    def test_local_execution_identity_uses_clean_exact_checkout(self):
        clean = mock.Mock(returncode=0, stdout="")
        revision = mock.Mock(returncode=0, stdout="a" * 40 + "\n")
        with mock.patch.dict(
                runner.os.environ, {
                    "GITHUB_SHA": "",
                    "RUNNER_OS": "fixture-os",
                    "RUNNER_ARCH": "fixture-arch",
                    "ImageOS": "",
                    "ImageVersion": "",
                }, clear=False), \
                mock.patch.object(
                    runner, "run", side_effect=[clean, revision]):
            identity = runner.execution_identity(ROOT, ROOT / "unused.log")
        self.assertEqual(identity["repository_revision"], "a" * 40)
        self.assertTrue(identity["image_os"].startswith("local-"))
        self.assertTrue(identity["image_version"])

    def test_local_execution_identity_rejects_dirty_checkout(self):
        dirty = mock.Mock(returncode=0, stdout=" M tracked-file\n")
        with mock.patch.dict(
                runner.os.environ, {"GITHUB_SHA": ""}, clear=False), \
                mock.patch.object(runner, "run", return_value=dirty):
            with self.assertRaisesRegex(
                    runner.PocError, "local repository has tracked modifications"):
                runner.execution_identity(ROOT, ROOT / "unused.log")

    def test_hosted_execution_identity_matches_clean_checkout(self):
        clean = mock.Mock(returncode=0, stdout="")
        revision = mock.Mock(returncode=0, stdout="a" * 40 + "\n")
        with mock.patch.dict(
                runner.os.environ, {"GITHUB_SHA": "a" * 40}, clear=False), \
                mock.patch.object(
                    runner, "run", side_effect=[clean, revision]):
            identity = runner.execution_identity(ROOT, ROOT / "unused.log")
        self.assertEqual(identity["repository_revision"], "a" * 40)

    def test_hosted_execution_identity_rejects_revision_mismatch(self):
        clean = mock.Mock(returncode=0, stdout="")
        revision = mock.Mock(returncode=0, stdout="a" * 40 + "\n")
        with mock.patch.dict(
                runner.os.environ, {"GITHUB_SHA": "b" * 40}, clear=False), \
                mock.patch.object(
                    runner, "run", side_effect=[clean, revision]):
            with self.assertRaisesRegex(
                    runner.PocError, "does not match the checked-out revision"):
                runner.execution_identity(ROOT, ROOT / "unused.log")

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
             mock.patch.object(
                 validator.evidence_digest, "text_evidence_sha256", return_value="1" * 64
             ), \
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

    def test_openssl_resumption_requires_fresh_cache_miss(self):
        source = (ROOT / "tools/tls_provider_poc/openssl_memory_poc.c").read_text(
            encoding="utf-8")
        self.assertIn("SSL_session_reused(first.client) == 0", source)
        self.assertIn("SSL_session_reused(first.server) == 0", source)
        self.assertIn("SSL_session_reused(resumed.client) == 1", source)
        self.assertIn("SSL_session_reused(resumed.server) == 1", source)

    def test_archive_result_binds_release_tag_resolution(self):
        result = complete_result(self.spec, provider="mbedtls", status="PARTIAL")
        result["source"]["tag_resolved_commit"] = "0" * 40
        with self.assertRaisesRegex(validator.ValidationError,
                                    "release tag commit"):
            validator.validate_result(result, self.spec)

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
                    {"id": "openssl", "version": "9.9.9"}, root,
                    root / "src", root, root / "log",
                    fixtures, "linux-glibc-x86_64",
                )
                self.assertEqual("UNSUPPORTED", openssl["leak_detection"]["status"])
                self.assertIn("OpenSSL 9.9.9", openssl["leak_detection"]["reason"])
                self.assertNotIn("OpenSSL 3.6.3", openssl["leak_detection"]["reason"])
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

        result = complete_result(self.spec)
        result["operational_evidence"]["native_memory_diagnostic"].pop(
            "cleanup_cycles")
        with self.assertRaisesRegex(validator.ValidationError,
                                    "diagnostic execution cycles"):
            validator.validate_result(result, self.spec)

        result = complete_result(self.spec)
        result["operational_evidence"]["native_memory_diagnostic"].pop(
            "output_sha256")
        with self.assertRaisesRegex(validator.ValidationError,
                                    "diagnostic output digest"):
            validator.validate_result(result, self.spec)

    def test_static_archive_inventory_is_structured_and_bounded(self):
        source = RUN_MODULE.read_text(encoding="utf-8")
        self.assertGreaterEqual(
            source.count("for archive in sorted(archives, key=lambda path: path.name)"),
            2,
        )
        result = complete_result(self.spec)
        result["build"]["static_archives"] = [True]
        with self.assertRaisesRegex(validator.ValidationError,
                                    "static archive inventory entry invalid"):
            validator.validate_result(result, self.spec)

        result = complete_result(self.spec)
        result["build"]["static_archives"].append(copy.deepcopy(
            result["build"]["static_archives"][0]))
        with self.assertRaisesRegex(validator.ValidationError,
                                    "sorted and unique"):
            validator.validate_result(result, self.spec)

    def test_partial_rejects_not_run_and_requires_blocked_capability(self):
        result = complete_result(self.spec, status="PARTIAL")
        result["capabilities"]["tls12"] = "NOT_RUN"
        with self.assertRaisesRegex(validator.ValidationError,
                                    "failed or unexecuted capability"):
            validator.validate_result(result, self.spec)

        result = complete_result(self.spec, status="PARTIAL")
        result["capabilities"] = {
            name: "PASS" for name in self.spec["required_capabilities"]
        }
        with self.assertRaisesRegex(validator.ValidationError,
                                    "requires at least one blocked"):
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

    def test_windows_aws_lc_assembler_identity_is_required(self):
        result = complete_result(self.spec, platform="windows-x86_64")
        result["build"]["provenance"]["assembler"] = None
        with self.assertRaisesRegex(validator.ValidationError,
                                    "NASM assembler identity required"):
            validator.validate_result(result, self.spec)
        result = complete_result(self.spec, platform="windows-x86_64")
        result["build"]["provenance"]["assembler"]["exit_code"] = 1
        with self.assertRaisesRegex(validator.ValidationError,
                                    "NASM assembler identity command failed"):
            validator.validate_result(result, self.spec)

    def test_non_windows_build_rejects_assembler_identity(self):
        result = complete_result(self.spec)
        result["build"]["provenance"]["assembler"] = tool_identity_fixture("nasm")
        with self.assertRaisesRegex(validator.ValidationError,
                                    "unexpected provider assembler identity"):
            validator.validate_result(result, self.spec)

    def test_windows_workflow_pins_nasm_fallback(self):
        workflow = (ROOT / ".github/workflows/m0-016-windows-provider-poc.yml").read_text()
        self.assertIn("choco install nasm --version=2.16.3 --no-progress -y", workflow)

    def test_hosted_workflows_supply_read_only_tag_resolution_token(self):
        for path in (
                ".github/workflows/tls-provider-poc.yml",
                ".github/workflows/m0-016-windows-provider-poc.yml"):
            workflow = (ROOT / path).read_text()
            self.assertIn("WIRESTACK_GITHUB_TOKEN: ${{ github.token }}",
                          workflow)

    def test_musl_package_installation_has_no_tag_resolution_token(self):
        workflow = (ROOT / ".github/workflows/tls-provider-poc.yml").read_text()
        provision_start = workflow.index(
            "- name: Provision native Alpine musl userspace")
        runner_start = workflow.index(
            "- name: Build and execute in provisioned Alpine musl userspace")
        cleanup_start = workflow.index("- name: Remove Alpine musl container")
        provision = workflow[provision_start:runner_start]
        runner_step = workflow[runner_start:cleanup_start]
        self.assertIn("apk add --no-cache", provision)
        self.assertIn("git config --global --add safe.directory /work",
                      provision)
        self.assertNotIn("WIRESTACK_GITHUB_TOKEN", provision)
        self.assertIn("-e WIRESTACK_GITHUB_TOKEN", runner_step)
        self.assertIn("unset WIRESTACK_GITHUB_TOKEN", runner_step)

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
                "sha256": evidence_digest.text_evidence_sha256(license_path),
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
                "sha256": evidence_digest.text_evidence_sha256(manifest_path),
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

    def test_license_manifest_digest_is_line_ending_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "LICENSE").write_text("inside\n", encoding="utf-8")
            output = root / "output"
            info = runner.create_license_bundle(
                source, output, "aws-lc", {"content_sha256": "0" * 64})
            manifest = output / info["path"]
            manifest.write_bytes(manifest.read_bytes().replace(b"\n", b"\r\n"))
            self.assertEqual(info["sha256"], evidence_digest.text_evidence_sha256(manifest))

    def test_license_file_metadata_is_line_ending_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            observed_digests = set()
            for index, raw in enumerate(
                    (b"alpha\nbeta\n", b"alpha\r\nbeta\r\n", b"alpha\rbeta\r")):
                with self.subTest(raw=raw):
                    source = root / f"source-{index}"
                    source.mkdir()
                    (source / "LICENSE").write_bytes(raw)
                    output = root / f"output-{index}"
                    result = complete_result(self.spec)
                    info = runner.create_license_bundle(
                        source, output, "aws-lc", result["source"])
                    result["build"]["license_bundle"] = info
                    manifest = json.loads(
                        (output / "license-bundle/manifest.json").read_text())
                    observed_digests.add(manifest["files"][0]["sha256"])
                    validator.validate_license_bundle(output / "result.json", result)
            self.assertEqual(1, len(observed_digests))

    def test_license_file_invalid_utf8_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "LICENSE").write_bytes(b"valid\n\xff")
            with self.assertRaisesRegex(runner.PocError, "not valid UTF-8"):
                runner.create_license_bundle(
                    source, root, "aws-lc", {"content_sha256": "0" * 64})

            (source / "LICENSE").write_bytes(b"valid\n")
            result = complete_result(self.spec)
            info = runner.create_license_bundle(
                source, root, "aws-lc", result["source"])
            result["build"]["license_bundle"] = info
            (root / "license-bundle/files/LICENSE").write_bytes(b"valid\n\xff")
            with self.assertRaisesRegex(validator.ValidationError, "not valid UTF-8"):
                validator.validate_license_bundle(root / "result.json", result)

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
                "sha256": evidence_digest.text_evidence_sha256(license_path),
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
            manifest_digest = evidence_digest.text_evidence_sha256(manifest_path)
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
                "sha256": evidence_digest.text_evidence_sha256(result_path),
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
            self.assertIn("CAP local_close=%s", source)
            self.assertIn("METRIC local_close_operations=%d", source)
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
        openssl_local_close = openssl_source[
            openssl_source.index("static int local_close_version_case"):
            openssl_source.index("static int local_close_case")
        ]
        self.assertNotIn("SSL_shutdown(", openssl_local_close)
        self.assertIn("SSL_free(p.client)", openssl_local_close)
        self.assertIn("peer_error == SSL_ERROR_SSL", openssl_local_close)
        self.assertIn("peer_error == SSL_ERROR_SYSCALL", openssl_local_close)
        self.assertNotIn("SSL_ERROR_WANT_READ", openssl_local_close)
        self.assertNotIn("SSL_ERROR_WANT_WRITE", openssl_local_close)
        self.assertIn("BIO_shutdown_wr(SSL_get_wbio(p.client))", openssl_source)
        openssl_truncation = openssl_source[
            openssl_source.index("static int truncation_case"):
            openssl_source.index("static int local_close_version_case")
        ]
        self.assertIn("e == SSL_ERROR_SSL", openssl_truncation)
        self.assertIn("e == SSL_ERROR_SYSCALL", openssl_truncation)
        self.assertNotIn("SSL_ERROR_WANT_READ", openssl_truncation)
        self.assertNotIn("SSL_ERROR_WANT_WRITE", openssl_truncation)
        mbedtls_local_close = mbedtls_source[
            mbedtls_source.index("static int local_close_version_case"):
            mbedtls_source.index("static int local_close_case")
        ]
        self.assertNotIn("mbedtls_ssl_close_notify", mbedtls_local_close)
        self.assertIn("mbedtls_ssl_free(&p.client)", mbedtls_local_close)
        self.assertIn("peer_result == 0", mbedtls_local_close)
        self.assertNotIn("MBEDTLS_ERR_SSL_WANT_READ", mbedtls_local_close)
        self.assertNotIn("MBEDTLS_ERR_SSL_WANT_WRITE", mbedtls_local_close)
        mbedtls_truncation = mbedtls_source[
            mbedtls_source.index("static int truncation_case"):
            mbedtls_source.index("static int local_close_version_case")
        ]
        self.assertIn("ok = ret == 0", mbedtls_truncation)
        self.assertNotIn("MBEDTLS_ERR_SSL_WANT_READ", mbedtls_truncation)
        self.assertNotIn("MBEDTLS_ERR_SSL_WANT_WRITE", mbedtls_truncation)

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

    def test_linux_and_macos_results_require_native_runner_identity(self):
        linux = complete_result(self.spec, platform="linux-glibc-x86_64")
        linux["execution"]["runner_arch"] = "ARM64"
        with self.assertRaisesRegex(validator.ValidationError,
                                    "native x86_64 runner"):
            validator.validate_result(linux, self.spec)

        macos = complete_result(self.spec, platform="macos-arm64")
        macos["execution"]["runner_os"] = "Linux"
        with self.assertRaisesRegex(validator.ValidationError,
                                    "native macOS runner"):
            validator.validate_result(macos, self.spec)

    def test_successful_result_requires_zero_poc_exit_code(self):
        result = complete_result(self.spec)
        result["poc_exit_code"] = 1
        with self.assertRaisesRegex(validator.ValidationError,
                                    "zero PoC exit code"):
            validator.validate_result(result, self.spec)
        result.pop("poc_exit_code")
        with self.assertRaisesRegex(validator.ValidationError,
                                    "zero PoC exit code"):
            validator.validate_result(result, self.spec)

    def test_successful_result_requires_final_binary_identity(self):
        result = complete_result(self.spec)
        result["build"].pop("binary_bytes")
        with self.assertRaisesRegex(validator.ValidationError,
                                    "bounded final binary size"):
            validator.validate_result(result, self.spec)

        result = complete_result(self.spec)
        result["build"].pop("binary_sha256")
        with self.assertRaisesRegex(validator.ValidationError,
                                    "final binary digest"):
            validator.validate_result(result, self.spec)

    def test_expected_revision_mismatch_fails(self):
        result = complete_result(self.spec, platform="windows-x86_64")
        with self.assertRaisesRegex(validator.ValidationError, "revision mismatch"):
            validator.validate_result(result, self.spec, "3" * 40)


if __name__ == "__main__":
    unittest.main()

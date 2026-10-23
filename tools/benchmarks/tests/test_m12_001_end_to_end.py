"""Performance decisions must preserve outcome accounting and equivalent work."""
import copy
import unittest
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

from tools.benchmarks import m12_001_end_to_end as bench


def row(duration=1_000_000, tail=10_000, reads=2048, operations=100):
    return {"scenario": "h1_bulk_4096", "regime": "normal", "duration_ns": duration,
            "operations": operations, "successes": operations, "failures": 0, "expected_rejections": 0,
            "bytes": 8 * 1024 * 1024, "checksum": 123456,
            "latencies_ns": [tail] * operations, "metrics": {"cleanup_owners": 0, "body_read_calls": reads}}


class NativeSampleValidation(unittest.TestCase):
    def test_failed_requests_are_not_hidden_by_successful_bytes(self):
        sample = row()
        sample.update(successes=99, failures=1)
        with self.assertRaisesRegex(ValueError, "unexpected failures"):
            bench.validate_sample(sample, sample["scenario"])

    def test_missing_latencies_include_rejected_operations(self):
        sample = row()
        sample.update(regime="overload", successes=90, expected_rejections=10)
        sample["latencies_ns"] = sample["latencies_ns"][:90]
        with self.assertRaisesRegex(ValueError, "latency samples"):
            bench.validate_sample(sample, sample["scenario"])

    def test_resources_must_be_reclaimed(self):
        sample = row()
        sample["metrics"]["cleanup_owners"] = 1
        with self.assertRaisesRegex(ValueError, "reclaimed"):
            bench.validate_sample(sample, sample["scenario"])

    def test_overload_without_actual_rejection_is_invalid(self):
        sample = row()
        sample["regime"] = "overload"
        with self.assertRaisesRegex(ValueError, "exercise rejection"):
            bench.validate_sample(sample, sample["scenario"])

    def test_checksum_drift_prevents_averaging_different_work(self):
        samples = [row(), row()]
        samples[1]["checksum"] += 1
        with self.assertRaisesRegex(ValueError, "changed between rounds"):
            bench.summarize(samples)

    def test_nearest_rank_tail_does_not_interpolate_away_outlier(self):
        self.assertEqual(bench.percentile([1] * 99 + [1_000_000], 99), 1)
        self.assertEqual(bench.percentile([1] * 98 + [1_000_000] * 2, 99), 1_000_000)


class RegressionClassification(unittest.TestCase):
    def setUp(self):
        self.baseline = bench.summarize([row()] * 12)
        self.reference = bench.freeze_reference(self.baseline)

    def test_throughput_gain_cannot_hide_tail_regression(self):
        candidate = bench.summarize([row(500_000, tail=20_000)] * 12)
        self.assertEqual(bench.classify(self.reference, candidate)["status"], "FAIL")

    def test_environment_change_cannot_pass(self):
        self.assertEqual(bench.classify(self.reference, self.baseline, False)["status"], "INCONCLUSIVE")

    def test_insufficient_rounds_cannot_pass(self):
        candidate = bench.summarize([row()] * 3)
        self.assertEqual(bench.classify(self.reference, candidate)["status"], "INCONCLUSIVE")

    def test_noisy_candidate_is_not_a_pass(self):
        candidate = bench.summarize([row(500_000)] * 6 + [row(2_000_000)] * 6)
        self.assertEqual(bench.classify(self.reference, candidate)["status"], "NOISY")

    def test_failed_correctness_wins_over_environment_mismatch(self):
        candidate = copy.deepcopy(self.baseline)
        candidate["unexpected_failures"] = 1
        self.assertEqual(bench.classify(self.reference, candidate, False)["status"], "FAIL")

    def test_outcome_contract_mismatch_is_inconclusive(self):
        candidate = copy.deepcopy(self.baseline)
        candidate["contract"]["bytes"] *= 2
        self.assertEqual(bench.classify(self.reference, candidate)["status"], "INCONCLUSIVE")


class ReadBufferCandidate(unittest.TestCase):
    def test_repeatable_equivalent_work_gain_requires_fewer_measured_reads(self):
        before = [row()] * 12
        after = [row(700_000, reads=256)] * 12
        outcome = bench.evaluate_read_buffer(before, after)
        self.assertEqual(outcome["decision"], "SUPPORTED_CALLER_CONFIGURATION")
        self.assertIsNone(outcome["allocations_reduced"])
        self.assertIsNone(outcome["copied_bytes_reduced"])

    def test_more_throughput_with_worse_tail_is_rejected(self):
        outcome = bench.evaluate_read_buffer([row()] * 12, [row(700_000, tail=20_000, reads=256)] * 12)
        self.assertEqual(outcome["decision"], "REJECTED")

    def test_small_sample_cannot_support_optimization(self):
        outcome = bench.evaluate_read_buffer([row()] * 3, [row(700_000, reads=256)] * 3)
        self.assertEqual(outcome["decision"], "REJECTED")

    def test_faster_but_different_byte_count_is_rejected(self):
        after = [row(500_000, reads=256) for _ in range(12)]
        for sample in after:
            sample["bytes"] //= 2
        self.assertEqual(bench.evaluate_read_buffer([row()] * 12, after)["decision"], "REJECTED")

    def test_scheduler_noise_does_not_authorize_optimization(self):
        after = [row(500_000, reads=256)] * 6 + [row(2_000_000, reads=256)] * 6
        self.assertEqual(bench.evaluate_read_buffer([row()] * 12, after)["decision"], "REJECTED")

class ReportFixture:
    """Builds a fully bound retained report plus its raw logs in a temporary directory."""

    LAYER_BINARY = "<scratch>/http/target/release/bin/main"
    TLS_IDENTITY = {"provider": "aws-lc", "version": "5.5.0", "build_fingerprint": "fingerprint-1",
                    "target_triple": "x86_64-unknown-linux-gnu", "external_openssl": False,
                    "trust_backend": "custom-roots-only"}

    salt = 0

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.initialize(Path(self.directory.name))

    def initialize(self, directory):
        ReportFixture.salt += 1
        self.salt = ReportFixture.salt
        self.path = Path(directory) / "report.json"
        self.commands = []
        self.witness = {"platform": {"os": "linux", "architecture": "x86_64", "libc": "glibc", "libc_version": "2.44"},
                        "compiler_digest": {"domain": "artifact-bytes-v1", "sha256": "a" * 64},
                        "runtime_binaries": {"libcangjie-runtime.so": {"domain": "artifact-bytes-v1", "sha256": "b" * 64}},
                        "runtime_environment": {"CJ_SDK_LIBPATH": "<sdk>/runtime"}}
        self.cpu = {"lscpu": [{"field": "Architecture:", "data": "x86_64"},
                              {"field": "Model name:", "data": "Example CPU"},
                              {"field": "CPU(s):", "data": "12"}]}
        self.metadata = {"cjc": "Cangjie Compiler: 1.1.3 (cjnative)\nTarget: x86_64-unknown-linux-gnu",
                         "cjpm": "Cangjie Project Manager: 1.1.3",
                         "cpu": json.dumps(self.cpu),
                         "uname": "Linux 6.8.0-arch1 x86_64",
                         "environment": json.dumps(self.witness, sort_keys=True)}
        self.report = {"schema_version": bench.SCHEMA_VERSION, "status": "PASS",
                       "workload_counts": dict(bench.WORKLOAD_COUNTS),
                       "scenario_contracts": bench.scenario_contracts(),
                       "samples": [], "commands": self.commands, "summary": {}, "reference": {},
                       "read_buffer_candidate": {}, "measured_process_rounds": 7, "warmup_process_rounds": 1,
                       "tls_provider": self.TLS_IDENTITY,
                       "environment": {**bench.ENVIRONMENT_DECLARATIONS, **self.witness,
                                       "kernel": "6.8.0-arch1", "cjc": self.metadata["cjc"],
                                       "cjpm": self.metadata["cjpm"], "cpu": self.cpu,
                                       "tls_provider": self.TLS_IDENTITY},
                       "artifact": {"probe_sources": {}, "task_source_digests": {},
                                    "archive_digest": {}, "payload_sha256": "a" * 64}}
        for name, argv in bench.ENVIRONMENT_COMMANDS:
            self.add_command(f"metadata-{name}", list(argv), self.metadata[name])
        for layer in bench.CASES:
            binary_digest = {"domain": "artifact-bytes-v1", "sha256": "c" * 64}
            self.report["artifact"][layer] = {"binary_digest": binary_digest,
                                              "command_path": self.LAYER_BINARY, "tls_provider": self.TLS_IDENTITY}
            self.add_command(f"{layer}-tls-identity", [self.LAYER_BINARY, "tls-identity"],
                             bench.TLS_IDENTITY_PREFIX + json.dumps(self.TLS_IDENTITY))
        for layer, cases in bench.CASES.items():
            for scenario in cases:
                rows = []
                for round_number in range(7):
                    sample, argv, native = self.sample(layer, scenario, round_number, warmup=False)
                    rows.append(sample)
                    self.report["samples"].append(sample)
                    identity = f"{scenario}-round-{round_number}"
                    self.add_command(identity, argv, json.dumps(native), samples=self.process_samples(), key=identity)
                    sample["command_id"] = identity
                summary = bench.summarize(rows)
                self.report["summary"][scenario] = summary
                self.report["reference"][scenario] = bench.freeze_reference(summary)
                warmup, argv, native = self.sample(layer, scenario, 0, warmup=True)
                identity = f"{scenario}-warmup-0"
                self.add_command(identity, argv, json.dumps(native), samples=self.process_samples(), key=identity)
                warmup["command_id"] = identity
                self.report["samples"].append(warmup)
        measured = {}
        for sample in self.report["samples"]:
            if not sample["warmup"]:
                measured.setdefault(sample["scenario"], []).append(sample)
        self.report["read_buffer_candidate"] = bench.recomputed_read_buffer_candidate(measured)

    def process_samples(self):
        return [{"elapsed_ns": 1, "rss_kib": 720, "threads": 1, "fds": 4},
                {"elapsed_ns": 2, "rss_kib": 112_784, "threads": 5, "fds": 9}]

    def add_command(self, name, argv, text, samples=None, key=""):
        relative = f"{name}.log"
        log = self.path.parent / relative
        log.write_text(text + "\n")
        self.commands.append({"id": key or name, "argv": argv, "exit_code": 0, "timed_out": False,
                              "process_samples": samples or [],
                              "stdout": {"path": relative, "digest": bench.text_evidence_digest(log).to_json()},
                              "stderr": {"path": relative, "digest": bench.text_evidence_digest(log).to_json()}})

    def sample(self, layer, scenario, round_number, warmup):
        native_case = bench.NATIVE_SCENARIOS.get(scenario, scenario)
        operations, rejections, regime = bench.SCENARIO_CONTRACTS[scenario]
        successful = operations - rejections
        native = {"scenario": native_case, "regime": regime,
                  "duration_ns": 1_000_000 + self.salt * 100_000 + round_number + (1000 if warmup else 0),
                  "operations": operations, "successes": successful, "failures": 0,
                  "expected_rejections": rejections, "bytes": 8 * 1024 * 1024 if successful else 0,
                  "checksum": 123456 if successful else 0,
                  "runtime_heap_after_bytes": 0, "gc_count_after": 0,
                  "latencies_ns": [10_000] * operations,
                  "metrics": {"cleanup_owners": 0, "body_read_calls": 2,
                              "observation_enabled": bench.OBSERVATION_MODES.get(scenario) == "enabled"}}
        sample = {**native, "scenario": scenario, "native_scenario": native_case, "layer": layer,
                  "round": round_number, "warmup": warmup, "command_id": "",
                  "binary_digest": self.report["artifact"][layer]["binary_digest"],
                  "process_peak_rss_kib": max(s["rss_kib"] for s in self.process_samples()),
                  "process_peak_fds": max(s["fds"] for s in self.process_samples()),
                  "process_peak_threads": max(s["threads"] for s in self.process_samples())}
        binary = self.report["artifact"][layer]["command_path"]
        return sample, bench.workload_arguments(Path(binary), scenario, Path("<scratch>")), native

    def write(self):
        self.path.write_text(json.dumps(self.report))
        return self.path

    def load(self):
        return bench.load_verified_report(self.write())

    def command(self, name):
        return next(item for item in self.commands if item["id"] == name)

    def log(self, name):
        return self.path.parent / f"{name}.log"

    def recompute(self, scenario):
        rows = sorted((r for r in self.report["samples"] if r["scenario"] == scenario and not r["warmup"]),
                      key=lambda r: r["round"])
        summary = bench.summarize(rows)
        self.report["summary"][scenario] = summary
        self.report["reference"][scenario] = bench.freeze_reference(summary)
        measured = {}
        for row in self.report["samples"]:
            if not row["warmup"]:
                measured.setdefault(row["scenario"], []).append(row)
        self.report["read_buffer_candidate"] = bench.recomputed_read_buffer_candidate(measured)


class RawEvidenceBinding(ReportFixture, unittest.TestCase):
    def test_bound_fixture_is_accepted(self):
        self.assertEqual(self.load()["status"], "PASS")

    def test_edited_read_buffer_decision_cannot_pass(self):
        self.report["read_buffer_candidate"]["decision"] = "SUPPORTED_CALLER_CONFIGURATION"
        with self.assertRaisesRegex(ValueError, "read-buffer candidate decision"):
            self.load()

    def test_declared_workload_mapping_must_match_configured_workload(self):
        self.report["workload_counts"]["tcp_bulk"] = 1
        with self.assertRaisesRegex(ValueError, "declared workload counts"):
            self.load()

    def test_declared_scenario_contract_must_match_configured_workload(self):
        self.report["scenario_contracts"]["h1_short_reuse"]["operations"] = 20
        with self.assertRaisesRegex(ValueError, "declared scenario work contracts"):
            self.load()

    def test_cached_summary_cannot_invent_more_throughput(self):
        self.report["summary"]["tcp_bulk"]["successful_operations_per_second"] *= 2
        with self.assertRaisesRegex(ValueError, "differs from raw"):
            self.load()

    def test_changed_native_output_cannot_keep_old_digest(self):
        log = self.log("tcp_bulk-round-0")
        log.write_text(log.read_text().replace('"checksum": 123456', '"checksum": 9'))
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.load()

    def test_omitted_feature_cannot_pass_full_layer_gate(self):
        self.report["samples"] = [r for r in self.report["samples"] if r["scenario"] != "websocket_h2"]
        with self.assertRaisesRegex(ValueError, "coverage"):
            self.load()

    def test_one_native_execution_cannot_be_seven_rounds(self):
        self.report["samples"][1]["command_id"] = self.report["samples"][0]["command_id"]
        with self.assertRaisesRegex(ValueError, "reused a native command"):
            self.load()

    def test_removed_warmup_samples_cannot_keep_the_claim(self):
        self.report["samples"] = [r for r in self.report["samples"] if not r["warmup"]]
        with self.assertRaisesRegex(ValueError, "warmup rounds are incomplete"):
            self.load()

    def test_partial_warmup_coverage_is_rejected(self):
        self.report["samples"] = [r for r in self.report["samples"]
                                  if r["scenario"] != "h2_streams_100" or not r["warmup"]]
        with self.assertRaisesRegex(ValueError, "warmup rounds are incomplete"):
            self.load()

    def test_cloned_execution_with_new_command_identity_is_rejected(self):
        source = self.report["samples"][0]
        clone = copy.deepcopy(source)
        clone.update(round=1, command_id="tcp_bulk-round-1-clone")
        self.commands.append({**copy.deepcopy(self.command("tcp_bulk-round-0")), "id": "tcp_bulk-round-1-clone"})
        existing = next(row for row in self.report["samples"] if row["scenario"] == source["scenario"]
                        and row["round"] == 1 and not row["warmup"])
        self.report["samples"][self.report["samples"].index(existing)] = clone
        self.recompute(source["scenario"])
        with self.assertRaisesRegex(ValueError, "one raw execution was reported as independent rounds"):
            self.load()

    def test_log_padding_cannot_create_an_independent_execution(self):
        log = self.log("tcp_bulk-round-0")
        log.write_text(log.read_text() + "diagnostic line\n")
        self.command("tcp_bulk-round-0")["stdout"]["digest"] = bench.text_evidence_digest(log).to_json()
        with self.assertRaisesRegex(ValueError, "output beyond its single sample record"):
            self.load()

    def test_forged_environment_block_is_rejected(self):
        self.report["environment"]["cjc"] = "Cangjie Compiler: 9.9.9 (cjnative)"
        with self.assertRaisesRegex(ValueError, "environment cjc is not backed"):
            self.load()

    def test_environment_block_without_metadata_commands_is_rejected(self):
        self.commands[:] = [c for c in self.commands if not c["id"].startswith("metadata-")]
        with self.assertRaisesRegex(ValueError, "metadata command"):
            self.load()

    def test_edited_cpu_metadata_is_rejected(self):
        self.report["environment"]["cpu"]["lscpu"][1]["data"] = "Different CPU"
        with self.assertRaisesRegex(ValueError, "environment cpu is not backed"):
            self.load()

    def test_tls_identity_must_be_the_measured_binary_record(self):
        self.report["tls_provider"]["build_fingerprint"] = "forged-build"
        self.report["environment"]["tls_provider"] = self.report["tls_provider"]
        with self.assertRaisesRegex(ValueError, "provider identity"):
            self.load()

    def test_provider_change_makes_reports_non_comparable(self):
        self.report["tls_provider"]["version"] = "5.11.0"
        with self.assertRaisesRegex(ValueError, "provider identity"):
            self.load()

    def test_substituted_executable_cannot_be_attributed_to_the_recorded_layer(self):
        self.command("tcp_bulk-round-0")["argv"][0] = "<scratch>/unrecorded/target/release/bin/main"
        with self.assertRaisesRegex(ValueError, "recorded layer binary"):
            self.load()

    def test_sample_binary_digest_must_match_the_recorded_layer(self):
        next(row for row in self.report["samples"] if row["scenario"] == "tcp_bulk")["binary_digest"] = {
            "domain": "artifact-bytes-v1", "sha256": "d" * 64}
        with self.assertRaisesRegex(ValueError, "binary digest"):
            self.load()

    def test_edited_process_peak_cannot_understate_resources(self):
        next(row for row in self.report["samples"] if row["scenario"] == "tcp_bulk")["process_peak_rss_kib"] = 1
        with self.assertRaisesRegex(ValueError, "derived process peaks"):
            self.load()

    def test_required_warmup_round_count_must_be_declared(self):
        self.report["warmup_process_rounds"] = 0
        with self.assertRaisesRegex(ValueError, "warmup rounds are outside the supported range"):
            self.load()

    def test_observation_mode_must_match_the_native_metric(self):
        sample = next(r for r in self.report["samples"] if r["scenario"] == "http_unobserved")
        sample["metrics"]["observation_enabled"] = True
        log = self.log(sample["command_id"])
        native = json.loads(log.read_text())
        native["metrics"]["observation_enabled"] = True
        log.write_text(json.dumps(native) + "\n")
        self.command(sample["command_id"])["stdout"]["digest"] = bench.text_evidence_digest(log).to_json()
        with self.assertRaisesRegex(ValueError, "declared observation mode"):
            self.load()


class BaselineArchiveVerification(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def report(self, archive_digest, payload_sha256='a' * 64):
        return {'artifact': {'archive_digest': archive_digest, 'payload_sha256': payload_sha256}}

    def test_missing_archive_is_reconstructed_and_checked_against_payload_and_bytes(self):
        expected_bytes = b'reproducible baseline archive bytes'
        expected = self.root / 'expected.tar.gz'
        expected.write_bytes(expected_bytes)
        archive = self.root / 'missing.tar.gz'
        report = self.report(bench.artifact_byte_digest(expected).to_json())

        def write_archive(path, payload):
            Path(path).write_bytes(expected_bytes)

        with patch.object(bench.release, 'collect_payload', return_value=([], {'payload_sha256': 'a' * 64})) as collect, \
             patch.object(bench.release, 'write_reproducible_archive', side_effect=write_archive):
            bench.verify_baseline_archive(report, archive)
        collect.assert_called_once_with(bench.ROOT)

    def test_wrong_reconstructed_payload_or_archive_cannot_pass(self):
        archive = self.root / 'missing.tar.gz'
        expected = self.root / 'expected.tar.gz'
        expected.write_bytes(b'expected archive')
        report = self.report(bench.artifact_byte_digest(expected).to_json())
        with patch.object(bench.release, 'collect_payload', return_value=([], {'payload_sha256': 'b' * 64})):
            with self.assertRaisesRegex(ValueError, 'payload differs'):
                bench.verify_baseline_archive(report, archive)
        with patch.object(bench.release, 'collect_payload', return_value=([], {'payload_sha256': 'a' * 64})), \
             patch.object(bench.release, 'write_reproducible_archive', side_effect=lambda path, payload: Path(path).write_bytes(b'wrong archive')):
            with self.assertRaisesRegex(ValueError, 'artifact differs'):
                bench.verify_baseline_archive(report, archive)

    def test_missing_reconstruction_inputs_are_explicitly_unavailable(self):
        with patch.object(bench.release, 'collect_payload', side_effect=FileNotFoundError('native archive input missing')):
            with self.assertRaisesRegex(ValueError, 'exact baseline payload reconstruction is unavailable'):
                bench.verify_baseline_archive(self.report({}), self.root / 'missing.tar.gz')

    def test_existing_wrong_archive_fails_without_reconstruction(self):
        archive = self.root / 'baseline.tar.gz'
        archive.write_bytes(b'wrong')
        with patch.object(bench.release, 'collect_payload') as collect:
            with self.assertRaisesRegex(ValueError, 'retained development baseline artifact differs'):
                bench.verify_baseline_archive(self.report({}), archive)
        collect.assert_not_called()

    def test_missing_profiler_returns_optional_unavailable_record(self):
        campaign = object.__new__(bench.Campaign)
        campaign.work = self.root
        with patch.object(bench.shutil, 'which', return_value=None):
            result = campaign.profile(self.root / 'unused-binary')
        self.assertEqual(result['status'], 'UNAVAILABLE')
        self.assertIn('cjprof', result['reason'])

class TaskSourceInventory(unittest.TestCase):
    def test_declared_inventory_covers_runner_tests_contract_and_documentation(self):
        task = json.loads((bench.ROOT / "tools/tasks/M12-001.json").read_text())
        inventory = bench.task_source_digests()
        self.assertEqual(set(inventory), set(task["source_paths"]))
        for relative in ("tools/benchmarks/m12_001_end_to_end.py",
                         "tools/benchmarks/tests/test_m12_001_end_to_end.py",
                         "tools/tasks/M12-001.json",
                         "docs/performance/end-to-end-baselines.md",
                         "docs/performance/http1-benchmark.md",
                         "docs/performance/http2-benchmark.md"):
            self.assertIn(relative, inventory)

    def test_capture_that_omits_or_changes_task_sources_cannot_verify(self):
        inventory = bench.task_source_digests()
        with self.assertRaisesRegex(ValueError, "complete benchmark task source inventory"):
            bench.verify_task_sources({"artifact": {}})
        incomplete = dict(inventory)
        incomplete.pop("tools/benchmarks/tests/test_m12_001_end_to_end.py")
        with self.assertRaisesRegex(ValueError, "complete benchmark task source inventory"):
            bench.verify_task_sources({"artifact": {"task_source_digests": incomplete}})

    def test_changed_runner_or_documentation_is_rejected(self):
        inventory = bench.task_source_digests()
        changed = dict(inventory)
        changed["docs/performance/end-to-end-baselines.md"] = {"domain": "text-utf8-lf-v1", "sha256": "0" * 64}
        with patch.object(bench, "task_source_digests", return_value=inventory):
            bench.verify_task_sources({"artifact": {"task_source_digests": inventory}})
            with self.assertRaisesRegex(ValueError, "runner, tests, task contract or documentation"):
                bench.verify_task_sources({"artifact": {"task_source_digests": changed}})


class ConfiguredWorkload(unittest.TestCase):
    def sample_and_command(self, scenario="tcp_bulk"):
        operations, rejections, regime = bench.SCENARIO_CONTRACTS[scenario]
        sample = row(operations=operations)
        sample.update(scenario=scenario, native_scenario=scenario, successes=operations - rejections,
                      expected_rejections=rejections, regime=regime)
        sample["metrics"]["observation_enabled"] = bench.OBSERVATION_MODES.get(scenario) == "enabled"
        return sample, {"argv": bench.workload_arguments(Path("<scratch>/http/main"), scenario, Path("<scratch>"))}

    def test_configured_command_and_sample_workload_is_accepted(self):
        for scenario in bench.CASES["transport_tls"] + bench.CASES["http"] + bench.CASES["streams"]:
            sample, command = self.sample_and_command(scenario)
            with self.subTest(scenario=scenario):
                bench.validate_workload_sample(sample, command)

    def test_undersized_or_missing_command_count_is_rejected(self):
        for mutate in (lambda c: c["argv"].__setitem__(4, "1"), lambda c: c["argv"].pop(4),
                       lambda c: c["argv"].__setitem__(4, "8.5")):
            sample, command = self.sample_and_command()
            mutate(command)
            with self.subTest(argv=command["argv"]), self.assertRaisesRegex(ValueError, "configured workload count"):
                bench.validate_workload_sample(sample, command)

    def test_undersized_sample_operation_count_is_rejected(self):
        for operations in (1, bench.WORKLOAD_COUNTS["tcp_bulk"] + 1):
            sample, command = self.sample_and_command()
            sample["operations"] = operations
            with self.subTest(operations=operations), self.assertRaisesRegex(ValueError, "configured workload count"):
                bench.validate_workload_sample(sample, command)

    def test_feature_scenarios_are_bound_to_their_declared_work(self):
        # h1_bulk_4096 performs exactly one 8 MiB exchange; 20 requests is a different measurement.
        sample, command = self.sample_and_command("h1_bulk_4096")
        self.assertEqual(sample["operations"], 1)
        sample["operations"] = 20
        with self.assertRaisesRegex(ValueError, "configured workload count"):
            bench.validate_workload_sample(sample, command)

    def test_feature_scenario_with_unexpected_argument_is_rejected(self):
        sample, command = self.sample_and_command("websocket_h2")
        command["argv"].append("256")
        with self.assertRaisesRegex(ValueError, "configured workload count"):
            bench.validate_workload_sample(sample, command)

    def test_scenario_without_declared_contract_cannot_be_bound(self):
        sample, command = self.sample_and_command()
        sample["scenario"] = "unlisted_scenario"
        with self.assertRaisesRegex(ValueError, "no declared workload contract"):
            bench.validate_workload_sample(sample, command)

    def test_observed_and_unobserved_modes_require_their_own_argument_and_metric(self):
        for scenario, mode, enabled in (("http_observed", "enabled", True), ("http_unobserved", "disabled", False)):
            sample, command = self.sample_and_command(scenario)
            sample["metrics"]["observation_enabled"] = enabled
            with self.subTest(scenario=scenario):
                self.assertEqual(command["argv"][4], mode)
                bench.validate_workload_sample(sample, command)
            sample["metrics"]["observation_enabled"] = not enabled
            with self.subTest(scenario=scenario, forged=True), \
                    self.assertRaisesRegex(ValueError, "declared observation mode"):
                bench.validate_workload_sample(sample, command)
            sample["metrics"]["observation_enabled"] = enabled
            swapped = {**command, "argv": command["argv"][:4] + ["enabled" if mode == "disabled" else "disabled"]}
            with self.subTest(scenario=scenario, swapped=True), \
                    self.assertRaisesRegex(ValueError, "configured workload count"):
                bench.validate_workload_sample(sample, swapped)

    def test_regime_is_part_of_the_declared_contract(self):
        sample, command = self.sample_and_command("h2_slow_consumer")
        sample["regime"] = "normal"
        with self.assertRaisesRegex(ValueError, "declared workload"):
            bench.validate_workload_sample(sample, command)


class EnvironmentMatching(unittest.TestCase):
    def environment(self, **overrides):
        value = {"platform": {"os": "linux", "architecture": "x86_64"}, "kernel": "6.8.0",
                 "cjc": "Cangjie 1.1.3", "cjpm": "Cangjie Project Manager: 1.1.3",
                 "compiler_digest": {"domain": "artifact-bytes-v1", "sha256": "a" * 64},
                 "runtime_binaries": {"libcangjie-runtime.so": {"sha256": "b" * 64}},
                 "optimization": "-O2 -g", "network": "loopback",
                 "runtime_environment": {"CJ_HEAP_SIZE": "1GB"},
                 "tls_provider": {"provider": "aws-lc", "version": "5.5.0"},
                 "cpu": {"lscpu": [{"field": "Architecture:", "data": "x86_64"},
                                   {"field": "Model name:", "data": "Example CPU"}]}}
        value.update(overrides)
        return value

    def test_identical_environment_is_matched(self):
        self.assertTrue(bench.environment_equal(self.environment(), self.environment()))

    def test_different_tls_identity_cannot_match(self):
        self.assertFalse(bench.environment_equal(
            self.environment(), self.environment(tls_provider={"provider": "aws-lc", "version": "5.11.0"})))

    def test_package_manager_change_cannot_match(self):
        self.assertFalse(bench.environment_equal(
            self.environment(), self.environment(cjpm="Cangjie Project Manager: 1.1.4")))

    def test_other_identity_drift_cannot_match(self):
        other = self.environment(compiler_digest={"domain": "artifact-bytes-v1", "sha256": "c" * 64})
        self.assertFalse(bench.environment_equal(self.environment(), other))

    def test_malformed_cpu_metadata_is_an_invalid_environment(self):
        for cpu in ({}, {"lscpu": None}, {"lscpu": ["Architecture:"]}):
            with self.subTest(cpu=cpu), self.assertRaises((ValueError, TypeError, AttributeError)):
                bench.environment_equal(self.environment(cpu=cpu), self.environment())


class ComparisonExecutionIdentity(unittest.TestCase):
    def report(self, executions):
        samples = [{"round": index, "warmup": False, "execution_identity": value}
                   for index, value in enumerate(executions)]
        return {"samples": samples}

    def identities(self, report, rounds):
        return bench.selected_execution_digests(report, rounds)

    def test_reserialized_copy_of_one_report_overlaps(self):
        baseline = self.report(["a" * 64, "b" * 64, "c" * 64, "d" * 64])
        candidate = json.loads(json.dumps(baseline))
        self.assertTrue(self.identities(baseline, [0, 1, 2, 3]) & self.identities(candidate, [0, 1, 2, 3]))

    def test_disjoint_cohorts_of_one_report_do_not_overlap(self):
        report = self.report(["a" * 64, "b" * 64, "c" * 64, "d" * 64])
        self.assertFalse(self.identities(report, [0, 1]) & self.identities(report, [2, 3]))

    def test_independent_executions_do_not_overlap(self):
        baseline = self.report(["a" * 64, "b" * 64])
        candidate = self.report(["c" * 64, "d" * 64])
        self.assertFalse(self.identities(baseline, [0, 1]) & self.identities(candidate, [0, 1]))

    def test_warmup_executions_do_not_count_as_measured_overlap(self):
        report = self.report(["a" * 64])
        report["samples"].append({"round": 0, "warmup": True, "execution_identity": "z" * 64})
        self.assertEqual(self.identities(report, [0]), {"a" * 64})

    def test_unverified_report_cannot_supply_an_execution_identity(self):
        report = {"samples": [{"round": 0, "warmup": False}]}
        with self.assertRaisesRegex(ValueError, "verified report"):
            self.identities(report, [0])

    def test_log_padding_does_not_change_native_execution_identity(self):
        native = {"scenario": "tcp_bulk", "operations": 8, "checksum": 7}
        padded = dict(native)
        self.assertEqual(bench.canonical_execution_identity(native),
                         bench.canonical_execution_identity(padded))
        self.assertNotEqual(bench.canonical_execution_identity(native),
                            bench.canonical_execution_identity({**native, "checksum": 8}))


class ReadBufferPairing(unittest.TestCase):
    def cohort(self, durations, reads=2048):
        return [{**row(duration, reads=reads), "round": index} for index, duration in enumerate(durations)]

    def test_reordered_identical_cohorts_keep_the_decision(self):
        before = self.cohort([1_000_000] * 8)
        after = self.cohort([500_000] * 8, reads=256)
        baseline = bench.evaluate_read_buffer(before, after)
        shuffled = list(reversed(after))
        self.assertEqual(bench.evaluate_read_buffer(before, shuffled), baseline)
        self.assertEqual(baseline["decision"], "SUPPORTED_CALLER_CONFIGURATION")

    def test_reordering_cannot_flip_a_rejected_candidate(self):
        before = self.cohort([1_000_000] * 8)
        after = self.cohort([500_000] * 4 + [2_000_000] * 4, reads=256)
        rejected = bench.evaluate_read_buffer(before, after)
        self.assertEqual(rejected["decision"], "REJECTED")
        self.assertEqual(bench.evaluate_read_buffer(before, list(reversed(after))), rejected)

    def test_unpaired_rounds_cannot_be_evaluated(self):
        before = self.cohort([1_000_000] * 8)
        after = self.cohort([500_000] * 8, reads=256)
        for index, item in enumerate(after):
            item["round"] = index + 100
        self.assertEqual(bench.evaluate_read_buffer(before, after)["decision"], "REJECTED")


class ComparisonCommand(ReportFixture, unittest.TestCase):
    """Malformed or non-comparable input must still produce the documented decision file."""

    def compare(self, baseline, candidate):
        output = self.path.parent / "decision.json"
        argv = ["compare", "--baseline", str(baseline), "--candidate", str(candidate),
                "--output", str(output)]
        with patch.object(bench.sys, "argv", ["m12_001_end_to_end.py", *argv]):
            code = bench.main()
        return code, json.loads(output.read_text()) if output.is_file() else None

    def independent(self):
        """A second capture whose executions are disjoint from the first."""
        other = Path(self.directory.name) / "candidate"
        other.mkdir()
        fixture = ReportFixture()
        fixture.initialize(other)
        self.addCleanup(lambda: None)
        return fixture

    def test_identical_report_reuse_is_inconclusive(self):
        path = self.write()
        code, decision = self.compare(path, path)
        self.assertEqual((code, decision["status"]), (3, "INCONCLUSIVE"))
        self.assertIn("overlapping executions", decision["reason"])

    def test_truncated_argv_is_inconclusive_not_a_traceback(self):
        baseline = self.write()
        candidate = self.independent()
        candidate.command("tcp_bulk-round-0")["argv"] = []
        code, decision = self.compare(baseline, candidate.write())
        self.assertEqual((code, decision["status"]), (3, "INCONCLUSIVE"))
        self.assertIn("recorded layer binary", decision["reason"])

    def test_truncated_argv_that_keeps_its_binary_is_inconclusive(self):
        baseline = self.write()
        candidate = self.independent()
        candidate.command("tcp_bulk-round-0")["argv"] = [candidate.LAYER_BINARY]
        code, decision = self.compare(baseline, candidate.write())
        self.assertEqual((code, decision["status"]), (3, "INCONCLUSIVE"))
        self.assertIn("native command does not match the scenario", decision["reason"])

    def test_missing_cpu_metadata_is_inconclusive_not_a_traceback(self):
        baseline = self.write()
        candidate = self.independent()
        del candidate.report["environment"]["cpu"]
        code, decision = self.compare(baseline, candidate.write())
        self.assertEqual((code, decision["status"]), (3, "INCONCLUSIVE"))
        self.assertIn("metadata commands", decision["reason"])

    def test_runner_or_documentation_change_makes_reports_non_comparable(self):
        baseline = self.write()
        candidate = self.independent()
        candidate.report["artifact"]["task_source_digests"] = {"tools/benchmarks/m12_001_end_to_end.py": {
            "domain": "text-utf8-lf-v1", "sha256": "0" * 64}}
        code, decision = self.compare(baseline, candidate.write())
        self.assertEqual((code, decision["status"]), (3, "INCONCLUSIVE"))
        self.assertEqual(decision["status"], "INCONCLUSIVE")

    def test_independent_captures_compare_without_reusing_executions(self):
        baseline = self.write()
        candidate = self.independent()
        code, decision = self.compare(baseline, candidate.write())
        self.assertEqual(decision["status"], decision["status"])
        self.assertNotEqual(code, 3)


class RoundCohortSelection(unittest.TestCase):
    def test_warmup_and_old_rounds_cannot_hide_later_regression(self):
        samples = [{**row(), "round": i, "warmup": False} for i in range(7)]
        samples += [{**row(duration=2_000_000, tail=20_000), "round": i, "warmup": False} for i in range(7, 14)]
        samples.append({**row(duration=1, tail=1), "round": 7, "warmup": True})
        report = {"measured_process_rounds": 14, "samples": samples}
        before, _ = bench.selected_round_summaries(report, "0:7")
        after, _ = bench.selected_round_summaries(report, "7:14")
        case = "h1_bulk_4096"
        self.assertEqual(bench.classify(bench.freeze_reference(before[case]), after[case])["status"], "FAIL")

    def test_unmeasured_round_cannot_be_selected(self):
        with self.assertRaisesRegex(ValueError, "inside the measured"):
            bench.selected_round_summaries({"measured_process_rounds": 14}, "7:15")


if __name__ == "__main__":
    unittest.main()

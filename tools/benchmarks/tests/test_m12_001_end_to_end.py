"""Performance decisions must preserve outcome accounting and equivalent work."""
import copy
import unittest
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

from tools.benchmarks import m12_001_end_to_end as bench


def row(duration=1_000_000, tail=10_000, reads=2048):
    return {"scenario": "h1_bulk_4096", "regime": "normal", "duration_ns": duration,
            "operations": 100, "successes": 100, "failures": 0, "expected_rejections": 0,
            "bytes": 8 * 1024 * 1024, "checksum": 123456,
            "latencies_ns": [tail] * 100, "metrics": {"cleanup_owners": 0, "body_read_calls": reads}}


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

class RawEvidenceBinding(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "report.json"
        self.report = {"status": "PASS", "samples": [], "commands": [], "summary": {}, "reference": {}, "measured_process_rounds": 7}
        for cases in bench.CASES.values():
            for scenario in cases:
                rows = []
                for round_number in range(7):
                    native_case = "http_observed" if scenario == "http_unobserved" else scenario
                    native = row()
                    native["scenario"] = native_case
                    identity = f"{scenario}-{round_number}"
                    log = self.path.parent / (identity + ".log")
                    log.write_text(json.dumps(native) + "\n")
                    sample = {**native, "scenario": scenario, "native_scenario": native_case, "round": round_number, "warmup": False, "command_id": identity}
                    rows.append(sample)
                    self.report["samples"].append(sample)
                    self.report["commands"].append({"id": identity, "argv": ["main", native_case], "exit_code": 0, "timed_out": False,
                        "stdout": {"path": log.name, "digest": bench.text_evidence_digest(log).to_json()}})
                summary = bench.summarize(rows)
                self.report["summary"][scenario] = summary
                self.report["reference"][scenario] = bench.freeze_reference(summary)

    def load(self):
        self.path.write_text(json.dumps(self.report))
        return bench.load_verified_report(self.path)

    def test_cached_summary_cannot_invent_more_throughput(self):
        self.report["summary"]["tcp_bulk"]["successful_operations_per_second"] *= 2
        with self.assertRaisesRegex(ValueError, "differs from raw"):
            self.load()

    def test_changed_native_output_cannot_keep_old_digest(self):
        log = self.path.parent / self.report["commands"][0]["stdout"]["path"]
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

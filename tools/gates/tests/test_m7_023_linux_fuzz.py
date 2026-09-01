from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "tools/gates/m7_023_linux_fuzz.py"
SPEC = importlib.util.spec_from_file_location("m7_023_linux_fuzz", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)
MANIFEST = ROOT / "tools/gates/campaigns/m7-023-linux-fuzz.json"
GENERIC_MANIFESTS = ROOT / "tools/gates/manifests"


class M7023LinuxFuzzGateTest(unittest.TestCase):
    def targets(self):
        manifest, targets = gate.load_manifest(ROOT, MANIFEST)
        return manifest, targets

    def process(self, stdout: str, exit_code: int = 0, timed_out: bool = False):
        return {
            "command": ["cjpm", "test"],
            "exit_code": exit_code,
            "timed_out": timed_out,
            "duration_ms": 1.0,
            "stdout": stdout,
            "stderr": "",
        }

    def test_manifest_covers_exact_prd_targets_and_verified_corpora(self):
        manifest, targets = self.targets()
        self.assertEqual(7023, manifest["seed"])
        self.assertEqual(gate.EXPECTED_TARGETS, tuple(item["name"] for item in targets))
        for target in targets:
            self.assertEqual(target["corpus_sha256"], target["actual_corpus_sha256"])
            self.assertTrue(target["corpus_hex"])

    def test_campaign_manifest_is_not_in_generic_gate_runner_namespace(self):
        self.assertEqual("campaigns", MANIFEST.parent.name)
        self.assertNotIn(MANIFEST.name, {
            path.name for path in GENERIC_MANIFESTS.glob("*.json")
        })

    def test_classification_requires_one_exact_marker_and_threshold(self):
        _, targets = self.targets()
        target = targets[0]
        marker = (
            "M7023_FUZZ target=tls-record seed=7023 "
            "iterations=512 decision=PASS\n"
        )
        decision, reasons, parsed = gate.classify(target, 7023, self.process(marker))
        self.assertEqual("PASS", decision)
        self.assertEqual([], reasons)
        self.assertEqual(512, parsed["iterations"])

        decision, reasons, _ = gate.classify(
            target, 7023,
            self.process(marker.replace("iterations=512", "iterations=511")),
        )
        self.assertEqual("FAIL", decision)
        self.assertTrue(any("below threshold" in reason for reason in reasons))

        decision, reasons, _ = gate.classify(target, 7023, self.process(""))
        self.assertEqual("FAIL", decision)
        self.assertTrue(any("exactly one" in reason for reason in reasons))

    def test_nonzero_and_timeout_fail_even_with_a_pass_marker(self):
        _, targets = self.targets()
        target = targets[1]
        marker = (
            "M7023_FUZZ target=tls-handshake seed=7023 "
            "iterations=512 decision=PASS\n"
        )
        decision, reasons, _ = gate.classify(
            target, 7023, self.process(marker, exit_code=-9, timed_out=True)
        )
        self.assertEqual("FAIL", decision)
        self.assertIn("campaign timed out", reasons)
        self.assertIn("campaign exited -9", reasons)

    def test_crash_artifact_replays_only_checked_in_coordinates(self):
        manifest, targets = self.targets()
        manifest_digest = text_evidence_sha256ha256(MANIFEST)
        target = targets[4]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "replay.json"
            artifact = gate.save_crash(
                ROOT, root / "crashes", target, manifest["seed"], manifest_digest,
                ["synthetic failure"], self.process("", exit_code=1), output,
            )
            self.assertEqual(target["name"], gate.validate_replay(
                artifact, manifest_digest, targets
            )["name"])
            payload = json.loads(artifact.read_text(encoding="utf-8"))
            payload["filter"] = "Injected.filter"
            artifact.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(gate.GateError):
                gate.validate_replay(artifact, manifest_digest, targets)

    def test_path_escape_and_invalid_hex_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(gate.GateError):
                gate.checked_path(root, "../escape")
            corpus = root / "bad.hex"
            corpus.write_text("0xz", encoding="ascii")
            with self.assertRaises(gate.GateError):
                gate.decode_hex_corpus(corpus)

    def test_o2_rewrite_requires_one_compile_option(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cjpm.toml"
            path.write_text('[package]\n  compile-option = ""\n', encoding="utf-8")
            gate.enable_o2(path)
            self.assertIn('compile-option = "-O2"', path.read_text(encoding="utf-8"))
            path.write_text("[package]\n", encoding="utf-8")
            with self.assertRaises(gate.GateError):
                gate.enable_o2(path)


if __name__ == "__main__":
    unittest.main()

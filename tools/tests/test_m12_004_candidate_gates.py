"""Candidate orchestration rejection controls. No SDK or provider builds."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from tools import m12_004_candidate_gates as gate


class CandidateGatesTests(unittest.TestCase):
    def temporary(self):
        return tempfile.TemporaryDirectory()

    def test_native_same_size_mutation_rejected(self):
        with self.temporary() as directory:
            root = Path(directory)
            archive = root / 'provider.a'
            archive.write_bytes(b'abcd')
            payload = {'provider.a': b'abcd'}
            before = gate.inventory(root, payload)
            archive.write_bytes(b'abce')
            with self.assertRaisesRegex(ValueError, 'payload changed'):
                gate.assert_unchanged(root, payload, before)

    def test_default_build_hook_rejected(self):
        with self.temporary() as directory:
            root = Path(directory)
            (root / 'build.cj').write_text('unexpected hook')
            with self.assertRaisesRegex(ValueError, 'payload changed'):
                gate.assert_unchanged(root, {}, {})

    def test_overlay_cannot_replace_production(self):
        with self.temporary() as directory:
            root = Path(directory)
            source, installed = root / 'source', root / 'installed'
            name = gate.TEST_FILES[0]
            for base in (source, installed):
                path = base / name
                path.parent.mkdir(parents=True)
                path.write_text('same')
            with self.assertRaisesRegex(ValueError, 'collides'):
                gate.overlay(source, installed, [])

    def test_failures_do_not_reduce_fuzz_target_list(self):
        with patch.object(gate, 'overlay', return_value={}), patch.object(gate.fuzz, 'execute_target', side_effect=[{'decision': 'FAIL'}] + [{'decision': 'PASS'} for _ in range(9)]) as execute:
            runner = unittest.mock.Mock()
            runner.env = {}
            report = {}
            result = gate.fuzz_gate(runner, Path('/installed'), report)
        self.assertEqual(execute.call_count, 10)
        self.assertEqual(result['status'], 'FAIL')

    def test_original_markers_reject_skip(self):
        with self.temporary() as directory:
            path = Path(directory) / 'out'
            path.write_text('NATIVE_TLS_VERSIONS=PASS\nSKIP\n')
            with self.assertRaisesRegex(RuntimeError, 'skipped'):
                gate.tls.require_marker(path, 'versions12')

    def test_nested_tls_log_digest_rebound_after_normalization(self):
        with self.temporary() as directory:
            output = Path(directory)
            log = output / 'consumer-decrypt.stdout.log'
            log.write_text('normalized output\n')
            report = {'commands': [], 'scenario': {'stdout': {'path': log.name, 'digest': {'domain': 'text-utf8-lf-v1', 'sha256': '0' * 64}}}}
            runner = unittest.mock.Mock(output=output)
            runner.redact = lambda text: text
            gate.write_report(output / 'report.json', report, runner)
            self.assertEqual(report['scenario']['stdout']['digest'], gate.d.text_evidence_digest(log).to_json())

if __name__ == '__main__':
    unittest.main()

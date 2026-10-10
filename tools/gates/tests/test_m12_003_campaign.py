"""Fail-closed native campaign coverage and binding contracts."""
import copy
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from tools.evidence_digest import text_evidence_digest
from tools.gates import m12_003_campaign as gate


SPEC = {'families': {'network': {'required_coverage': ['delay', 'loss']}}}


def observation():
    return {'task_id': 'M12-003', 'family': 'network', 'seed': 184003, 'status': 'PASS',
            'profiles': [{'id': 'packet', 'status': 'PASS', 'coverage_keys': ['delay', 'loss'],
                          'semantic_criteria': {'affected_packets': True, 'recovery': True},
                          'cleanup': {'reaped': True}, 'applied_fault_proof': {'dropped_packets': 3}}]}


class CampaignContracts(unittest.TestCase):
    def test_partial_coverage_cannot_complete_family(self):
        report = observation(); report['profiles'][0]['coverage_keys'] = ['delay']
        result = gate.coverage(SPEC, {'network': [('report.json', report)]})['network']
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['missing'], ['loss'])

    def test_passing_round_does_not_hide_failed_round(self):
        failed = observation(); failed['status'] = 'FAIL'; failed['profiles'][0]['status'] = 'FAIL'
        result = gate.coverage(SPEC, {'network': [('first.json', failed), ('second.json', observation())]})['network']
        self.assertEqual(result['status'], 'FAIL')

    def test_contradictory_semantics_cannot_pass(self):
        report = observation(); report['profiles'][0]['semantic_criteria']['recovery'] = False
        with self.assertRaises(ValueError): gate.coverage(SPEC, {'network': [('report.json', report)]})

    def test_cleanup_and_fault_observations_are_required(self):
        for field in ('cleanup', 'applied_fault_proof'):
            report = observation(); report['profiles'][0].pop(field)
            with self.assertRaises(ValueError): gate.coverage(SPEC, {'network': [('report.json', report)]})

    def test_duplicate_execution_identity_is_rejected(self):
        report = observation(); report['profiles'].append(copy.deepcopy(report['profiles'][0]))
        with self.assertRaises(ValueError): gate.coverage(SPEC, {'network': [('report.json', report)]})

    def test_unknown_coverage_and_wrong_task_cannot_supply_acceptance(self):
        for mutate in (lambda r: r.update(task_id='M12-004'),
                       lambda r: r['profiles'][0].update(coverage_keys=['imaginary']),
                       lambda r: r.update(seed=True)):
            report = observation(); mutate(report)
            with self.assertRaises(ValueError): gate.coverage(SPEC, {'network': [('report.json', report)]})

    def test_changed_source_and_sdk_bytes_are_rejected(self):
        parent = Path(os.environ.get('TMPDIR', Path.home() / '.cache/agent-tmp'))
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            root = Path(directory); source = root / 'consumer.cj'; source.write_text('main() { 0 }\n')
            sdk = {'bin/cjc': {'domain': 'artifact-bytes-v1', 'sha256': 'a' * 64}}
            archive = {'domain': 'artifact-bytes-v1', 'sha256': 'b' * 64}
            report = {'archive': archive, 'payload_sha256': 'c' * 64, 'sdk_files': copy.deepcopy(sdk),
                      'source_digests': {'consumer.cj': text_evidence_digest(source).to_json()}}
            with patch.object(gate, 'ROOT', root):
                gate.validate_bindings('network', report, sdk, archive, 'c' * 64)
                source.write_text('main() { 1 }\n')
                with self.assertRaises(ValueError): gate.validate_bindings('network', report, sdk, archive, 'c' * 64)
                source.write_text('main() { 0 }\n')
                report['sdk_files']['bin/cjc']['sha256'] = 'd' * 64
                with self.assertRaises(ValueError): gate.validate_bindings('network', report, sdk, archive, 'c' * 64)

    def test_source_symlink_cannot_escape_repository(self):
        parent = Path(os.environ.get('TMPDIR', Path.home() / '.cache/agent-tmp'))
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            outer = Path(directory); root = outer / 'repo'; root.mkdir()
            outside = outer / 'outside'; outside.write_text('private\n'); (root / 'link').symlink_to(outside)
            with patch.object(gate, 'ROOT', root):
                with self.assertRaises(ValueError): gate.repository_path('link')


if __name__ == '__main__':
    unittest.main()

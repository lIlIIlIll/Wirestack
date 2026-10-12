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
                          'cleanup': {'fixture_threads_joined': True, 'impairments_removed': True,
                                      'post_removal_qdisc': 'qdisc noqueue 0: root refcnt 2'},
                          'applied_fault_proof': {'dropped_packets': 3}}]}


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

    def test_every_semantic_criterion_must_be_exactly_true(self):
        for value in (False, None, 0, 1, 'FAIL', 'PASS'):
            report = observation()
            report['profiles'][0]['semantic_criteria']['recovery'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                gate.coverage(SPEC, {'network': [('report.json', report)]})
        result = gate.coverage(SPEC, {'network': [('report.json', observation())]})['network']
        self.assertEqual(result['status'], 'PASS')

    def test_cleanup_predicates_must_be_exactly_true(self):
        for field in ('fixture_threads_joined', 'impairments_removed'):
            for value in (False, None, 0, 1, 'PASS'):
                report = observation()
                report['profiles'][0]['cleanup'][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    gate.coverage(SPEC, {'network': [('report.json', report)]})

    def test_cleanup_and_fault_observations_are_required(self):
        for field in ('cleanup', 'applied_fault_proof'):
            report = observation(); report['profiles'][0].pop(field)
            with self.assertRaises(ValueError): gate.coverage(SPEC, {'network': [('report.json', report)]})

    def test_non_network_cleanup_uses_its_family_contract(self):
        campaign = {'families': {'lifecycle': {'required_coverage': ['shutdown']}}}
        report = {'task_id': 'M12-003', 'family': 'lifecycle', 'seed': 184003, 'status': 'PASS',
                  'profiles': [{'id': 'shutdown', 'status': 'PASS', 'coverage_keys': ['shutdown'],
                                'semantic_criteria': {'process_reaped': True},
                                'cleanup': {'process_reaped': True, 'remaining_live_owned_processes': 0,
                                            'sampler_alive': False},
                                'applied_fault_proof': {'child_exit': 0}}]}
        result = gate.coverage(campaign, {'lifecycle': [('report.json', report)]})['lifecycle']
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual(result['missing'], [])

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

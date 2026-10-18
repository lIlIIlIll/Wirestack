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
FAMILY_SPEC = {'families': {
    'network': {'required_coverage': ['delay']},
    'resources': {'required_coverage': ['buffer_quota']},
    'lifecycle': {'required_coverage': ['shutdown']},
}}


def observation():
    return {'task_id': 'M12-003', 'family': 'network', 'seed': 184003, 'status': 'PASS',
            'profiles': [{'id': 'packet', 'status': 'PASS', 'coverage_keys': ['delay', 'loss'],
                          'semantic_criteria': {'affected_packets': True, 'recovery': True},
                          'cleanup': {'fixture_threads_joined': True, 'impairments_removed': True,
                                      'post_removal_qdisc': 'qdisc noqueue 0: root refcnt 2'},
                          'applied_fault_proof': {'dropped_packets': 3}}]}


def supplemental_network_profile(status='PASS'):
    return {'id': 'system-boundary', 'status': status, 'coverage_keys': [],
            'semantic_criteria': {'native_semantics': True},
            'cleanup': {'fixture_threads_joined': True, 'impairments_removed': True},
            'applied_fault_proof': {'scope': 'test-only system operation boundary'}}


def artifact(seed):
    return {'domain': 'artifact-bytes-v1', 'sha256': seed * 64}


def text_digest(seed):
    return {'domain': 'text-utf8-lf-v1', 'sha256': seed * 64}


def network_binding():
    sdk_files = {'bin/cjc': artifact('a'),
                 'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so': artifact('b'),
                 'runtime/lib/linux_x86_64_cjnative/libcangjie-std-net.so': artifact('c')}
    archive = artifact('d')
    report = {'archive': archive, 'payload_sha256': 'e' * 64, 'sdk_files': copy.deepcopy(sdk_files),
              'interposer': {'test_only': True,
                             'source': text_evidence_digest(gate.ROOT / 'tools/gates/native/gai_delay.c').to_json(),
                             'binary': artifact('f')},
              'source_digests': {name: text_evidence_digest(gate.ROOT / name).to_json()
                                 for name in gate.NETWORK_SOURCE_KEYS},
              'probe_source_digests': {}, 'execution_source_digests': {}}
    return report, sdk_files, archive


def lifecycle_binding():
    sdk_files = {'bin/cjc': artifact('a'),
                 'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so': artifact('b')}
    archive = artifact('d')
    production = {path.relative_to(gate.ROOT).as_posix() for path in gate.release.production_sources(gate.ROOT)}
    report = {'archive': {'digest': archive, 'payload_sha256': 'e' * 64},
              'sdk': {'compiler_digest': sdk_files['bin/cjc'],
                      'runtime_file_digests': {
                          'libcangjie-runtime.so': sdk_files['runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so']}},
              'sdk_files': copy.deepcopy(sdk_files),
              'source_digests': {name: text_evidence_digest(gate.ROOT / name).to_json() for name in production},
              'probe_source_digests': {name: text_evidence_digest(gate.ROOT / name).to_json()
                                       for name in gate.LIFECYCLE_PROBE_KEYS},
              'execution_source_digests': {}}
    return report, sdk_files, archive


def resource_binding():
    sdk_files = {'bin/cjc': artifact('a'),
                 'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so': artifact('b'),
                 'runtime/lib/linux_x86_64_cjnative/libcangjie-std-net.so': artifact('c')}
    archive = artifact('d')
    report = {'bindings': {'archive_digest': archive, 'payload_sha256': 'e' * 64},
              'sdk': {'std_net_digest': sdk_files['runtime/lib/linux_x86_64_cjnative/libcangjie-std-net.so'],
                      'compiler_digest': sdk_files['bin/cjc'],
                      'runtime_digest': sdk_files['runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so']},
              'sdk_files': copy.deepcopy(sdk_files),
              'source_digests': {name: text_evidence_digest(gate.ROOT / name).to_json()
                                 for name in gate.RESOURCE_SOURCE_KEYS},
              'probe_source_digests': {}, 'execution_source_digests': {}}
    return report, sdk_files, archive


def fresh_report(family, coverage_keys, criteria):
    """Report shape emitted by the current family producers after boolean normalization."""
    cleanup = {'lifecycle': {'process_reaped': True, 'remaining_live_owned_processes': 0, 'sampler_alive': False},
               'resources': {'child_reaped': True, 'dns_thread_stopped': True},
               'network': {'fixture_threads_joined': True, 'impairments_removed': True}}[family]
    return {'task_id': 'M12-003', 'family': family, 'seed': 184003, 'status': 'PASS',
            'profiles': [{'id': 'profile-1', 'status': 'PASS', 'coverage_keys': coverage_keys,
                          'semantic_criteria': criteria,
                          'cleanup': cleanup,
                          'applied_fault_proof': {'native_observation': True}}]}


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

    def test_supplemental_passing_profile_is_validated_without_coverage_keys(self):
        campaign = {'families': {'network': {'required_coverage': ['delay']}}}
        report = {'task_id': 'M12-003', 'family': 'network', 'seed': 184003, 'status': 'PASS',
                  'profiles': [supplemental_network_profile()]}
        result = gate.coverage(campaign, {'network': [('report.json', report)]})['network']
        self.assertEqual(result['status'], 'FAIL')  # required coverage key absent
        for mutate in (lambda profile: profile.update(semantic_criteria={'native_semantics': 'PASS'}),
                       lambda profile: profile.pop('cleanup'),
                       lambda profile: profile.pop('applied_fault_proof'),
                       lambda profile: profile['cleanup'].update(fixture_threads_joined=False)):
            broken = copy.deepcopy(report)
            mutate(broken['profiles'][0])
            with self.assertRaises(ValueError):
                gate.coverage(campaign, {'network': [('report.json', broken)]})

    def test_live_lifecycle_sampler_cannot_supply_a_pass(self):
        campaign = {'families': {'lifecycle': {'required_coverage': ['shutdown']}}}
        report = {'task_id': 'M12-003', 'family': 'lifecycle', 'seed': 184003, 'status': 'PASS',
                  'profiles': [{'id': 'shutdown', 'status': 'PASS', 'coverage_keys': ['shutdown'],
                                'semantic_criteria': {'process_reaped': True},
                                'cleanup': {'process_reaped': True, 'remaining_live_owned_processes': 0,
                                            'sampler_alive': True},
                                'applied_fault_proof': {'child_exit': 0}}]}
        with self.assertRaisesRegex(ValueError, 'sampler'):
            gate.coverage(campaign, {'lifecycle': [('report.json', report)]})

    def test_execution_source_binding_requires_the_exact_fleet(self):
        report, sdk, archive = network_binding()
        gate.validate_bindings('network', report, sdk, archive, 'e' * 64)
        for mutate in (lambda value: value['source_digests'].pop(next(iter(gate.NETWORK_SOURCE_KEYS))),
                       lambda value: value.pop('source_digests'),
                       lambda value: value['source_digests'].update(
                           {'examples/linux/m12_001/http.cj': text_evidence_digest(
                               gate.ROOT / 'examples/linux/m12_001/http.cj').to_json()}),
                       lambda value: value.update(execution_source_digests={
                           'src/common.cj': text_evidence_digest(gate.ROOT / 'src/common.cj').to_json()})):
            broken = copy.deepcopy(report)
            mutate(broken)
            with self.assertRaises(ValueError):
                gate.validate_bindings('network', broken, sdk, archive, 'e' * 64)

    def test_resource_report_requires_the_complete_qualified_sdk(self):
        report, sdk, archive = resource_binding()
        gate.validate_bindings('resources', report, sdk, archive, 'e' * 64)
        for mutate in (lambda value: value.pop('sdk_files'),
                       lambda value: value['sdk_files'].update({'tools/bin/cjpm': artifact('f')}),
                       lambda value: value['sdk_files'].pop('bin/cjc')):
            broken = copy.deepcopy(report)
            mutate(broken)
            with self.assertRaises(ValueError):
                gate.validate_bindings('resources', broken, sdk, archive, 'e' * 64)

    def test_network_interposer_source_is_bound(self):
        report, sdk, archive = network_binding()
        report['interposer']['source'] = text_digest('0')
        with self.assertRaisesRegex(ValueError, 'interposer'):
            gate.validate_bindings('network', report, sdk, archive, 'e' * 64)

    def test_lifecycle_report_requires_the_complete_qualified_sdk(self):
        report, sdk, archive = lifecycle_binding()
        gate.validate_bindings('lifecycle', report, sdk, archive, 'e' * 64)
        for mutate in (lambda value: value.pop('sdk_files'),
                       lambda value: value['sdk_files'].update({'tools/bin/cjpm': artifact('f')}),
                       lambda value: value['sdk_files'].pop('bin/cjc')):
            broken = copy.deepcopy(report)
            mutate(broken)
            with self.assertRaises(ValueError):
                gate.validate_bindings('lifecycle', broken, sdk, archive, 'e' * 64)

    def test_passing_profile_requires_nonempty_structured_observation(self):
        for value in ({}, [], '', 0, None):
            report = observation()
            report['profiles'][0]['applied_fault_proof'] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'nonempty structured native observation'):
                gate.coverage(SPEC, {'network': [('report.json', report)]})
        measured = observation()
        measured['profiles'][0].pop('applied_fault_proof')
        measured['profiles'][0]['measurement'] = {'native_ms': 12}
        result = gate.coverage(SPEC, {'network': [('report.json', measured)]})['network']
        self.assertEqual(result['status'], 'PASS')

    def test_complete_family_cleanup_contract_is_enforced(self):
        def lifecycle_report(cleanup):
            return {'task_id': 'M12-003', 'family': 'lifecycle', 'seed': 184003, 'status': 'PASS',
                    'profiles': [{'id': 'shutdown', 'status': 'PASS', 'coverage_keys': ['shutdown'],
                                  'semantic_criteria': {'process_reaped': True}, 'cleanup': cleanup,
                                  'applied_fault_proof': {'child_exit': 0}}]}
        lifecycle_campaign = {'families': {'lifecycle': {'required_coverage': ['shutdown']}}}
        good_lifecycle = {'process_reaped': True, 'remaining_live_owned_processes': 0,
                          'sampler_alive': False, 'peer_thread_alive': False, 'listener_closed': True}
        result = gate.coverage(lifecycle_campaign, {'lifecycle': [
            ('report.json', lifecycle_report(good_lifecycle))]})['lifecycle']
        self.assertEqual(result['status'], 'PASS')
        for field, value in (('process_reaped', False), ('remaining_live_owned_processes', 1),
                             ('sampler_alive', True), ('peer_thread_alive', True), ('listener_closed', False)):
            cleanup = dict(good_lifecycle)
            cleanup[field] = value
            with self.subTest(family='lifecycle', field=field), self.assertRaises(ValueError):
                gate.coverage(lifecycle_campaign, {'lifecycle': [('report.json', lifecycle_report(cleanup))]})

        def resource_report(cleanup):
            return {'task_id': 'M12-003', 'family': 'resources', 'seed': 184003, 'status': 'PASS',
                    'profiles': [{'id': 'buffer', 'status': 'PASS', 'coverage_keys': ['buffer_quota'],
                                  'semantic_criteria': {'native_profile_validated': True}, 'cleanup': cleanup,
                                  'applied_fault_proof': {'cpu_max': '25000 100000'}}]}
        resource_campaign = {'families': {'resources': {'required_coverage': ['buffer_quota']}}}
        good_resource = {'child_reaped': True, 'dns_thread_stopped': True}
        result = gate.coverage(resource_campaign, {'resources': [
            ('report.json', resource_report(good_resource))]})['resources']
        self.assertEqual(result['status'], 'PASS')
        for field in ('child_reaped', 'dns_thread_stopped'):
            cleanup = dict(good_resource)
            cleanup[field] = False
            with self.subTest(family='resources', field=field), self.assertRaises(ValueError):
                gate.coverage(resource_campaign, {'resources': [('report.json', resource_report(cleanup))]})

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
            interposer_source = root / 'gai_delay.c'; interposer_source.write_text('int gai_delay;\n')
            sdk = {'bin/cjc': {'domain': 'artifact-bytes-v1', 'sha256': 'a' * 64}}
            archive = {'domain': 'artifact-bytes-v1', 'sha256': 'b' * 64}
            report = {'archive': archive, 'payload_sha256': 'c' * 64, 'sdk_files': copy.deepcopy(sdk),
                      'interposer': {'source': text_evidence_digest(interposer_source).to_json()},
                      'source_digests': {'consumer.cj': text_evidence_digest(source).to_json()}}
            expected = {'source_digests': {'consumer.cj'}, 'probe_source_digests': set(),
                        'execution_source_digests': set()}
            mapping = {'tools/gates/native/gai_delay.c': interposer_source}
            with patch.object(gate, 'ROOT', root), \
                 patch.object(gate, 'expected_source_binding', return_value=expected), \
                 patch.object(gate, 'repository_path', side_effect=lambda name: mapping.get(name, root / name)):
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


class FreshProducerSchemaTests(unittest.TestCase):
    """collect/verify must validate the schema the commit's own producers emit."""

    def test_normalized_boolean_criteria_from_each_producer_supply_coverage(self):
        shapes = {
            'lifecycle': {'native_assertions': True, 'exact_byte_sequence': True, 'terminal_ledgers': True},
            'resources': {'native_profile_validated': True},
            'network': {'affected_packets': True, 'new_connection_after_removal': True},
        }
        reports = {family: [('report.json', fresh_report(
                        family, FAMILY_SPEC['families'][family]['required_coverage'], criteria))]
                   for family, criteria in shapes.items()}
        result = gate.coverage(FAMILY_SPEC, reports)
        self.assertEqual({family: row['status'] for family, row in result.items()},
                         {'lifecycle': 'PASS', 'resources': 'PASS', 'network': 'PASS'})
        self.assertEqual({family: row['missing'] for family, row in result.items()},
                         {'lifecycle': [], 'resources': [], 'network': []})

    def test_non_boolean_criteria_cannot_supply_any_family(self):
        for family, criteria in (
                ('lifecycle', {'native_assertions': 'PASS'}),
                ('resources', {'classification': 'supported', 'supported_configuration': True}),
                ('network', {'recovery': 1})):
            report = fresh_report(family, FAMILY_SPEC['families'][family]['required_coverage'], criteria)
            with self.subTest(family=family), self.assertRaises(ValueError):
                gate.coverage(FAMILY_SPEC, {family: [('report.json', report)]})


if __name__ == '__main__':
    unittest.main()

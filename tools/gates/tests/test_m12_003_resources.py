"""Behavioral resource evidence checks. No source-text or wiring assertions."""
import copy
import unittest
from tools.gates import m12_003_resources as gate


def observed(scenario='buffers'):
    row = 'connections=0 reserved_connections=0 requests=0 streams=0 reserved_streams=0 buffers=0 owners=0 waiters=0 pool_waiters=0 rejected=0'
    during = row.replace('buffers=0 owners=0', 'buffers=131072 owners=1')
    after = row.replace('rejected=0', 'rejected=2')
    queued = during.replace('waiters=0 pool_waiters', 'waiters=1 pool_waiters')
    return {'exit_code': 0, 'timed_out': False, 'cleanup': {'child_reaped': True, 'dns_thread_stopped': True},
            'applied_fault_proof': {'cpu_max': '25000 100000', 'memory_max': '536870912',
                                    'cpu_before': {'nr_throttled': 0, 'throttled_usec': 0},
                                    'cpu_after': {'nr_throttled': 1, 'throttled_usec': 25},
                                    'memory_before': {'oom_kill': 0, 'max': 0}, 'memory_after': {'oom_kill': 0, 'max': 0}},
            'samples': [{'elapsed_ms': 0, 'fd': 4, 'tasks': 6, 'rss_kib': 24000}],
            'dns_packets': [], 'stderr': '',
            'stdout': 'LEDGER during '+during+'\nLEDGER queued '+queued+'\nLEDGER after '+after+
                      '\nRESULT cancelled\nRESULT deadline\nCHECK '+gate.CHECKS[scenario]+' PASS\n'}


class ResourceEvidenceTests(unittest.TestCase):
    def test_supported_profile_retains_distinct_logical_counters(self):
        result = gate.validate_profile('buffers', observed())
        self.assertEqual(result['classification'], 'supported')
        self.assertEqual(result['public_ledgers']['after']['buffers'], 0)
        self.assertIn('cancellation_registrations', result['unavailable_counters'])

    def test_kernel_oom_cannot_be_supported_even_with_success_marker(self):
        result = observed('memory')
        result['applied_fault_proof']['memory_after']['oom_kill'] = 1
        self.assertEqual(gate.classify_memory(result), 'kernel_oom')
        with self.assertRaises(ValueError):
            gate.validate_profile('memory', result)

    def test_signal_alone_is_not_kernel_oom(self):
        result = observed(); result['exit_code'] = -9
        self.assertEqual(gate.classify_memory(result), 'runtime_or_native_signal')

    def test_unknown_process_failure_is_not_library_refusal_or_oom(self):
        result = observed(); result['exit_code'] = 1
        result['classification'] = 'library_refusal'
        result['stderr'] = 'unstructured diagnostics'
        self.assertEqual(gate.classify_memory(result), 'runtime_or_native_failure')
        with self.assertRaises(ValueError):
            gate.validate_profile('buffers', result)

    def test_refusal_label_without_structured_refusal_is_not_trusted(self):
        result = observed(); result['exit_code'] = 1; result['classification'] = 'library_refusal'
        self.assertEqual(gate.classify_memory(result), 'runtime_or_native_failure')

    def test_runtime_oom_requires_dedicated_exit_and_typed_consumer_marker(self):
        result = observed()
        result.update(exit_code=23, stdout='ALLOC bytes=4194304\nRUNTIME_ERROR code=out_of_memory\n', stderr='arbitrary diagnostic wording')
        result['applied_fault_proof']['memory_max'] = '100663296'
        result['applied_fault_proof']['cpu_max'] = '100000 100000'
        result['applied_fault_proof']['memory_after']['max'] = 1
        self.assertEqual(gate.classify_memory(result), 'runtime_oom')
        outcome = gate.validate_profile('memory_pressure', result)
        self.assertFalse(outcome['supported_configuration'])
        self.assertFalse(outcome['library_refusal'])
        self.assertTrue(outcome['typed_runtime_oom'])
        for mutate in (lambda r: r.update(exit_code=1), lambda r: r.update(stdout='ALLOC bytes=4194304\n'),
                       lambda r: r.update(stdout=r['stdout'] + 'RUNTIME_ERROR code=out_of_memory\n')):
            other = copy.deepcopy(result); mutate(other)
            self.assertEqual(gate.classify_memory(other), 'runtime_or_native_failure')

    def test_pressure_requires_ceiling_proof_and_real_allocation(self):
        result = observed(); result.update(exit_code=1, stdout='ALLOC bytes=4194304\n', stderr='unstructured diagnostics')
        result['applied_fault_proof']['memory_max'] = '100663296'
        result['applied_fault_proof']['cpu_max'] = '100000 100000'
        with self.assertRaises(ValueError): gate.validate_profile('memory_pressure', result)
        result['applied_fault_proof']['memory_after']['max'] = 1
        outcome = gate.validate_profile('memory_pressure', result)
        self.assertFalse(outcome['supported_configuration'])
        self.assertEqual(outcome['classification'], 'runtime_or_native_failure')

    def test_unlimited_or_wrong_cgroup_is_not_fault_application(self):
        for key, value in [('cpu_max', 'max 100000'), ('cpu_max', '50000 100000'), ('memory_max', 'max'), ('memory_max', '1073741824')]:
            result = observed(); result['applied_fault_proof'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError): gate.validate_profile('buffers', result)

    def test_quota_without_throttling_does_not_prove_cpu_fault(self):
        result = observed('cpu'); result['applied_fault_proof']['cpu_after'] = copy.deepcopy(result['applied_fault_proof']['cpu_before'])
        with self.assertRaises(ValueError): gate.validate_profile('cpu', result)

    def test_residue_missing_samples_and_incomplete_cleanup_fail_closed(self):
        for mutate in (lambda r: r.update(stdout=r['stdout'].replace('LEDGER after connections=0', 'LEDGER after connections=1')),
                       lambda r: r.update(samples=[]), lambda r: r['cleanup'].update(child_reaped=False),
                       lambda r: r.update(timed_out=True), lambda r: r.update(stdout=r['stdout'].replace('RESULT cancelled', ''))):
            result = observed(); mutate(result)
            with self.assertRaises(ValueError): gate.validate_profile('buffers', result)

    def test_marker_cannot_replace_missing_public_ledger(self):
        result = observed(); result['stdout'] = 'CHECK buffers_waiters_owners PASS\n'
        with self.assertRaises(ValueError): gate.validate_profile('buffers', result)

    def test_deadline_overshoot_is_enforced(self):
        result = observed(); result['stdout'] += 'DEADLINE elapsed_ns=1100000001 budget_ns=100000000\n'
        with self.assertRaises(ValueError): gate.validate_profile('buffers', result)

    def test_duplicate_native_completion_fails(self):
        result = observed(); result['stdout'] += 'CHECK buffers_waiters_owners PASS\n'
        with self.assertRaises(ValueError): gate.validate_profile('buffers', result)


if __name__ == '__main__':
    unittest.main()

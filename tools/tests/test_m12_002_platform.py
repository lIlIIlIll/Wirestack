"""Reject misleading deployment claims against real native VM consumer evidence."""
import copy
import json
from pathlib import Path
import unittest
from tools.m12_002_platform import ROOT, verify_report
from tools.evidence_digest import artifact_byte_digest_bytes


class NativePlatformEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = ROOT / 'docs/evidence/M12-002/platform/westmere-glibc244'
        cls.report = json.loads((cls.evidence / 'report.json').read_text())
        cls.stable = json.loads((ROOT / 'docs/evidence/M12-002/source-sdk/stable-native/report.json').read_text())

    def reject(self, field, value, reason):
        changed = copy.deepcopy(self.report)
        changed[field] = value
        with self.assertRaisesRegex(ValueError, reason):
            verify_report(changed, self.evidence, self.stable)

    def test_container_cannot_claim_native_kernel_boundary(self):
        self.reject('virtualization', 'docker', 'independent native VM')

    def test_shared_kernel_cannot_claim_old_kernel(self):
        self.reject('kernel', self.report['host_kernel'], 'independent native VM')

    def test_avx_enabled_vm_cannot_claim_weaker_cpu(self):
        self.reject('cpu_flags', self.report['cpu_flags'] + ['avx'], 'CPU boundary')

    def test_partial_native_scenarios_cannot_claim_supported_profile(self):
        self.reject('same_binary_check_count', 46, 'native scenarios missing')

    def test_rebuilt_binary_cannot_substitute_same_binary_proof(self):
        changed = copy.deepcopy(self.report)
        changed['same_binary']['cli']['digest'] = artifact_byte_digest_bytes(b'another executable').to_json()
        with self.assertRaisesRegex(ValueError, 'substituted a rebuild'):
            verify_report(changed, self.evidence, self.stable)

    def test_missing_sdk_input_cannot_claim_qualified_runtime(self):
        changed = copy.deepcopy(self.report)
        del changed['sdk_files']['bin/cjc']
        with self.assertRaisesRegex(ValueError, 'SDK closure is incomplete'):
            verify_report(changed, self.evidence, self.stable)

    def test_different_sdk_bits_cannot_reuse_native_profile(self):
        changed = copy.deepcopy(self.report)
        changed['sdk_files']['bin/cjc'] = artifact_byte_digest_bytes(b'different compiler').to_json()
        with self.assertRaisesRegex(ValueError, 'SDK closure differs'):
            verify_report(changed, self.evidence, self.stable)


if __name__ == '__main__':
    unittest.main()

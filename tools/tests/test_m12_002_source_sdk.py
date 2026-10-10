"""Public verifier behavior using captured native evidence, without fake compilers."""
import copy
import json
import os
from pathlib import Path
import unittest

from tools.m12_002_source_sdk import ROOT, verify_report
from tools.evidence_digest import artifact_byte_digest_bytes


class SourceSdkEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        report = os.environ.get('WIRESTACK_SOURCE_SDK_REPORT')
        sdk = os.environ.get('WIRESTACK_SOURCE_SDK_ROOT')
        if not report or not sdk:
            raise unittest.SkipTest('Set WIRESTACK_SOURCE_SDK_REPORT and WIRESTACK_SOURCE_SDK_ROOT to real captured evidence')
        cls.path = Path(report)
        cls.sdk = Path(sdk).resolve()
        cls.archive = ROOT / 'docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz'
        cls.report = json.loads(cls.path.read_text())

    def test_changed_archive_cannot_reuse_report(self):
        changed = copy.deepcopy(self.report)
        changed['archive_digest'] = artifact_byte_digest_bytes(b'different artifact').to_json()
        with self.assertRaisesRegex(ValueError, 'archive binding changed'):
            verify_report(changed, self.archive, self.sdk, self.path.parent)

    def test_new_compiler_cannot_reuse_report(self):
        changed = copy.deepcopy(self.report)
        changed['sdk_files']['bin/cjc'] = artifact_byte_digest_bytes(b'different compiler').to_json()
        with self.assertRaisesRegex(ValueError, 'SDK compiler/runtime/import binding changed'):
            verify_report(changed, self.archive, self.sdk, self.path.parent)

    def test_new_runtime_cannot_reuse_report(self):
        changed = copy.deepcopy(self.report)
        runtime = next(k for k in changed['sdk_files'] if k.endswith('libcangjie-runtime.so'))
        changed['sdk_files'][runtime] = artifact_byte_digest_bytes(b'different runtime').to_json()
        with self.assertRaisesRegex(ValueError, 'SDK compiler/runtime/import binding changed'):
            verify_report(changed, self.archive, self.sdk, self.path.parent)

    def test_build_success_is_not_binary_cross_sdk_support(self):
        changed = copy.deepcopy(self.report)
        changed['binary_cross_sdk'] = 'PASS'
        with self.assertRaisesRegex(ValueError, 'source-only compatibility proof'):
            verify_report(changed, self.archive, self.sdk, self.path.parent)


if __name__ == '__main__':
    unittest.main()

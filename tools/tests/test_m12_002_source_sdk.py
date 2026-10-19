"""Public verifier behavior using captured native evidence, without fake compilers."""
import copy
import json
import os
from pathlib import Path
import unittest

from tools.m12_002_source_sdk import (ROOT, consumer_source_digests, validate_resume,
    verify_consumer_sources, verify_report)
from tools.evidence_digest import artifact_byte_digest_bytes


def text_digest(seed):
    return {'domain': 'text-utf8-lf-v1', 'sha256': seed * 64}


def artifact_digest(seed):
    return {'domain': 'artifact-bytes-v1', 'sha256': seed * 64}


class ResumeDriftTests(unittest.TestCase):
    def report(self):
        return {'runner_digest': text_digest('a'),
                'native_cc_digest': artifact_digest('d'),
                'build_options': {'environment': {'CFLAGS': '', 'CXXFLAGS': '', 'LDFLAGS': '', 'CJC_FLAGS': ''}},
                'consumer_sources': {'examples/linux/m11_004/cli/src/main.cj': text_digest('b')}}

    def test_matching_retained_inputs_are_accepted(self):
        validate_resume(self.report(), self.report())

    def test_changed_capture_runner_is_rejected(self):
        previous = self.report()
        current = self.report()
        current['runner_digest'] = text_digest('c')
        with self.assertRaisesRegex(ValueError, 'capture runner'):
            validate_resume(previous, current)

    def test_changed_native_compiler_is_rejected(self):
        previous = self.report()
        current = self.report()
        current['native_cc_digest'] = artifact_digest('e')
        with self.assertRaisesRegex(ValueError, 'native compiler'):
            validate_resume(previous, current)

    def test_unbound_native_compiler_is_rejected(self):
        previous = self.report()
        previous.pop('native_cc_digest')
        with self.assertRaisesRegex(ValueError, 'native compiler'):
            validate_resume(previous, self.report())

    def test_changed_build_options_are_rejected(self):
        previous = self.report()
        current = self.report()
        current['build_options']['environment']['CJC_FLAGS'] = '-O3'
        with self.assertRaisesRegex(ValueError, 'native build options'):
            validate_resume(previous, current)

    def test_changed_consumer_source_is_rejected(self):
        previous = self.report()
        current = self.report()
        current['consumer_sources']['examples/linux/m11_004/cli/src/main.cj'] = text_digest('c')
        with self.assertRaisesRegex(ValueError, 'consumer sources'):
            validate_resume(previous, current)

    def test_added_consumer_source_is_rejected(self):
        previous = self.report()
        current = self.report()
        current['consumer_sources']['examples/linux/m11_004/decoded/src/main.cj'] = text_digest('c')
        with self.assertRaisesRegex(ValueError, 'consumer sources'):
            validate_resume(previous, current)


class ConsumerSourceInventoryTests(unittest.TestCase):
    def setUp(self):
        self.inventory = consumer_source_digests()

    def test_inventory_contains_every_app_file_and_sdk_fixture(self):
        from tools import m11_004_installed_consumers as consumers
        expected = {str(path.relative_to(ROOT)) for name in consumers.APP_NAMES
                    for path in consumers.app_files(consumers.APPS / name)}
        expected |= {str(path.relative_to(ROOT)) for path in
                     (ROOT / 'examples/linux/m12_002/sdk/cjpm.toml', ROOT / 'examples/linux/m12_002/sdk/src/main.cj')}
        self.assertEqual(set(self.inventory), expected)

    def test_complete_recorded_inventory_is_accepted(self):
        verify_consumer_sources({'consumer_sources': self.inventory})

    def test_missing_or_extra_consumer_source_is_rejected(self):
        incomplete = dict(self.inventory)
        incomplete.pop(next(iter(incomplete)))
        with self.assertRaisesRegex(ValueError, 'consumer source inventory changed'):
            verify_consumer_sources({'consumer_sources': incomplete})
        extra = dict(self.inventory)
        extra['examples/linux/m11_004/cli/src/removed.cj'] = text_digest('f')
        with self.assertRaisesRegex(ValueError, 'consumer source inventory changed'):
            verify_consumer_sources({'consumer_sources': extra})

    def test_changed_consumer_source_digest_is_rejected(self):
        changed = dict(self.inventory)
        changed[next(iter(changed))] = text_digest('f')
        with self.assertRaisesRegex(ValueError, 'consumer source changed'):
            verify_consumer_sources({'consumer_sources': changed})


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

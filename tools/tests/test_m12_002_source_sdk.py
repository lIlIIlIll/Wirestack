"""Public verifier behavior using captured native evidence, without fake compilers."""
import copy
import json
import os
from pathlib import Path
import unittest

from tools.m12_002_source_sdk import (ROOT, consumer_retained, expected_consumer_sources,
                                     validate_resume, verify_consumer_sources, verify_report)
from tools.evidence_digest import artifact_byte_digest, artifact_byte_digest_bytes, text_evidence_digest


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

    def test_changed_build_options_are_rejected(self):
        previous = self.report()
        current = self.report()
        current['build_options']['environment']['CFLAGS'] = '-O3'
        with self.assertRaisesRegex(ValueError, 'build options'):
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


class ConsumerInventoryTests(unittest.TestCase):
    def report(self):
        return {'consumer_sources': {name: text_evidence_digest(ROOT / name).to_json()
                                     for name in expected_consumer_sources()}}

    def test_complete_inventory_is_accepted(self):
        report = self.report()
        verify_consumer_sources(report)
        self.assertTrue({'examples/linux/m11_004/cli/src/main.cj',
                         'examples/linux/m11_004/decoded/src/main.cj',
                         'examples/linux/m11_004/streams/src/main.cj',
                         'examples/linux/m11_004/service/src/main.cj',
                         'examples/linux/m12_002/sdk/cjpm.toml',
                         'examples/linux/m12_002/sdk/src/main.cj'} <= set(report['consumer_sources']))

    def test_omitted_changed_or_added_source_is_rejected(self):
        for mutate in (lambda value: value['consumer_sources'].pop(next(iter(value['consumer_sources']))),
                       lambda value: value['consumer_sources'].update(
                           {'examples/linux/m11_004/cli/src/main.cj': text_digest('0')}),
                       lambda value: value['consumer_sources'].update(
                           {'examples/linux/unexpected/fixture.cj': text_digest('0')}),
                       lambda value: value.pop('consumer_sources')):
            report = self.report()
            mutate(report)
            with self.assertRaisesRegex(ValueError, 'consumer source'):
                verify_consumer_sources(report)


class RetainedConsumerTests(unittest.TestCase):
    def test_only_successful_retained_consumer_with_matching_binary_is_reused(self):
        binary = Path(__file__).resolve()
        previous = {'consumers': {'cli': {'binary_digest': artifact_byte_digest(binary).to_json()}}}
        commands = [{'id': 'cli-acceptance', 'exit_code': 0}]
        self.assertTrue(consumer_retained(previous, commands, 'cli', binary))
        self.assertFalse(consumer_retained(None, commands, 'cli', binary))
        self.assertFalse(consumer_retained(previous, [], 'cli', binary))
        self.assertFalse(consumer_retained(previous, [{'id': 'cli-acceptance', 'exit_code': 1}], 'cli', binary))
        self.assertFalse(consumer_retained(previous, commands, 'decoded', binary))
        self.assertFalse(consumer_retained(previous, commands, 'cli', binary.with_name('missing-binary')))


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

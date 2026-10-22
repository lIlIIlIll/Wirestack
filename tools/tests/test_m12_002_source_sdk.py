"""Public verifier behavior using captured native evidence, without fake compilers."""
import copy
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

from tools.m12_002_source_sdk import (EXPECTED_COMMANDS, HELPER_SOURCES, ROOT,
    consumer_source_digests, helper_sources, native_compiler, validate_resume,
    verify_command_inventory, verify_consumer_sources, verify_helper_sources,
    verify_report, verify_retained_binary, verify_retained_commands)
from tools.evidence_digest import (artifact_byte_digest, artifact_byte_digest_bytes,
    text_evidence_digest)


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


class HelperBindingTests(unittest.TestCase):
    """The verdict depends on imported helpers, so their bytes must be part of the report."""

    def test_every_imported_helper_is_bound(self):
        recorded = helper_sources()
        self.assertEqual(recorded.keys(), set(HELPER_SOURCES))
        verify_helper_sources({'helper_sources': recorded})

    def test_missing_helper_is_rejected(self):
        recorded = dict(helper_sources())
        del recorded['tools/m11_004_installed_consumers.py']
        with self.assertRaisesRegex(ValueError, 'evidence helper inventory changed'):
            verify_helper_sources({'helper_sources': recorded})

    def test_changed_helper_is_rejected(self):
        recorded = dict(helper_sources())
        recorded['tools/evidence_digest.py'] = text_digest('f')
        with self.assertRaisesRegex(ValueError, 'evidence helper changed: tools/evidence_digest.py'):
            verify_helper_sources({'helper_sources': recorded})

    def test_unbound_helper_report_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'evidence helper inventory changed'):
            verify_helper_sources({'helper_sources': {}})


class CommandInventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-source-commands-')
        self.evidence = Path(self.directory.name)
        self.commands = []
        for name, expected in EXPECTED_COMMANDS.items():
            logs = {stream: self.evidence / f'{name}.{stream}.log' for stream in ('stdout', 'stderr')}
            for stream, log in logs.items():
                log.write_text(name + '\n' if stream == 'stdout' else '')
            self.commands.append({'id': name, 'exit_code': expected,
                'expected_exit_code': expected, 'timed_out': False,
                **{stream: {'path': log.name, 'digest': text_evidence_digest(log).to_json()}
                   for stream, log in logs.items()}})

    def tearDown(self):
        self.directory.cleanup()

    def test_complete_inventory_is_accepted(self):
        verify_command_inventory(self.commands, self.evidence)
        verify_retained_commands(self.commands, self.evidence)

    def test_omitted_command_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'command inventory is incomplete'):
            verify_command_inventory(self.commands[1:], self.evidence)

    def test_duplicated_command_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'command inventory contains duplicates'):
            verify_command_inventory(self.commands + [self.commands[0]], self.evidence)

    def test_reclassified_ca_expectation_is_rejected(self):
        changed = copy.deepcopy(self.commands)
        next(c for c in changed if c['id'] == 'missing-explicit-ca')['expected_exit_code'] = 0
        with self.assertRaisesRegex(ValueError, 'command expectation reclassified: missing-explicit-ca'):
            verify_command_inventory(changed, self.evidence)

    def test_ca_check_without_its_native_failure_is_rejected(self):
        changed = copy.deepcopy(self.commands)
        next(c for c in changed if c['id'] == 'system-ca-missing')['exit_code'] = 0
        with self.assertRaisesRegex(ValueError, 'command did not satisfy its native outcome: system-ca-missing'):
            verify_command_inventory(changed, self.evidence)

    def test_timed_out_command_is_rejected(self):
        changed = copy.deepcopy(self.commands)
        changed[0]['timed_out'] = True
        with self.assertRaisesRegex(ValueError, 'command timed out: cjc'):
            verify_command_inventory(changed, self.evidence)

    def test_changed_retained_log_is_rejected(self):
        (self.evidence / 'cjc.stdout.log').write_text('changed\n')
        with self.assertRaisesRegex(ValueError, 'command evidence changed: cjc'):
            verify_command_inventory(self.commands, self.evidence)
        with self.assertRaisesRegex(ValueError, 'retained command log changed: cjc'):
            verify_retained_commands(self.commands, self.evidence)


class RetainedBinaryTests(unittest.TestCase):
    def test_retained_binary_must_still_match(self):
        with tempfile.TemporaryDirectory(prefix='m12-retained-') as directory:
            binary = Path(directory) / 'main'
            binary.write_bytes(b'built consumer')
            verify_retained_binary({'binary_digest': artifact_byte_digest(binary).to_json()}, binary)
            binary.write_bytes(b'changed consumer')
            with self.assertRaisesRegex(ValueError, 'retained consumer binary changed'):
                verify_retained_binary({'binary_digest': artifact_byte_digest_bytes(b'built consumer').to_json()}, binary)
            binary.unlink()
            with self.assertRaisesRegex(ValueError, 'retained consumer binary is missing'):
                verify_retained_binary({}, binary)


class NativeCompilerTests(unittest.TestCase):
    def test_missing_compiler_is_reported_instead_of_fabricated(self):
        original = shutil.which
        shutil.which = lambda name, *args: None if name == 'cc' else original(name, *args)
        try:
            with self.assertRaisesRegex(ValueError, 'native C compiler cc is unavailable'):
                native_compiler()
        finally:
            shutil.which = original

    def test_present_compiler_resolves_to_an_executable(self):
        if not shutil.which('cc'):
            self.skipTest('host C compiler unavailable')
        self.assertTrue(native_compiler().is_file())


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

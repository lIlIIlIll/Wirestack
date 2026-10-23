"""The deployment collector binds retained profiles to current inputs, never to their own keys."""
import inspect
import json
import os
import shutil
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
from tools import m12_002_binary as binary_verifier
from tools import m12_002_deployment as deployment
from tools import m12_002_source_sdk as source_sdk
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest


def binary_artifact_digest(path: Path):
    """Typed byte digest of a compiled library, kept out of the text-evidence domain."""
    return artifact_byte_digest(path).to_json()


def compiled_profile():
    return {'native_cc_digest': artifact_byte_digest(Path(shutil.which('cc'))).to_json(),
            'production_sources': {str(path.relative_to(deployment.ROOT)): artifact_byte_digest(path).to_json()
                                   for path in release.production_sources(deployment.ROOT)}}


@unittest.skipUnless(shutil.which('cc'), 'host C compiler required')
class CompilerBindingTests(unittest.TestCase):
    def test_the_compiler_that_produced_the_profile_is_accepted(self):
        deployment.require_compiler_binding(compiled_profile())

    def test_a_changed_compiler_rejects_the_retained_profile(self):
        profile = compiled_profile()
        other = dict(profile['native_cc_digest'], sha256='0' * 64)
        with self.assertRaisesRegex(ValueError, 'native compiler changed'):
            deployment.require_compiler_binding(dict(profile, native_cc_digest=other))

    def test_an_absent_compiler_is_a_controlled_refusal(self):
        profile = compiled_profile()
        original = shutil.which
        source_sdk.shutil.which = lambda name, *args: None if name == 'cc' else original(name, *args)
        try:
            with self.assertRaisesRegex(ValueError, 'native C compiler cc is unavailable'):
                deployment.require_compiler_binding(profile)
        finally:
            source_sdk.shutil.which = original


@unittest.skipUnless(shutil.which('cc'), 'host C compiler required')
class ProductionInventoryTests(unittest.TestCase):
    def test_the_complete_current_inventory_is_accepted(self):
        deployment.require_production_inventory(compiled_profile())

    def test_a_missing_production_source_is_rejected(self):
        profile = compiled_profile()
        removed = sorted(profile['production_sources'])[0]
        del profile['production_sources'][removed]
        with self.assertRaisesRegex(ValueError, 'not the current production sources'):
            deployment.require_production_inventory(profile)

    def test_an_unrelated_extra_entry_is_rejected_although_the_count_matches(self):
        profile = compiled_profile()
        removed = sorted(profile['production_sources'])[0]
        profile['production_sources']['src/unrelated_platform.cj'] = profile['production_sources'].pop(removed)
        self.assertEqual(len(profile['production_sources']),
            len(release.production_sources(deployment.ROOT)))
        with self.assertRaisesRegex(ValueError, 'not the current production sources'):
            deployment.require_production_inventory(profile)

    def test_changed_source_bytes_are_rejected(self):
        profile = compiled_profile()
        changed = sorted(profile['production_sources'])[0]
        profile['production_sources'][changed] = dict(profile['production_sources'][changed], sha256='1' * 64)
        with self.assertRaisesRegex(ValueError, 'production source changed'):
            deployment.require_production_inventory(profile)


class BinaryInputSelectionTests(unittest.TestCase):
    """The binary verifier receives the selected inputs, in the signature it declares."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-deployment-inputs-')
        self.root = Path(self.directory.name)
        self.capture = self.root / 'capture'
        self.capture.mkdir()
        self.wrapper = self.root / 'wrapper'
        self.wrapper.write_text('#!/bin/sh\nexec "$@"\n')
        self.openssl = self.root / 'libssl.so.3'
        self.openssl.write_bytes(b'ssl')
        self.crypto = self.root / 'libcrypto.so.3'
        self.crypto.write_bytes(b'crypto')
        self.consumers = {}
        for profile in binary_verifier.CONSUMER_PROFILES:
            for app in binary_verifier.CONSUMER_APPS:
                binary = self.capture / profile / app / 'target/release/bin/main'
                binary.parent.mkdir(parents=True)
                binary.write_bytes((profile + app).encode())
                self.consumers[profile + '/' + app] = str(binary).replace(str(self.capture), '<scratch>')
        self.binary = {'consumers': self.consumers,
            'external_tls_fixture': {'library_digest': binary_artifact_digest(self.openssl),
                'crypto_library_digest': binary_artifact_digest(self.crypto)}}
        self.source_capture = self.root / 'source-capture'
        self.source_capture.mkdir()
        self.environment = {'WIRESTACK_BINARY_CAPTURE_ROOT': str(self.capture),
            'WIRESTACK_SOURCE_CAPTURE_ROOT': str(self.source_capture),
            'WIRESTACK_BINARY_WRAPPER': str(self.wrapper),
            'WIRESTACK_BINARY_OPENSSL_LIBRARY': str(self.openssl),
            'WIRESTACK_BINARY_OPENSSL_CRYPTO_LIBRARY': str(self.crypto)}

    def tearDown(self):
        self.directory.cleanup()

    def selected_inputs(self, environment=None):
        with patch.dict(os.environ, self.environment if environment is None else environment):
            return deployment.selected_binary_inputs()

    def test_every_binary_input_is_an_explicit_selection(self):
        selected = self.selected_inputs()
        self.assertEqual(selected['capture_root'], self.capture.resolve())
        self.assertEqual(selected['wrapper'], self.wrapper.resolve())
        self.assertEqual(selected['openssl_library'], self.openssl.resolve())
        self.assertEqual(selected['openssl_crypto_library'], self.crypto.resolve())

    def test_a_missing_binary_selector_is_a_controlled_refusal(self):
        for variable in (name for name in self.environment if name.startswith('WIRESTACK_BINARY_')):
            with self.subTest(variable=variable):
                incomplete = {key: value for key, value in self.environment.items() if key != variable}
                with self.assertRaisesRegex(ValueError, variable + ' must select'):
                    self.selected_inputs(incomplete)

    def test_a_selected_file_that_does_not_exist_is_rejected(self):
        absent = dict(self.environment, WIRESTACK_BINARY_WRAPPER=str(self.root / 'absent'))
        with self.assertRaisesRegex(ValueError, 'selection does not name a file'):
            self.selected_inputs(absent)

    def test_the_source_capture_root_is_required(self):
        without = {key: value for key, value in self.environment.items()
            if key != 'WIRESTACK_SOURCE_CAPTURE_ROOT'}
        with patch.dict(os.environ, without, clear=True):
            with self.assertRaisesRegex(ValueError,
                    'WIRESTACK_SOURCE_CAPTURE_ROOT must select the retained source captures'):
                deployment.selected_source_capture_root()

    def test_a_missing_source_capture_directory_is_rejected(self):
        absent = dict(self.environment, WIRESTACK_SOURCE_CAPTURE_ROOT=str(self.root / 'absent'))
        with patch.dict(os.environ, absent, clear=True):
            with self.assertRaisesRegex(ValueError, 'source capture root selection is not a directory'):
                deployment.selected_source_capture_root()

    def test_the_two_tls_libraries_must_be_distinct(self):
        same = dict(self.environment, WIRESTACK_BINARY_OPENSSL_CRYPTO_LIBRARY=str(self.openssl))
        with self.assertRaisesRegex(ValueError, 'independent TLS libraries must be distinct'):
            self.selected_inputs(same)

    def test_declared_consumers_resolve_under_the_selected_capture(self):
        consumers = deployment.selected_consumers(self.binary, self.capture.resolve())
        self.assertEqual([(profile, app) for profile, app, _ in consumers],
            [(profile, app) for profile in binary_verifier.CONSUMER_PROFILES
             for app in binary_verifier.CONSUMER_APPS])
        for _, _, path in consumers:
            self.assertTrue(path.is_file())

    def test_a_missing_installed_consumer_is_rejected(self):
        missing = next(iter(self.consumers.values()))
        (self.capture / missing.replace('<scratch>/', '')).unlink()
        with self.assertRaisesRegex(ValueError, 'installed consumer selection is missing'):
            deployment.selected_consumers(self.binary, self.capture.resolve())

    def test_undeclared_consumer_profiles_are_rejected(self):
        del self.binary['consumers']['candidate-native/trust']
        with self.assertRaisesRegex(ValueError, 'does not declare the installed consumer'):
            deployment.selected_consumers(self.binary, self.capture.resolve())

    def test_call_shape_matches_the_binary_verifier_signature(self):
        """The migrated call binds the exact parameters `verify` declares, in order."""
        parameters = list(inspect.signature(binary_verifier.verify).parameters.values())
        self.assertFalse(any(parameter.kind == parameter.VAR_POSITIONAL for parameter in parameters))
        arguments = deployment.binary_verification_arguments(
            self.binary, self.selected_inputs(), [self.root / 'sdk'])
        self.assertEqual(len(arguments), len(parameters))
        bound = dict(zip((parameter.name for parameter in parameters), arguments))
        self.assertIs(bound['report'], self.binary)
        self.assertEqual(bound['sdks'], [self.root / 'sdk'])
        self.assertEqual(bound['work'], self.capture.resolve())
        self.assertEqual(bound['wrapper'], self.wrapper.resolve())
        self.assertEqual(bound['openssl_library'], self.openssl.resolve())
        self.assertEqual(bound['openssl_crypto_library'], self.crypto.resolve())
        self.assertEqual(len(bound['consumers']),
            len(binary_verifier.CONSUMER_PROFILES) * len(binary_verifier.CONSUMER_APPS))

    def test_verify_is_called_with_the_selected_inputs(self):
        """`current_inputs()` reaches the real verifier with every selected input, not five positionals."""
        repository = self.root / 'repository'
        archive_digest = {'domain': 'artifact-bytes-v1', 'sha256': 'a' * 64}
        profile = {'production_sources': {}, 'native_archives': {},
            'archive_digest': archive_digest, 'payload_sha256': 'b' * 64, 'native_cc_digest': {}}
        runner = repository / 'tools/m12_002_glibc_namespace.py'
        runner.parent.mkdir(parents=True)
        runner.write_text('# fixture namespace runner\n')
        native = {'cpu_model': 'fixture', 'glibc': 'glibc 2.44', 'kernel': '5.15.0-198-generic',
            'installed_payload_verified': 'b' * 64, 'image': {'selected_glibc': {
                'namespace_runner_digest': text_evidence_digest(runner).to_json()}}}
        reports = {name: repository / 'docs/evidence/M12-002/source-sdk' / name / 'report.json'
            for name in ('stable', 'candidate')}
        platform = repository / 'docs/evidence/M12-002/platform/westmere-glibc244/report.json'
        binary_report = repository / 'docs/evidence/M12-002/binary/report.json'
        fixtures = [(path, profile) for path in reports.values()] + [(platform, native), (binary_report, self.binary)]
        for path, value in fixtures:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))
        selected = {name: self.root / (name + '-sdk') for name in reports}
        with patch.dict(os.environ, self.environment), \
                patch.object(deployment, 'ROOT', repository), \
                patch.object(deployment, 'EVIDENCE', repository / 'docs/evidence/M12-002'), \
                patch.object(deployment, 'SOURCE_REPORTS', reports), \
                patch.object(deployment, 'PLATFORM_REPORT', platform), \
                patch.object(deployment, 'selected_sdks', return_value=selected), \
                patch.object(deployment, 'verify_source'), \
                patch.object(deployment, 'require_compiler_binding'), \
                patch.object(deployment, 'require_production_inventory'), \
                patch.object(deployment, 'verify_platform'), \
                patch.object(deployment, 'verify_binary') as verifier:
            deployment.current_inputs(binary_report)
        positional = verifier.call_args.args
        # The call must satisfy the real signature: no missing wrapper/TLS/consumer arguments.
        inspect.signature(binary_verifier.verify).bind(*positional)
        self.assertEqual(positional[0], self.binary)
        self.assertEqual(positional[2], list(selected.values()))
        self.assertEqual(positional[3], repository / 'examples/linux/m12_002/coexist')
        self.assertEqual(positional[4], self.capture.resolve())
        self.assertEqual(positional[5], self.wrapper.resolve())
        self.assertEqual(positional[6], self.openssl.resolve())
        self.assertEqual(positional[7], self.crypto.resolve())
        self.assertEqual(len(positional[8]),
            len(binary_verifier.CONSUMER_PROFILES) * len(binary_verifier.CONSUMER_APPS))

    def test_a_tls_library_outside_the_report_is_rejected(self):
        """The selected OpenSSL inputs must be the bytes the binary report bound."""
        with patch.dict(os.environ, self.environment):
            with self.assertRaisesRegex(ValueError,
                    'selected independent TLS library differs from the binary report'):
                deployment.require_binary_tls_binding(
                    dict(self.binary, external_tls_fixture=dict(
                        self.binary['external_tls_fixture'],
                        library_digest=binary_artifact_digest(self.crypto))),
                    {'openssl_library': self.openssl, 'openssl_crypto_library': self.crypto})


class PublicationOrderingTests(unittest.TestCase):
    """No COMPLETE snapshot may be published unless the entire snapshot validates."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-deployment-publish-')
        self.evidence = Path(self.directory.name)
        self.path = self.evidence / 'verification.json'
        self.source = sorted(json.loads((deployment.ROOT / 'tools/tasks/M12-002.json').read_text())['source_paths'])
        self.task = {'source_paths': self.source}
        self.result = {'schema_version': 1, 'task_id': 'M12-002', 'status': 'COMPLETE',
            'candidate_committed': False, 'archive_digest': {'domain': 'artifact-bytes-v1', 'sha256': 'a' * 64},
            'production_source_count': 164, 'binary_report': 'docs/evidence/M12-002/binary/report.json',
            'source_digests': {name: text_evidence_digest(deployment.ROOT / name).to_json()
                for name in self.source}, 'evidence_digests': {}}
        self.inputs = {'source': {'stable': {'archive_digest': self.result['archive_digest'],
            'production_sources': {str(path.relative_to(deployment.ROOT)): None
                for path in release.production_sources(deployment.ROOT)}}},
            'native': {'cpu_model': 'fixture', 'glibc': 'glibc 2.44',
                'kernel': '5.15.0-198-generic'},
            'binary_report': deployment.ROOT / 'docs/evidence/M12-002/binary/report.json'}

    def tearDown(self):
        self.directory.cleanup()

    def test_a_valid_snapshot_is_accepted_in_memory(self):
        deployment.verify_snapshot(self.result, self.inputs)

    def test_failed_verification_publishes_no_snapshot(self):
        broken = dict(self.result, status='FAIL')
        calls = []
        with patch.object(deployment, 'current_inputs', side_effect=lambda path: calls.append(path) or self.inputs), \
                patch.object(deployment, 'atomic_json',
                    side_effect=lambda path, value: calls.append((path, value))):
            with self.assertRaisesRegex(ValueError, 'uncommitted task acceptance evidence'):
                deployment.verify_snapshot(broken, self.inputs)
        self.assertEqual(calls, [])

    def test_collect_writes_nothing_when_verification_fails(self):
        published = []
        with patch.object(deployment, 'EVIDENCE', self.evidence), \
                patch.object(deployment, 'current_inputs', return_value=self.inputs), \
                patch.object(deployment, 'verify_snapshot',
                    side_effect=ValueError('snapshot is not this uncommitted task acceptance evidence')), \
                patch.object(deployment, 'atomic_json',
                    side_effect=lambda path, value: published.append(value)):
            with self.assertRaisesRegex(ValueError, 'uncommitted task acceptance evidence'):
                deployment.collect(deployment.ROOT / 'docs/evidence/M12-002/binary/report.json')
        self.assertEqual(published, [])
        self.assertFalse(self.path.exists())

    def test_collect_publishes_after_the_snapshot_validates(self):
        order = []
        with patch.object(deployment, 'EVIDENCE', self.evidence), \
                patch.object(deployment, 'current_inputs', return_value=self.inputs), \
                patch.object(deployment, 'verify_snapshot',
                    side_effect=lambda snapshot, inputs=None: order.append('validate') or snapshot), \
                patch.object(deployment, 'atomic_json',
                    side_effect=lambda path, value: order.append('publish')):
            deployment.collect(deployment.ROOT / 'docs/evidence/M12-002/binary/report.json')
        self.assertEqual(order, ['validate', 'publish'])


if __name__ == '__main__':
    unittest.main()

"""Behavioral guardrails for candidate scope, SDK selection and observed identity."""
import copy
import json
from pathlib import Path
import unittest
from unittest import mock
from tools import m12_004_upgrade as upgrade
from tools import m7_021_linux_release as release
from tools import m7_030_linux_release as signing


IDENTITY = {'commit': 'a' * 40, 'tree': 'b' * 40, 'content_sha256': 'c' * 64}


class UpgradeBoundaries(unittest.TestCase):
    def test_candidate_cannot_promote_or_apply_unreviewed_patches(self):
        pin = json.loads(upgrade.PIN.read_text())
        for field, value in [('production_pin_changed', True), ('scope', 'PRODUCTION'),
                             ('qualification', 'QUALIFIED'), ('patches', ['unreviewed.patch'])]:
            with self.subTest(field=field):
                changed = copy.deepcopy(pin)
                changed[field] = value
                with self.assertRaises(signing.ReleaseError) as caught:
                    upgrade.selected_manifest(changed)
                self.assertEqual('CANDIDATE_SCOPE', caught.exception.code)

    def test_unrelated_upstream_and_changed_baseline_require_reselection(self):
        pin = json.loads(upgrade.PIN.read_text())
        changed = copy.deepcopy(pin)
        changed['source']['url'] = 'https://example.test/untrusted.git'
        with self.assertRaises(signing.ReleaseError) as caught:
            upgrade.selected_manifest(changed)
        self.assertEqual('UPSTREAM_SOURCE', caught.exception.code)
        changed = copy.deepcopy(pin)
        changed['baseline']['commit'] = '0' * 40
        with self.assertRaises(signing.ReleaseError) as caught:
            upgrade.selected_manifest(changed)
        self.assertEqual('BASELINE_PIN_CHANGED', caught.exception.code)

    def test_non_sts_sdk_is_rejected_before_reading_or_executing_it(self):
        with mock.patch.object(upgrade, 'sdk_binding') as binding:
            with self.assertRaises(signing.ReleaseError) as caught:
                upgrade.validate_sdk(Path('/nonexistent/main-sdk'))
            self.assertEqual('STS_REQUIRED', caught.exception.code)
            binding.assert_not_called()

    def test_new_candidate_rejects_old_runtime_provider_identity(self):
        observed = ('HTTPS_CLIENT_SERVER=PASS\nHTTP_VERSION=2\ntransportBackend=std-net\n'
                    'runtimeIoBackend=cjnative\ntlsProvider=aws-lc\ntlsProviderVersion=5.5.0\n'
                    'externalOpenSslDependency=false\nbuildFingerprint=abc\n')
        with self.assertRaises(release.ReleaseError):
            release.validate_smoke_output(observed, provider_version='5.11.0')
        release.validate_smoke_output(observed.replace('5.5.0', '5.11.0'), provider_version='5.11.0')


class SourceRevalidationAfterBuild(unittest.TestCase):
    """The checkout that was built must still be the checkout that is reported."""

    def setUp(self):
        self.source = Path('/external/aws-lc')
        self.manifest = {'source': {'commit': IDENTITY['commit'], 'tree': IDENTITY['tree'],
                                    'content_sha256': IDENTITY['content_sha256']}}

    def test_identical_identity_is_accepted(self):
        with mock.patch.object(upgrade.builder, 'verify_source', return_value=dict(IDENTITY)) as verify:
            self.assertEqual(upgrade.require_source_unchanged(self.source, self.manifest, dict(IDENTITY)), IDENTITY)
        verify.assert_called_once_with(self.source, self.manifest)

    def test_checkout_changed_during_the_build_is_rejected(self):
        drift = {**IDENTITY, 'commit': 'd' * 40, 'content_sha256': 'e' * 64}
        with mock.patch.object(upgrade.builder, 'verify_source', return_value=drift):
            with self.assertRaises(signing.ReleaseError) as caught:
                upgrade.require_source_unchanged(self.source, self.manifest, dict(IDENTITY))
        self.assertEqual('SOURCE_CHANGED', caught.exception.code)
        self.assertIn('during the build', caught.exception.detail)

    def test_dirty_or_missing_checkout_failure_is_a_controlled_source_change(self):
        for message in ('AWS-LC source checkout contains tracked or untracked changes',
                        'AWS-LC source is not a Git checkout'):
            with self.subTest(message=message):
                with mock.patch.object(upgrade.builder, 'verify_source',
                                       side_effect=upgrade.builder.BuildError(message)):
                    with self.assertRaises(signing.ReleaseError) as caught:
                        upgrade.require_source_unchanged(self.source, self.manifest, dict(IDENTITY))
                self.assertEqual('SOURCE_CHANGED', caught.exception.code)
                self.assertIn(message, caught.exception.detail)

    def test_build_candidate_revalidates_before_publishing_any_identity(self):
        """The post-build check must gate every identity-bearing output."""
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / 'work'
            output = root / 'output'
            writes = []

            def write_archive(path, payload):
                writes.append(Path(path).name)
                Path(path).write_bytes(b'archive')

            def verify(source, manifest):
                return dict(IDENTITY)

            def revalidate(source, manifest, identity):
                raise signing.ReleaseError('SOURCE_CHANGED', 'AWS-LC source checkout changed during the build')

            args = type('Args', (), {'work_root': work, 'output': output,
                                     'sdk_root': Path('/sdk/sts1.1.3'),
                                     'source_dir': Path('/external/aws-lc')})()
            with mock.patch.object(upgrade.Capture, 'run', return_value=''), \
                 mock.patch.object(upgrade, 'validate_sdk', return_value={}), \
                 mock.patch.object(upgrade, 'selected_manifest', return_value={}), \
                 mock.patch.object(upgrade.release, 'collect_payload',
                                   return_value=({}, {'payload_sha256': 'a' * 64, 'provider': {}})), \
                 mock.patch.object(upgrade.release, 'write_reproducible_archive', side_effect=write_archive), \
                 mock.patch.object(upgrade.release, 'extract_archive', return_value=root / 'package'), \
                 mock.patch.object(upgrade.builder, 'resolve_tool', return_value='/usr/bin/true'), \
                 mock.patch.object(upgrade.builder, 'tool_version', return_value='version'), \
                 mock.patch.object(upgrade.builder, 'verify_source', side_effect=verify), \
                 mock.patch.object(upgrade.builder, 'build_provider',
                                   return_value=(root / 'native', {'build_fingerprint': 'b' * 64})), \
                 mock.patch.object(upgrade.builder, 'platform_identity', return_value={}), \
                 mock.patch.object(upgrade, 'require_source_unchanged', side_effect=revalidate):
                (root / 'native').mkdir()
                with self.assertRaises(signing.ReleaseError) as caught:
                    upgrade.build_candidate(args, {})
        self.assertEqual('SOURCE_CHANGED', caught.exception.code)
        # Only the pre-build baseline archive was written; no candidate identity
        # was published and no consumer or supply-chain document was produced.
        self.assertEqual(writes, ['before.tar.gz'])


if __name__ == '__main__':
    unittest.main()

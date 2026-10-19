"""Behavioral guardrails for candidate scope, SDK selection and observed identity."""
import copy
import json
from pathlib import Path
import unittest
from unittest import mock
from tools import m12_004_upgrade as upgrade
from tools import m7_021_linux_release as release
from tools import m7_030_linux_release as signing


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


if __name__ == '__main__':
    unittest.main()

"""The deployment collector binds retained profiles to current inputs, never to their own keys."""
import shutil
from pathlib import Path
import unittest
from tools import m12_002_deployment as deployment
from tools import m12_002_source_sdk as source_sdk
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest


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


if __name__ == '__main__':
    unittest.main()

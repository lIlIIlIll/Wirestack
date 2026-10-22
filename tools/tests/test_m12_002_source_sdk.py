"""Public verifier behavior using captured native evidence, without fake compilers."""
import copy
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

from tools.m12_002_source_sdk import (CA_CHECKS, CA_DIAGNOSTICS, COMMAND_CONTRACTS,
    EXPECTED_COMMANDS, HELPER_SOURCES, HOST_CA_MOUNT, PORT, ROOT, TLS_FIXTURE_FILES, consumer_source_digests, helper_sources,
    native_compiler, validate_resume, verify_ca_checks, verify_command_inventory,
    verify_consumer_sources, verify_helper_sources, verify_report, verify_retained_binary,
    verify_retained_commands, verify_tls_fixtures)
from tools.evidence_digest import (artifact_byte_digest, artifact_byte_digest_bytes,
    text_evidence_digest)


def text_digest(seed):
    return {'domain': 'text-utf8-lf-v1', 'sha256': seed * 64}


def artifact_digest(seed):
    return {'domain': 'artifact-bytes-v1', 'sha256': seed * 64}


def fixture_digests():
    return {name: artifact_digest(format(index, 'x')) for index, name in enumerate(TLS_FIXTURE_FILES)}


class ResumeDriftTests(unittest.TestCase):
    def report(self):
        return {'runner_digest': text_digest('a'),
                'native_cc_digest': artifact_digest('d'),
                'helper_sources': {name: text_digest('e') for name in HELPER_SOURCES},
                'tls_fixtures': fixture_digests(),
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

    def test_changed_helper_closure_is_rejected(self):
        previous = self.report()
        current = self.report()
        current['helper_sources']['tools/evidence_digest.py'] = text_digest('c')
        with self.assertRaisesRegex(ValueError, 'changed evidence helper closure'):
            validate_resume(previous, current)

    def test_unbound_helper_closure_cannot_resume(self):
        previous = self.report()
        del previous['helper_sources']
        with self.assertRaisesRegex(ValueError, 'changed evidence helper closure'):
            validate_resume(previous, self.report())

    def test_changed_tls_fixture_is_rejected(self):
        previous = self.report()
        current = self.report()
        current['tls_fixtures']['certificate.der'] = artifact_digest('8')
        with self.assertRaisesRegex(ValueError, 'changed retained TLS fixture material'):
            validate_resume(previous, current)

    def test_unbound_tls_fixture_cannot_resume(self):
        previous = self.report()
        del previous['tls_fixtures']
        with self.assertRaisesRegex(ValueError, 'changed retained TLS fixture material'):
            validate_resume(previous, self.report())

    def test_added_consumer_source_is_rejected(self):
        previous = self.report()
        current = self.report()
        current['consumer_sources']['examples/linux/m11_004/decoded/src/main.cj'] = text_digest('c')
        with self.assertRaisesRegex(ValueError, 'consumer sources'):
            validate_resume(previous, current)


class TlsFixtureBindingTests(unittest.TestCase):
    def test_complete_fixture_inventory_is_accepted(self):
        verify_tls_fixtures({'tls_fixtures': fixture_digests()})

    def test_missing_fixture_is_rejected(self):
        recorded = fixture_digests()
        del recorded['key.der']
        with self.assertRaisesRegex(ValueError, 'TLS fixture inventory is incomplete'):
            verify_tls_fixtures({'tls_fixtures': recorded})

    def test_unbound_fixture_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'TLS fixture inventory is incomplete'):
            verify_tls_fixtures({})

    def test_one_file_cannot_stand_in_for_every_fixture(self):
        recorded = fixture_digests()
        recorded['untrusted.der'] = recorded['certificate.der']
        with self.assertRaisesRegex(ValueError, 'TLS fixtures are not distinct'):
            verify_tls_fixtures({'tls_fixtures': recorded})

    def test_fixture_must_carry_a_byte_digest(self):
        recorded = fixture_digests()
        recorded['certificate.pem'] = text_digest('c')
        with self.assertRaisesRegex(ValueError, 'not byte-bound: certificate.pem'):
            verify_tls_fixtures({'tls_fixtures': recorded})

    def test_malformed_byte_digest_is_rejected(self):
        malformed = (
            {'domain': 'artifact-bytes-v1', 'sha256': 'a' * 63},
            {'domain': 'artifact-bytes-v1', 'sha256': 'g' * 64},
            {'domain': 'artifact-bytes-v1', 'sha256': 'A' * 64},
            {'domain': 'artifact-bytes-v1'},
        )
        for digest in malformed:
            with self.subTest(digest=digest):
                recorded = fixture_digests()
                recorded['certificate.pem'] = digest
                with self.assertRaisesRegex(ValueError, 'not byte-bound: certificate.pem'):
                    verify_tls_fixtures({'tls_fixtures': recorded})


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


def contract_argv(name):
    """The declared invocation for one command, with its ephemeral port resolved."""
    cwd, argv = COMMAND_CONTRACTS[name][0]
    return cwd, [value.replace(PORT, '44595') for value in argv]


class CommandInventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-source-commands-')
        self.evidence = Path(self.directory.name)
        self.commands = []
        for name, expected in EXPECTED_COMMANDS.items():
            cwd, argv = contract_argv(name)
            logs = {stream: self.evidence / f'{name}.{stream}.log' for stream in ('stdout', 'stderr')}
            logs['stdout'].write_text(CA_DIAGNOSTICS.get(name, name) + '\n')
            logs['stderr'].write_text('')
            self.commands.append({'id': name, 'argv': argv, 'cwd': cwd, 'exit_code': expected,
                'expected_exit_code': expected, 'timed_out': False,
                **{stream: {'path': log.name, 'digest': text_evidence_digest(log).to_json()}
                   for stream, log in logs.items()}})
        self.report = {'commands': self.commands,
            'ca_checks': {name: {'status': 'PASS', 'expected_exit': EXPECTED_COMMANDS[name],
                'diagnostic': CA_DIAGNOSTICS[name]} for name in CA_CHECKS}}

    def tearDown(self):
        self.directory.cleanup()

    def changed(self):
        return copy.deepcopy(self.commands)

    def test_complete_inventory_is_accepted(self):
        verify_command_inventory(self.commands, self.evidence)
        verify_retained_commands(self.commands, self.evidence)
        verify_ca_checks(self.report, self.evidence)

    def test_omitted_command_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'command inventory is incomplete'):
            verify_command_inventory(self.commands[1:], self.evidence)

    def test_duplicated_command_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'command inventory contains duplicates'):
            verify_command_inventory(self.commands + [self.commands[0]], self.evidence)

    def test_reclassified_ca_expectation_is_rejected(self):
        changed = self.changed()
        next(c for c in changed if c['id'] == 'missing-explicit-ca')['expected_exit_code'] = 0
        with self.assertRaisesRegex(ValueError, 'command expectation reclassified: missing-explicit-ca'):
            verify_command_inventory(changed, self.evidence)

    def test_ca_check_without_its_native_failure_is_rejected(self):
        changed = self.changed()
        next(c for c in changed if c['id'] == 'system-ca-missing')['exit_code'] = 0
        with self.assertRaisesRegex(ValueError, 'command did not satisfy its native outcome: system-ca-missing'):
            verify_command_inventory(changed, self.evidence)

    def test_timed_out_command_is_rejected(self):
        changed = self.changed()
        changed[0]['timed_out'] = True
        with self.assertRaisesRegex(ValueError, 'command timed out: cjc'):
            verify_command_inventory(changed, self.evidence)

    def test_changed_retained_log_is_rejected(self):
        (self.evidence / 'cjc.stdout.log').write_text('changed\n')
        with self.assertRaisesRegex(ValueError, 'command evidence changed: cjc'):
            verify_command_inventory(self.commands, self.evidence)
        with self.assertRaisesRegex(ValueError, 'retained command log changed: cjc'):
            verify_retained_commands(self.commands, self.evidence)


class CommandContractTests(CommandInventoryTests):
    """A verdict is bound to the invocation it claims, not merely to a command identifier."""

    def test_every_declared_command_has_a_contract(self):
        self.assertEqual(set(COMMAND_CONTRACTS), set(EXPECTED_COMMANDS))

    def test_relocated_consumer_must_not_run_from_the_hidden_tree(self):
        changed = self.changed()
        command = next(c for c in changed if c['id'] == 'cli-acceptance')
        command['cwd'] = '<scratch>/original/consumers/cli'
        with self.assertRaisesRegex(ValueError, 'command shape changed: cli-acceptance'):
            verify_command_inventory(changed, self.evidence)

    def test_negated_trust_scenario_must_pass_its_own_ca_file(self):
        changed = self.changed()
        command = next(c for c in changed if c['id'] == 'incorrect-explicit-ca')
        command['argv'][-1] = '<scratch>/certificate.der'
        with self.assertRaisesRegex(ValueError, 'command shape changed: incorrect-explicit-ca'):
            verify_command_inventory(changed, self.evidence)

    def test_system_ca_scenario_must_mount_its_own_store(self):
        changed = self.changed()
        argv = next(c for c in changed if c['id'] == 'system-ca-missing')['argv']
        start = argv.index('--tmpfs', argv.index('/etc/ssl') - 1)
        argv[start:start + 4] = ['--tmpfs', '/etc/ssl', '--ro-bind', '<scratch>/certificate.pem',
            '/etc/ssl/certs/ca-certificates.crt', '--dir', '/etc/ssl/certs']
        with self.assertRaisesRegex(ValueError, 'command shape changed: system-ca-missing'):
            verify_command_inventory(changed, self.evidence)

    def test_optional_host_ca_mount_is_accepted_for_all_system_scenarios(self):
        for name in ('system-ca-installed', 'system-ca-missing', 'system-ca-incorrect'):
            with self.subTest(name=name):
                changed = self.changed()
                argv = next(c for c in changed if c['id'] == name)['argv']
                insertion = argv.index('--chdir')
                argv[insertion:insertion] = HOST_CA_MOUNT
                verify_command_inventory(changed, self.evidence)

    def test_unrelated_mount_is_rejected_with_optional_host_ca_mount(self):
        changed = self.changed()
        argv = next(c for c in changed if c['id'] == 'system-ca-missing')['argv']
        insertion = argv.index('--chdir')
        argv[insertion:insertion] = [*HOST_CA_MOUNT, '--tmpfs', '/etc/other']
        with self.assertRaisesRegex(ValueError, 'command shape changed: system-ca-missing'):
            verify_command_inventory(changed, self.evidence)

    def test_hidden_probe_must_hide_the_checkout(self):
        changed = self.changed()
        next(c for c in changed if c['id'] == 'checkout-hidden')['argv'].remove('--tmpfs')
        with self.assertRaisesRegex(ValueError, 'command shape changed: checkout-hidden'):
            verify_command_inventory(changed, self.evidence)

    def test_missing_invocation_is_rejected(self):
        changed = self.changed()
        del next(c for c in changed if c['id'] == 'cli-help')['argv']
        with self.assertRaisesRegex(ValueError, 'command shape changed: cli-help'):
            verify_command_inventory(changed, self.evidence)

    def test_evidence_path_outside_the_tree_is_rejected(self):
        changed = self.changed()
        next(c for c in changed if c['id'] == 'cjc')['stdout']['path'] = '../../etc/passwd'
        with self.assertRaisesRegex(ValueError, 'command evidence path escapes its evidence tree: cjc'):
            verify_command_inventory(changed, self.evidence)

    def test_absolute_evidence_path_is_rejected(self):
        changed = self.changed()
        next(c for c in changed if c['id'] == 'cjc')['stdout']['path'] = '/etc/hostname'
        with self.assertRaisesRegex(ValueError, 'command evidence path escapes its evidence tree: cjc'):
            verify_command_inventory(changed, self.evidence)

    def test_symlinked_evidence_path_cannot_escape_tree(self):
        outside = self.evidence.parent / (self.evidence.name + '-outside.log')
        self.addCleanup(outside.unlink, missing_ok=True)
        outside.write_text('cjc\n')
        link = self.evidence / 'outside.log'
        link.symlink_to(outside)
        changed = self.changed()
        command = next(c for c in changed if c['id'] == 'cjc')
        command['stdout'] = {'path': link.name, 'digest': text_evidence_digest(outside).to_json()}
        with self.assertRaisesRegex(ValueError, 'command evidence path escapes its evidence tree: cjc'):
            verify_command_inventory(changed, self.evidence)
        with self.assertRaisesRegex(ValueError, 'retained command log changed: cjc'):
            verify_retained_commands(changed, self.evidence)


class CaDiagnosticTests(CommandInventoryTests):
    """A negative CA scenario is only evidence while its own output still proves the refusal."""

    def rewrite(self, name, text):
        log = self.evidence / f'{name}.stdout.log'
        log.write_text(text)
        entry = next(c for c in self.commands if c['id'] == name)['stdout']
        entry['digest'] = text_evidence_digest(log).to_json()

    def test_wrong_negative_diagnostic_is_rejected(self):
        for name, diagnostic in (('missing-explicit-ca', 'ERROR trust_unavailable'),
                                 ('incorrect-explicit-ca', 'ERROR ca_file_missing'),
                                 ('system-ca-missing', 'ERROR ca_file_missing')):
            with self.subTest(name=name):
                original = (self.evidence / f'{name}.stdout.log').read_text()
                self.rewrite(name, diagnostic + '\n')
                with self.assertRaisesRegex(ValueError, 'CA scenario output does not match its diagnostic: ' + name):
                    verify_ca_checks(self.report, self.evidence)
                self.rewrite(name, original)

    def test_success_scenario_that_merely_exits_zero_is_rejected(self):
        self.rewrite('system-ca-installed', 'ERROR certificate_untrusted phase=tls_handshake\n')
        with self.assertRaisesRegex(ValueError, 'CA scenario output does not match its diagnostic: system-ca-installed'):
            verify_ca_checks(self.report, self.evidence)

    def test_diagnostic_on_stderr_is_rejected(self):
        entry = next(c for c in self.commands if c['id'] == 'explicit-ca')['stderr']
        log = self.evidence / entry['path']
        log.write_text('ERROR ca_file_missing\n')
        entry['digest'] = text_evidence_digest(log).to_json()
        with self.assertRaisesRegex(ValueError, 'CA scenario reported diagnostics on stderr: explicit-ca'):
            verify_ca_checks(self.report, self.evidence)

    def test_reclassified_ca_claim_is_rejected(self):
        report = copy.deepcopy(self.report)
        report['ca_checks']['system-ca-missing']['diagnostic'] = 'ERROR ca_file_missing'
        with self.assertRaisesRegex(ValueError, 'CA scenario diagnostic changed: system-ca-missing'):
            verify_ca_checks(report, self.evidence)
        report = copy.deepcopy(self.report)
        report['ca_checks']['system-ca-missing']['expected_exit'] = 0
        with self.assertRaisesRegex(ValueError, 'CA scenario expectation changed: system-ca-missing'):
            verify_ca_checks(report, self.evidence)

    def test_incomplete_or_failed_ca_inventory_is_rejected(self):
        report = copy.deepcopy(self.report)
        del report['ca_checks']['missing-explicit-ca']
        with self.assertRaisesRegex(ValueError, 'CA evidence inventory is incomplete'):
            verify_ca_checks(report, self.evidence)
        report = copy.deepcopy(self.report)
        report['ca_checks']['explicit-ca']['status'] = 'FAIL'
        with self.assertRaisesRegex(ValueError, 'CA scenario is not recorded as passed: explicit-ca'):
            verify_ca_checks(report, self.evidence)


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
        cls.report = json.loads(cls.path.read_text())
        # The binding under test is the SDK one, so supply any real file whose digest the report
        # carries; the captured archive itself is not retained in a source checkout.
        cls.directory = tempfile.TemporaryDirectory(prefix='m12-source-archive-')
        cls.addClassCleanup(cls.directory.cleanup)
        cls.archive = Path(cls.directory.name) / 'wirestack-baseline.tar.gz'
        cls.archive.write_bytes(b'synthetic archive standing in for the accepted release')
        cls.archive_digest = artifact_byte_digest(cls.archive).to_json()

    def candidate(self):
        changed = copy.deepcopy(self.report)
        changed['archive_digest'] = self.archive_digest
        return changed

    def test_changed_archive_cannot_reuse_report(self):
        changed = self.candidate()
        changed['archive_digest'] = artifact_byte_digest_bytes(b'different artifact').to_json()
        with self.assertRaisesRegex(ValueError, 'archive binding changed'):
            verify_report(changed, self.archive, self.sdk, self.path.parent)

    def test_new_compiler_cannot_reuse_report(self):
        changed = self.candidate()
        changed['sdk_files']['bin/cjc'] = artifact_byte_digest_bytes(b'different compiler').to_json()
        with self.assertRaisesRegex(ValueError, 'SDK compiler/runtime/import binding changed'):
            verify_report(changed, self.archive, self.sdk, self.path.parent)

    def test_new_runtime_cannot_reuse_report(self):
        changed = self.candidate()
        runtime = next(k for k in changed['sdk_files'] if k.endswith('libcangjie-runtime.so'))
        changed['sdk_files'][runtime] = artifact_byte_digest_bytes(b'different runtime').to_json()
        with self.assertRaisesRegex(ValueError, 'SDK compiler/runtime/import binding changed'):
            verify_report(changed, self.archive, self.sdk, self.path.parent)

    def test_build_success_is_not_binary_cross_sdk_support(self):
        changed = self.candidate()
        changed['binary_cross_sdk'] = 'PASS'
        with self.assertRaisesRegex(ValueError, 'source-only compatibility proof'):
            verify_report(changed, self.archive, self.sdk, self.path.parent)


if __name__ == '__main__':
    unittest.main()

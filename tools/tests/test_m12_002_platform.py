"""Reject misleading deployment claims against real native VM consumer evidence."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from tools.m12_002_platform import (COMMAND_IDS, ROOT, SOURCE_LAYOUTS, SUPPORT_FILES,
    evidence_log, observed_platform, transferred_path, validate_transferred_sources, verify_command_contract,
    verify_commands, verify_report)
from tools.evidence_digest import artifact_byte_digest_bytes, text_evidence_digest


class NativePlatformEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = ROOT / 'docs/evidence/M12-002/platform/westmere-glibc244'
        cls.stable = json.loads((ROOT / 'docs/evidence/M12-002/source-sdk/stable-native/report.json').read_text())
        cls.report = cls.conformant(json.loads((cls.evidence / 'report.json').read_text()))

    @classmethod
    def conformant(cls, report):
        """Re-derive every claim from the retained logs so each negative case is isolated."""
        report.update(observed_platform(report, cls.evidence))
        report['support_sources'] = {name: text_evidence_digest(ROOT / name).to_json()
            for name in SUPPORT_FILES}
        report['transferred_sources'] = dict(cls.stable['consumer_sources'])
        return report

    def reject(self, field, value, reason):
        changed = copy.deepcopy(self.report)
        changed[field] = value
        with self.assertRaisesRegex(ValueError, reason):
            verify_report(changed, self.evidence, self.stable)

    def test_claims_rederived_from_the_captured_logs_are_accepted(self):
        verify_report(copy.deepcopy(self.report), self.evidence, self.stable)

    def test_container_cannot_claim_native_kernel_boundary(self):
        self.reject('virtualization', 'docker', 'claim differs from its captured output: virtualization')

    def test_shared_kernel_cannot_claim_old_kernel(self):
        self.reject('kernel', self.report['host_kernel'], 'claim differs from its captured output: kernel')

    def test_unqualified_host_cannot_stand_in_for_the_measured_host(self):
        changed = copy.deepcopy(self.report)
        changed['host_kernel'] = '6.8.0-31-generic'
        with self.assertRaisesRegex(ValueError, 'host identity is not the kernel observed by the source qualification'):
            verify_report(changed, self.evidence, self.stable)

    def test_avx_enabled_vm_cannot_claim_weaker_cpu(self):
        self.reject('cpu_flags', self.report['cpu_flags'] + ['avx'], 'claim differs from its captured output: cpu_flags')

    def test_partial_native_scenarios_cannot_claim_supported_profile(self):
        self.reject('same_binary_check_count', 46, 'native scenarios missing')

    def test_omitted_native_command_is_rejected(self):
        changed = copy.deepcopy(self.report)
        changed['commands'] = [command for command in changed['commands'] if command['id'] != 'rebuilt-cli']
        with self.assertRaisesRegex(ValueError, 'native command inventory is incomplete'):
            verify_commands(changed, self.evidence)

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

    def test_missing_transferred_consumer_source_is_rejected(self):
        changed = copy.deepcopy(self.report)
        del changed['transferred_sources'][next(iter(changed['transferred_sources']))]
        with self.assertRaisesRegex(ValueError, 'transferred consumer source inventory is incomplete'):
            verify_report(changed, self.evidence, self.stable)

    def test_changed_transferred_consumer_source_is_rejected(self):
        changed = copy.deepcopy(self.report)
        key = next(iter(changed['transferred_sources']))
        changed['transferred_sources'][key] = text_evidence_digest(Path('tools/m12_002_platform.py')).to_json()
        with self.assertRaisesRegex(ValueError, 'transferred consumer source differs from source qualification'):
            verify_report(changed, self.evidence, self.stable)

    def test_duplicated_native_command_is_rejected(self):
        changed = copy.deepcopy(self.report)
        changed['commands'].append(copy.deepcopy(changed['commands'][0]))
        with self.assertRaisesRegex(ValueError, 'native command inventory contains duplicates'):
            verify_commands(changed, self.evidence)

    def test_missing_rebuild_stage_is_rejected(self):
        changed = copy.deepcopy(self.report)
        changed['commands'] = [command for command in changed['commands']
            if command['id'] != 'clean-service']
        with self.assertRaisesRegex(ValueError, 'native command inventory is incomplete'):
            verify_commands(changed, self.evidence)

    def test_failed_native_command_is_rejected(self):
        changed = copy.deepcopy(self.report)
        next(command for command in changed['commands'] if command['id'] == 'build-cli')['exit_code'] = 1
        with self.assertRaisesRegex(ValueError, 'native command failed: build-cli'):
            verify_commands(changed, self.evidence)

    def test_command_inventory_covers_every_declared_stage(self):
        # 9 environment probes + 4 rebuilt apps x (same-binary, clean, build, rebuilt).
        self.assertEqual(len(COMMAND_IDS), 25)
        probes = {'kernel', 'glibc', 'virtualization', 'cpu', 'os-release', 'compiler', 'cjpm',
                  'native-cc', 'native-ld'}
        self.assertEqual(COMMAND_IDS - probes,
            {f'{stage}-{app}' for stage in ('same-binary', 'clean', 'build', 'rebuilt')
             for app in ('cli', 'decoded', 'streams', 'service')})

    def test_missing_support_source_is_rejected(self):
        changed = copy.deepcopy(self.report)
        del changed['support_sources']['tools/evidence_digest.py']
        with self.assertRaisesRegex(ValueError, 'platform support source inventory is incomplete'):
            verify_report(changed, self.evidence, self.stable)


class TransferredSourceTests(unittest.TestCase):
    def test_consumer_sources_map_onto_the_vm_layout(self):
        for prefix, layout in SOURCE_LAYOUTS:
            self.assertEqual(transferred_path(prefix + 'src/main.cj'), layout + 'src/main.cj')

    def test_unknown_consumer_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unknown consumer source: src/http/client.cj'):
            transferred_path('src/http/client.cj')

    def test_transferred_tree_must_retain_the_qualified_bytes(self):
        with tempfile.TemporaryDirectory(prefix='m12-transfer-') as directory:
            tree = Path(directory)
            source = tree / 'consumers/src/main.cj'
            source.parent.mkdir(parents=True)
            source.write_text('main() {}\n')
            stable = {'consumer_sources': {'examples/linux/m11_004/src/main.cj': text_evidence_digest(source).to_json()}}
            self.assertEqual(validate_transferred_sources(tree, stable),
                             {'examples/linux/m11_004/src/main.cj': text_evidence_digest(source).to_json()})
            source.write_text('main() { changed }\n')
            with self.assertRaisesRegex(ValueError, 'transferred consumer source changed'):
                validate_transferred_sources(tree, stable)
            source.unlink()
            with self.assertRaisesRegex(ValueError, 'transferred consumer source is missing'):
                validate_transferred_sources(tree, stable)


class ObservedPlatformTests(unittest.TestCase):
    def test_malformed_cpu_inventory_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='m12-platform-') as directory:
            evidence = Path(directory)
            report = {'commands': []}
            for name, body in (('kernel', '5.15.0-198-generic\n'), ('glibc', 'glibc 2.44\n'),
                               ('virtualization', 'kvm\n'), ('cpu', '{}\n')):
                (evidence / (name + '.stdout.log')).write_text(body)
                report['commands'].append({'id': name, 'stdout': {'path': name + '.stdout.log'}})
            with self.assertRaisesRegex(ValueError, 'CPU inventory is not a populated lscpu object'):
                observed_platform(report, evidence)
            (evidence / 'cpu.stdout.log').write_text(json.dumps({'lscpu': [{'field': 'Model name'}]}))
            with self.assertRaisesRegex(ValueError, 'malformed item'):
                observed_platform(report, evidence)
            (evidence / 'cpu.stdout.log').write_text(json.dumps(
                {'lscpu': [{'field': 'Model name', 'data': 'Westmere'}]}))
            with self.assertRaisesRegex(ValueError, 'lacks a model or flags'):
                observed_platform(report, evidence)

    def test_log_must_belong_to_the_command_that_claims_it(self):
        with tempfile.TemporaryDirectory(prefix='m12-platform-') as directory:
            evidence = Path(directory)
            (evidence / 'kernel.stdout.log').write_text('5.15.0-198-generic\n')
            with self.assertRaisesRegex(ValueError, 'evidence is not its own retained log: glibc'):
                evidence_log({'id': 'glibc', 'stdout': {'path': 'kernel.stdout.log'}}, evidence, 'stdout')

    def test_log_path_may_not_escape_the_evidence_tree(self):
        with tempfile.TemporaryDirectory(prefix='m12-platform-') as directory:
            evidence = Path(directory)
            with self.assertRaisesRegex(ValueError, 'evidence path escapes its evidence tree: kernel'):
                evidence_log({'id': 'kernel', 'stdout': {'path': '../../../etc/passwd'}}, evidence, 'stdout')


class CommandContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        evidence = ROOT / 'docs/evidence/M12-002/platform/westmere-glibc244'
        cls.commands = {command['id']: command
            for command in json.loads((evidence / 'report.json').read_text())['commands']}

    def verify(self, name, **changes):
        command = copy.deepcopy(self.commands[name])
        command.update(changes)
        verify_command_contract(command)

    def test_every_real_native_command_matches_its_contract(self):
        for name, command in self.commands.items():
            with self.subTest(name=name):
                verify_command_contract(command)

    def test_vm_binary_cannot_be_replaced_by_a_host_binary(self):
        name = 'same-binary-cli'
        argv = list(self.commands[name]['argv'])
        argv[0] = '/usr/bin/main'
        with self.assertRaisesRegex(ValueError, 'command shape changed: ' + name):
            self.verify(name, argv=argv)

    def test_clean_cannot_be_relabelled_as_a_build(self):
        with self.assertRaisesRegex(ValueError, 'command shape changed: clean-cli'):
            self.verify('clean-cli', argv=['<sdk>/tools/bin/cjpm', 'build'])

    def test_rebuilt_tree_must_live_under_the_rebuild_root(self):
        with self.assertRaisesRegex(ValueError, 'working directory changed: rebuilt-cli'):
            self.verify('rebuilt-cli', cwd='<installed-tree>/consumers/cli/target/release/bin')

    def test_kernel_probe_must_run_the_recorded_command(self):
        with self.assertRaisesRegex(ValueError, 'command shape changed: kernel'):
            self.verify('kernel', argv=['cat', '/proc/version'])

    def test_self_check_must_pass_the_declared_fixtures(self):
        name = 'same-binary-streams'
        argv = list(self.commands[name]['argv'])
        argv[3] = '<support>/fixtures/other.der'
        with self.assertRaisesRegex(ValueError, 'command shape changed: ' + name):
            self.verify(name, argv=argv)

    def test_cli_port_must_be_a_real_port_but_may_differ(self):
        name = 'same-binary-cli'
        argv = list(self.commands[name]['argv'])
        verify_command_contract({**self.commands[name], 'argv': argv[:-1] + ['51234']})
        argv[-1] = 'port'
        with self.assertRaisesRegex(ValueError, 'command shape changed: ' + name):
            self.verify(name, argv=argv)


if __name__ == '__main__':
    unittest.main()
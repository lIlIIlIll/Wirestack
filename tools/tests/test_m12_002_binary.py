"""Behavioral ELF checks use real linked objects, not fabricated readelf output."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest
from tools.m12_002_binary import (CONSUMER_APPS, CONSUMER_PROFILES, OPTIONAL_MODULES,
    SCAN_SUFFIXES, TRUNCATED_ISA, Capture, bind_installed_payload, bound_command, consumer_identity,
    dynamic_fields, expected_scan_inputs, gating_command_ids, install_selected_archive, isa_presence,
    scan_fields, scanner_digest, validate_abi_matrix, verify_abi_matrix, verify_command_inventory,
    verify_consumers, verify_scan_inputs, verify_scan_verdicts, versions, CHECKS, TRUNCATED)


@unittest.skipUnless(shutil.which('gcc') and shutil.which('readelf'), 'native ELF tools required')
class BinaryBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-binary-tests-')
        self.work = Path(self.directory.name)
        self.env = dict(os.environ, TMPDIR=str(self.work), TMP=str(self.work), TEMP=str(self.work))

    def tearDown(self):
        self.directory.cleanup()

    def build(self, source, flags=()):
        path = self.work / 'probe.c'
        path.write_text(source)
        binary = self.work / 'probe'
        subprocess.run(['gcc', '-march=x86-64', str(path), '-o', str(binary), *flags],
                       env=self.env, check=True, capture_output=True)
        return binary

    def dynamic(self, binary):
        text = subprocess.check_output(['readelf', '-dW', str(binary)], env=self.env, text=True)
        return dynamic_fields(text)

    def test_real_libc_needed_and_version_requirement(self):
        binary = self.build('#include <stdio.h>\nint main(void) { return puts("native") < 0; }\n')
        result = subprocess.run([str(binary)], env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, 'native\n')
        fields = self.dynamic(binary)
        self.assertIn('libc.so.6', fields['needed'])
        self.assertFalse(fields['implicit_system_tls'])
        version_text = subprocess.check_output(['readelf', '-VW', str(binary)], env=self.env, text=True)
        self.assertTrue(any(v.startswith('GLIBC_') for v in versions(version_text)))

    def test_absolute_runpath_rejected_and_origin_not_absolute(self):
        binary = self.build('int main(void) { return 0; }\n', ['-Wl,-rpath,/opt/example/lib:$ORIGIN/lib'])
        fields = self.dynamic(binary)
        self.assertEqual(fields['absolute_path_hazards'], ['/opt/example/lib'])
        self.assertIn('$ORIGIN/lib', fields['runpath'][0])

    def test_actual_shared_library_soname_is_recorded(self):
        binary = self.build('int fixture(void) { return 42; }\n', ['-shared', '-fPIC', '-Wl,-soname,libexample.so.1'])
        self.assertEqual(self.dynamic(binary)['soname'], ['libexample.so.1'])

    def test_explicit_tls_link_is_detected(self):
        if not Path('/usr/include/openssl/ssl.h').exists():
            self.skipTest('OpenSSL fixture development headers unavailable')
        binary = self.build('#include <openssl/ssl.h>\nint main(void) { return TLS_client_method() == 0; }\n', ['-lssl'])
        self.assertTrue(self.dynamic(binary)['implicit_system_tls'])

    def test_absolute_soname_dependency_is_a_hazard(self):
        library = self.work / 'libfixture.so'
        source = self.work / 'library.c'
        source.write_text('int fixture(void) { return 42; }\n')
        subprocess.run(['gcc', '-shared', '-fPIC', str(source), '-Wl,-soname,/opt/example/libfixture.so',
                        '-o', str(library)], env=self.env, check=True, capture_output=True)
        binary = self.build('extern int fixture(void); int main(void) { return fixture() != 42; }\n', [str(library)])
        self.assertIn('/opt/example/libfixture.so', self.dynamic(binary)['absolute_path_hazards'])

    def test_independent_tls_never_guesses_a_library(self):
        if not Path('/usr/include/openssl/ssl.h').exists():
            self.skipTest('OpenSSL fixture development headers unavailable')
        fixture = Path(__file__).resolve().parents[2] / 'examples/linux/m12_002/coexist/native/independent_tls.c'
        binary = self.build('#include <stdlib.h>\nextern int fixture_independent_tls(unsigned short);\nint main(void) { unsetenv("WIRESTACK_FIXTURE_OPENSSL_LIBRARY"); unsetenv("WIRESTACK_FIXTURE_CA_FILE"); return fixture_independent_tls(0) == 10 ? 0 : 1; }\n', [str(fixture), '-ldl', '-lssl', '-lcrypto'])
        subprocess.run([str(binary)], env=self.env, check=True, capture_output=True)


class AbiMatrixQualificationTests(unittest.TestCase):
    @staticmethod
    def matrix(built_sdk=0, runtime_sdk=1):
        return [{'built_sdk': i, 'runtime_sdk': j,
                 'abi_result': 'FAIL_RUNTIME_EXECUTION_REQUIRES_DIAGNOSIS' if (i, j) == (built_sdk, runtime_sdk) else 'PASS',
                 'semantic_result': 'NOT_EXECUTED_TO_COMPLETION' if (i, j) == (built_sdk, runtime_sdk) else 'PASS'}
                for i in range(2) for j in range(2)]

    def test_complete_passing_matrix_is_accepted(self):
        validate_abi_matrix(self.matrix(built_sdk=-1, runtime_sdk=-1), 2)

    def test_failed_cross_runtime_cell_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'cross-SDK native behavior failed: built_sdk=0 runtime_sdk=1'):
            validate_abi_matrix(self.matrix(built_sdk=0, runtime_sdk=1), 2)

    def test_incomplete_matrix_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'ABI matrix is incomplete'):
            validate_abi_matrix(self.matrix()[:3], 2)


class AbiMatrixCoordinateTests(unittest.TestCase):
    @staticmethod
    def row(built, runtime, abi='PASS', semantic='PASS'):
        return {'built_sdk': built, 'runtime_sdk': runtime, 'abi_result': abi,
                'semantic_result': semantic}

    def test_repeated_coordinate_cannot_replace_a_missing_cell(self):
        rows = [self.row(0, 0), self.row(0, 0), self.row(1, 0), self.row(1, 1)]
        with self.assertRaisesRegex(ValueError, 'does not cover each built/runtime coordinate exactly once'):
            validate_abi_matrix(rows, 2)

    def test_non_contiguous_matrix_is_rejected(self):
        rows = [self.row(0, 1), self.row(0, 2), self.row(1, 1), self.row(1, 2)]
        with self.assertRaisesRegex(ValueError, 'does not cover each built/runtime coordinate exactly once'):
            validate_abi_matrix(rows, 2)


class AbiCellTypeTests(unittest.TestCase):
    @staticmethod
    def row(built, runtime):
        return {'built_sdk': built, 'runtime_sdk': runtime, 'abi_result': 'PASS',
                'semantic_result': 'PASS'}

    def test_boolean_cell_cannot_pose_as_an_sdk_index(self):
        rows = [self.row(0, 0), self.row(0, 1), self.row(True, 0), self.row(1, 1)]
        with self.assertRaisesRegex(ValueError, 'ABI matrix cell is not an SDK index'):
            validate_abi_matrix(rows, 2)

    def test_missing_coordinate_is_rejected(self):
        rows = [self.row(0, 0), self.row(0, 1), self.row(1, 0), {'built_sdk': 1}]
        with self.assertRaisesRegex(ValueError, 'ABI matrix cell is not an SDK index'):
            validate_abi_matrix(rows, 2)


def behavior_text():
    """A successful same-process probe transcript, matching the real probe vocabulary."""
    checks = ''.join(f'CHECK {name} PASS\n' for name in sorted(CHECKS))
    return (checks
        + 'IDENTITY wirestack aws-lc 5.5.0 0123abcd\n'
        + 'IDENTITY independent_tls OpenSSL 3.0 isolation=deepbind libc=shared '
          'verified_peer=example.test bytes=8\n'
        + 'BOUNDARY symbols SSL_connect global=0x1 isolated=0x2 owners_distinct=1 '
          'independent_owner=/opt/libssl.so\n'
        + 'BOUNDARY unisolated_openssl UNSUPPORTED resolved_identity=AWS-LC\n'
        + 'BOUNDARY crypto OpenSSL_version global=0x1 independent=0x2 owners_distinct=1 '
          'independent_owner=/opt/libcrypto.so\n'
        + 'BOUNDARY libc pthread_getspecific global=0x1 independent=0x1 owner_shared=1 '
          'pthread_create_shared=1 pthread_key_create_shared=1\n')


class AbiEvidenceBindingTests(unittest.TestCase):
    """A matrix row may only attest the run recorded under its own command ID."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-abi-tests-')
        self.root = Path(self.directory.name)
        (self.root / 'docs/evidence/M12-002/binary').mkdir(parents=True)
        self.work = self.root / 'scratch'
        self.work.mkdir()
        self.wrapper = self.root / 'wrapper'
        self.openssl_library = self.root / 'libssl.so'
        self.openssl_crypto_library = self.root / 'libcrypto.so'
        self.wrapper.write_text('')
        self.sdks = [self.root / f'sdk-{i}' for i in range(2)]
        for sdk in self.sdks:
            sdk.mkdir()
        self.binaries = []
        for index in range(2):
            binary = self.work / f'coexist-{index}/target/release/bin/main'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(f'coexist-{index}'.encode())
            self.binaries.append(binary)
        self.report = {'commands': [{'id': 'tool-gcc'}], 'abi_matrix': [], 'scans': {}}
        for index, binary in enumerate(self.binaries):
            self.report['scans'][f'coexist-{index}'] = {
                'path': f'<scratch>/coexist-{index}/target/release/bin/main',
                'digest': artifact_byte_digest(binary).to_json()}
        for built in range(2):
            for runtime in range(2):
                self.cell(built, runtime)

    def tearDown(self):
        self.directory.cleanup()

    def log(self, name, stream, text):
        path = self.root / f'docs/evidence/M12-002/binary/{name}.{stream}.log'
        path.write_text(text)
        return {'path': str(path.relative_to(self.root)), 'digest': text_evidence_digest(path).to_json()}

    def runtime_library(self, runtime):
        return f'<sdk-{runtime}>/runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so'

    def cell(self, built, runtime):
        name = f'abi-{built}-to-{runtime}'
        loading = f'calling init: {self.runtime_library(runtime)}\n'
        argv = ['bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--bind',
            '<scratch>', '<scratch>', '--tmpfs', '<repo>', '--chdir', '<scratch>', '--',
            '<repo>/wrapper', '--sdk-root', f'<sdk-{runtime}>', '--cwd', '<scratch>',
            f'<scratch>/coexist-{built}/target/release/bin/main',
            '<scratch>/certificate.der', '<scratch>/key.pk8']
        environment = {
            'WIRESTACK_FIXTURE_OPENSSL_LIBRARY': '<repo>/libssl.so',
            'WIRESTACK_FIXTURE_OPENSSL_CRYPTO_LIBRARY': '<repo>/libcrypto.so',
            'WIRESTACK_FIXTURE_CA_FILE': '<scratch>/certificate.pem',
            'LD_DEBUG': 'libs'}
        self.report['commands'].append({'id': name, 'argv': argv, 'cwd': '<scratch>',
            'environment': environment, 'exit_code': 0, 'timed_out': False,
            'stdout': self.log(name, 'stdout', behavior_text()),
            'stderr': self.log(name, 'stderr', loading)})
        self.report['abi_matrix'].append({'built_sdk': built, 'runtime_sdk': runtime,
            'binary_digest': self.report['scans'][f'coexist-{built}']['digest'],
            'command': name, 'abi_result': 'PASS', 'semantic_result': 'PASS',
            'runtime_loaded_library': self.runtime_library(runtime),
            'runtime_loading_proof': self.report['commands'][-1]['stderr']})

    def verify(self):
        verify_abi_matrix(self.report, self.root, self.work, self.sdks, self.wrapper,
            self.openssl_library, self.openssl_crypto_library)

    def test_bound_evidence_is_accepted(self):
        self.verify()

    def test_row_cannot_claim_another_cell_command(self):
        self.report['abi_matrix'][0]['command'] = 'abi-1-to-1'
        self.report['abi_matrix'][3]['command'] = 'abi-0-to-0'
        with self.assertRaisesRegex(ValueError, 'ABI row is not bound to its own command: abi-1-to-1'):
            self.verify()

    def test_two_rows_cannot_share_one_command(self):
        self.report['abi_matrix'][1]['command'] = 'abi-0-to-0'
        with self.assertRaisesRegex(ValueError, 'ABI matrix rows do not name distinct commands'):
            self.verify()

    def test_missing_cell_command_is_rejected(self):
        self.report['commands'] = [c for c in self.report['commands'] if c['id'] != 'abi-1-to-0']
        with self.assertRaisesRegex(ValueError, 'ABI command inventory does not match the recorded matrix'):
            self.verify()

    def test_behavior_is_rederived_from_the_retained_stdout(self):
        command = next(c for c in self.report['commands'] if c['id'] == 'abi-0-to-0')
        path = self.root / command['stdout']['path']
        path.write_text(path.read_text().replace('CHECK wirestack_verified_tls PASS\n', ''))
        command['stdout']['digest'] = text_evidence_digest(path).to_json()
        with self.assertRaisesRegex(ValueError, 'same-process behavior checks missing or duplicated'):
            self.verify()

    def test_substituted_loading_proof_is_rejected(self):
        self.report['abi_matrix'][1]['runtime_loading_proof'] = self.report['commands'][1]['stderr']
        with self.assertRaisesRegex(ValueError, 'ABI row loading proof is not its own command log'):
            self.verify()

    def test_claimed_runtime_must_appear_in_the_loader_trace(self):
        self.report['abi_matrix'][2]['runtime_loaded_library'] = '/other/libcangjie-runtime.so'
        with self.assertRaisesRegex(ValueError, 'ABI row did not load its recorded runtime'):
            self.verify()

    def test_failed_cell_command_is_rejected(self):
        next(c for c in self.report['commands'] if c['id'] == 'abi-0-to-0')['exit_code'] = 1
        with self.assertRaisesRegex(ValueError, 'ABI qualification command did not succeed: abi-0-to-0'):
            self.verify()

    def test_row_must_execute_its_own_built_binary(self):
        self.report['scans']['coexist-0']['digest'] = self.report['scans']['coexist-1']['digest']
        with self.assertRaisesRegex(ValueError, 'ABI row executed a binary other than its built artifact'):
            self.verify()

    def test_abi_command_must_run_its_declared_inputs(self):
        mutations = (
            ('binary', lambda command: command['argv'].__setitem__(-3,
                '<scratch>/coexist-1/target/release/bin/main')),
            ('runtime SDK', lambda command: command['argv'].__setitem__(
                command['argv'].index('--sdk-root') + 1, '<sdk-1>')),
            ('wrapper', lambda command: command['argv'].__setitem__(
                command['argv'].index('--') + 1, '<repo>/other-wrapper')),
            ('working directory', lambda command: command.update(cwd='/')),
        )
        for label, mutate in mutations:
            with self.subTest(input=label):
                report = copy.deepcopy(self.report)
                command = next(c for c in report['commands'] if c['id'] == 'abi-0-to-0')
                mutate(command)
                with self.assertRaisesRegex(ValueError, 'ABI command invocation differs'):
                    verify_abi_matrix(report, self.root, self.work, self.sdks, self.wrapper,
                        self.openssl_library, self.openssl_crypto_library)

    def test_abi_command_must_use_declared_tls_fixtures_and_loader_trace(self):
        mutations = (
            ('TLS library', lambda command: command['environment'].__setitem__(
                'WIRESTACK_FIXTURE_OPENSSL_LIBRARY', '<repo>/other-libssl.so')),
            ('loader trace', lambda command: command['environment'].__setitem__('LD_DEBUG', 'off')),
            ('CA fixture', lambda command: command['environment'].__setitem__(
                'WIRESTACK_FIXTURE_CA_FILE', '<scratch>/other-certificate.pem')))
        for label, mutate in mutations:
            with self.subTest(input=label):
                report = copy.deepcopy(self.report)
                command = next(c for c in report['commands'] if c['id'] == 'abi-0-to-0')
                mutate(command)
                with self.assertRaisesRegex(ValueError, 'ABI command environment differs'):
                    verify_abi_matrix(report, self.root, self.work, self.sdks, self.wrapper,
                        self.openssl_library, self.openssl_crypto_library)



class BinaryEvidencePathTests(unittest.TestCase):
    def test_symlinked_command_log_cannot_escape_evidence_root(self):
        with tempfile.TemporaryDirectory(prefix='m12-binary-evidence-') as temporary:
            base = Path(temporary)
            root = base / 'evidence'
            root.mkdir()
            outside = base / 'outside.log'
            outside.write_text('retained output\n')
            (root / 'escape.log').symlink_to(outside)
            stderr = root / 'probe.stderr.log'
            stderr.write_text('')
            report = {'commands': [{'id': 'probe',
                'stdout': {'path': 'escape.log', 'digest': text_evidence_digest(outside).to_json()},
                'stderr': {'path': stderr.name, 'digest': text_evidence_digest(stderr).to_json()}}]}
            with self.assertRaisesRegex(ValueError, 'command evidence path escapes its evidence tree: probe'):
                bound_command(report, 'probe', root)


class IndependentScanInventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-scan-inventory-')
        self.base = Path(self.directory.name)
        self.evidence = self.base / 'evidence'
        self.evidence.mkdir()
        self.work = self.base / 'scratch'
        self.work.mkdir()
        self.sdk = self.base / 'sdk'
        self.sdk.mkdir()
        self.consumers = [(profile, app, self.base / profile / app / 'main')
            for profile in CONSUMER_PROFILES for app in CONSUMER_APPS]
        self.wrapper = self.evidence / 'wrapper'
        self.openssl_library = self.evidence / 'libssl.so'
        system_output = 'libc.so.6 => <scratch>/libc.so.6 (0x1)\n'
        external_output = 'libssl.so.3 => <scratch>/libssl.so.3 (0x2)\n'
        self.report = {'commands': [{'id': 'tool-gcc'}], 'scans': {},
            'dynamic_dependency_closure': {'<scratch>/libc.so.6': 'system-dependency-0'},
            'external_tls_fixture': {'dynamic_dependencies': ['external-tls-dependency-0']}}
        for name in ('closure-0-compiler', 'closure-0-runtime', 'closure-0-coexist'):
            self.add_command(name, system_output)
        self.add_command('external-tls-closure', external_output)
        self.scan_inputs = expected_scan_inputs(self.report, ['target/native/libfixture.a'],
            [self.sdk], self.consumers, self.work, self.wrapper, self.openssl_library, self.evidence)
        self.report['scans'] = {base: {'path': self.normalize_scan_path(path),
            'symbol_inventory_command': base + '-symbols'}
            for base, path in self.scan_inputs.items()}
        expected = gating_command_ids(self.report, 1, self.scan_inputs)
        existing = {command['id'] for command in self.report['commands']}
        self.report['commands'].extend({'id': command_id} for command_id in sorted(expected - existing))

    def normalize_scan_path(self, path):
        value = str(path)
        replacements = ((self.evidence, '<repo>'), (self.work, '<scratch>'),
            (self.sdk, '<sdk-0>'), (self.work.parent, '<task-scratch>'), (Path.home(), '$HOME'))
        for actual, token in sorted(replacements, key=lambda item: -len(str(item[0]))):
            value = value.replace(str(actual), token)
        return value

    def tearDown(self):
        self.directory.cleanup()

    def add_command(self, name, stdout):
        output = self.evidence / f'{name}.stdout.log'
        error = self.evidence / f'{name}.stderr.log'
        output.write_text(stdout)
        error.write_text('')
        if name.startswith('closure-'):
            binary_name = name.removeprefix('closure-0-')
            binary = {'compiler': '<sdk-0>/bin/cjc',
                'runtime': '<sdk-0>/runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so',
                'coexist': '<scratch>/coexist-0/target/release/bin/main'}[binary_name]
            argv = ['<repo>/wrapper', '--sdk-root', '<sdk-0>', 'ldd', binary]
        elif name == 'external-tls-closure':
            argv = ['ldd', '<repo>/libssl.so']
        else:
            self.fail(f'unexpected closure command {name}')
        self.report['commands'].append({'id': name, 'argv': argv, 'cwd': '<scratch>',
            'exit_code': 0, 'timed_out': False,
            'stdout': {'path': output.name, 'digest': text_evidence_digest(output).to_json()},
            'stderr': {'path': error.name, 'digest': text_evidence_digest(error).to_json()}})

    def test_independently_derived_scan_inventory_accepts_complete_report(self):
        verify_command_inventory(self.report, 1, self.scan_inputs)
        verify_scan_inputs(self.report, self.scan_inputs, self.evidence, self.work, [self.sdk])

    def test_scan_label_cannot_borrow_another_artifacts_path(self):
        self.report['scans']['archive-0']['path'] = self.report['scans']['external-tls-fixture']['path']
        with self.assertRaisesRegex(ValueError, 'scan path differs from its declared artifact: archive-0'):
            verify_scan_inputs(self.report, self.scan_inputs, self.evidence, self.work, [self.sdk])

    def test_scanner_command_must_match_its_scan_label(self):
        self.report['scans']['archive-0']['symbol_inventory_command'] = 'external-tls-fixture-symbols'
        with self.assertRaisesRegex(ValueError, 'scanner command does not match independent scan inventory: archive-0'):
            verify_command_inventory(self.report, 1, self.scan_inputs)

    def test_deleting_a_scan_and_its_six_command_chain_does_not_shrink_inventory(self):
        base = 'system-dependency-0'
        self.report['scans'].pop(base)
        scanner_ids = {base + '-' + suffix for suffix in SCAN_SUFFIXES}
        self.report['commands'] = [command for command in self.report['commands']
            if command['id'] not in scanner_ids]
        with self.assertRaisesRegex(ValueError, 'binary scan inventory is incomplete'):
            verify_command_inventory(self.report, 1, self.scan_inputs)

    def test_missing_scanner_command_is_rejected(self):
        missing = 'external-tls-dependency-0-dynamic'
        self.report['commands'] = [command for command in self.report['commands']
            if command['id'] != missing]
        with self.assertRaisesRegex(ValueError, 'native command inventory is incomplete'):
            verify_command_inventory(self.report, 1, self.scan_inputs)

    def test_dynamic_dependency_closure_is_bound_to_the_sdk_binary(self):
        command = next(command for command in self.report['commands']
            if command['id'] == 'closure-0-runtime')
        command['argv'][-1] = '<sdk-0>/bin/cjc'
        with self.assertRaisesRegex(ValueError,
                'dynamic dependency closure invocation changed: closure-0-runtime'):
            expected_scan_inputs(self.report, ['target/native/libfixture.a'], [self.sdk],
                self.consumers, self.work, self.wrapper, self.openssl_library, self.evidence)

    def test_external_tls_closure_is_bound_to_the_selected_library(self):
        command = next(command for command in self.report['commands']
            if command['id'] == 'external-tls-closure')
        command['argv'][-1] = '<repo>/other-libssl.so'
        with self.assertRaisesRegex(ValueError, 'external TLS dependency closure invocation changed'):
            expected_scan_inputs(self.report, ['target/native/libfixture.a'], [self.sdk],
                self.consumers, self.work, self.wrapper, self.openssl_library, self.evidence)


class TruncatedDisassemblyTests(unittest.TestCase):
    def test_truncated_disassembly_cannot_claim_mnemonic_counts(self):
        self.assertEqual(isa_presence(TRUNCATED + 'abc\n'), TRUNCATED_ISA)

    def test_complete_disassembly_counts_mnemonics(self):
        self.assertEqual(isa_presence('  401000:\tvmovdqa %xmm0,%xmm1\n  401004:\taesenc %xmm0,%xmm1\n')
                         ['avx_mnemonics'], 1)


class ConsumerDeclarationTests(unittest.TestCase):
    def test_every_declared_profile_and_app_parses(self):
        for profile in CONSUMER_PROFILES:
            for app in CONSUMER_APPS:
                self.assertEqual(consumer_identity(profile + '/' + app + '=/opt/main'),
                                 (profile, app, Path('/opt/main')))

    def test_undeclared_profile_or_app_is_rejected(self):
        for value in ('nightly-native/cli=/opt/main', 'stable-native/worker=/opt/main',
                      'stable-native=/opt/main', 'stable-native/cli='):
            with self.assertRaisesRegex(ValueError, 'consumer must be'):
                consumer_identity(value)


class ConsumerEvidenceTests(unittest.TestCase):
    """An empty or partial consumer inventory must never reach a PASS verdict."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-consumers-')
        self.root = Path(self.directory.name)
        self.consumers = []
        for profile in CONSUMER_PROFILES:
            for app in CONSUMER_APPS:
                binary = self.root / profile / app / 'bin/main'
                binary.parent.mkdir(parents=True)
                binary.write_bytes((profile + app).encode())
                self.consumers.append((profile, app, binary))

    def tearDown(self):
        self.directory.cleanup()

    def report(self, consumers):
        scans = {f'installed-consumer-{index}': {'path': str(path),
                                                 'digest': artifact_byte_digest(path).to_json()}
                 for index, (_, _, path) in enumerate(consumers)}
        archives = {}
        for profile, app, path in consumers:
            module_root = path.resolve().parent.parent / 'wirestack'
            module_root.mkdir(parents=True, exist_ok=True)
            for module in OPTIONAL_MODULES:
                archive = module_root / f'libwirestack.{module}.a'
                archive.write_bytes(module.encode())
                label = f'optional-{profile}-{app}-{module}'
                archives[label] = str(archive)
                scans[label] = {'path': str(archive), 'digest': artifact_byte_digest(archive).to_json()}
        return {'consumers': {profile + '/' + app: str(path)
                              for profile, app, path in consumers},
                'scans': scans, 'compiled_optional_modules': archives}

    def test_ready_report_is_accepted(self):
        verify_consumers(self.report(self.consumers), self.consumers, {})

    def test_missing_consumer_identity_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'every declared profile/app installed consumer exactly once'):
            verify_consumers(self.report(self.consumers), self.consumers[:9], {})

    def test_duplicated_consumer_identity_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'every declared profile/app installed consumer exactly once'):
            verify_consumers(self.report(self.consumers),
                             self.consumers[:9] + [self.consumers[0]], {})

    def test_omitted_consumer_from_the_report_is_rejected(self):
        report = self.report(self.consumers)
        report['consumers'].pop('stable-native/cli')
        with self.assertRaisesRegex(ValueError, 'installed consumer inventory changed'):
            verify_consumers(report, self.consumers, {})

    def test_misbound_optional_archive_identity_is_rejected(self):
        report = self.report(self.consumers)
        renamed = {}
        for label, path in report['compiled_optional_modules'].items():
            profile = 'candidate-native' if label.startswith('optional-stable-native') else 'stable-native'
            replacement = label.replace(label.split('-')[1], profile, 1)
            renamed[replacement] = path
            report['scans'][replacement] = report['scans'].pop(label)
        report['compiled_optional_modules'] = renamed
        with self.assertRaisesRegex(ValueError, 'compiled optional archive inventory is incomplete'):
            verify_consumers(report, self.consumers, {})

    def test_optional_archive_bytes_must_match_their_identity(self):
        report = self.report(self.consumers)
        label = 'optional-stable-native/cli-gzip'.replace('/', '-')
        Path(report['compiled_optional_modules'][label]).write_bytes(b'substituted')
        with self.assertRaisesRegex(ValueError, 'compiled optional archive changed: ' + label):
            verify_consumers(report, self.consumers, {})

    def test_missing_declared_optional_archive_is_rejected(self):
        report = self.report(self.consumers)
        report['compiled_optional_modules'].pop(next(iter(report['compiled_optional_modules'])))
        with self.assertRaisesRegex(ValueError, 'compiled optional archive inventory is incomplete'):
            verify_consumers(report, self.consumers, {})

    def test_consumer_must_match_its_capture(self):
        report = self.report(self.consumers)
        report['consumers']['stable-native/cli'] = '/other/main'
        with self.assertRaisesRegex(ValueError, 'installed consumer differs from its capture'):
            verify_consumers(report, self.consumers, {})

    def test_changed_consumer_binary_is_rejected(self):
        report = self.report(self.consumers)
        self.consumers[0][2].write_bytes(b'replaced')
        with self.assertRaisesRegex(ValueError, 'installed consumer changed: stable-native/cli'):
            verify_consumers(report, self.consumers, {})


@unittest.skipUnless(all(shutil.which(name) for name in ('gcc', 'readelf', 'nm', 'objdump')),
                     'native ELF tools required')
class ScanVerdictTests(unittest.TestCase):
    """Recompute ELF/loader verdicts from real scanner output instead of trusting the report."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-scan-tests-')
        self.root = Path(self.directory.name)
        (self.root / 'docs/evidence/M12-002/binary').mkdir(parents=True)
        self.binary = self.root / 'probe'
        source = self.root / 'probe.c'
        source.write_text('#include <stdio.h>\nint main(void) { return puts("scan") < 0; }\n')
        subprocess.run(['gcc', '-march=x86-64', str(source), '-o', str(self.binary)], check=True,
                       capture_output=True)
        self.report = {'scans': {}, 'commands': []}
        self.report['scans']['probe'] = self.scan('probe', self.binary)

    def tearDown(self):
        self.directory.cleanup()

    def scan(self, label, path):
        output = {}
        for suffix, argv in (('headers', ['readelf', '-hW']), ('dynamic', ['readelf', '-dW']),
                             ('versions', ['readelf', '-VW']), ('notes', ['readelf', '-nW']),
                             ('symbols', ['nm', '-g', '--defined-only']),
                             ('disassembly', ['objdump', '-d', '--no-show-raw-insn'])):
            result = subprocess.run([*argv, str(path)], capture_output=True, text=True)
            log = self.root / f'docs/evidence/M12-002/binary/{label}-{suffix}.stdout.log'
            log.write_text(result.stdout)
            self.report['commands'].append({'id': f'{label}-{suffix}', 'exit_code': result.returncode,
                'timed_out': False, 'argv': [*argv, str(path)], 'cwd': str(self.root),
                'stdout': {'path': str(log.relative_to(self.root)), 'digest': text_evidence_digest(log).to_json()},
                'stderr': {'path': str(log.relative_to(self.root)), 'digest': text_evidence_digest(log).to_json()}})
            output[suffix] = result.stdout
        return {'path': str(path), 'digest': artifact_byte_digest(path).to_json(),
                'symbol_inventory_command': label + '-symbols',
                **scan_fields(output['headers'], output['dynamic'], output['versions'],
                    output['notes'], output['symbols'], isa_presence(output['disassembly']))}

    def test_real_scanner_output_satisfies_the_recorded_verdicts(self):
        verify_scan_verdicts(self.report, self.root)

    def test_altered_loader_verdict_is_rejected(self):
        self.report['scans']['probe']['needed'] = ['libtls.so.6']
        with self.assertRaisesRegex(ValueError, 'scan verdict differs from its captured output: probe/needed'):
            verify_scan_verdicts(self.report, self.root)

    def test_claimed_cpu_minimum_is_rejected(self):
        self.report['scans']['probe']['minimum_cpu'] = 'AVX2'
        with self.assertRaisesRegex(ValueError, 'scan verdict differs from its captured output: probe/minimum_cpu'):
            verify_scan_verdicts(self.report, self.root)

    def test_missing_scanner_command_is_rejected(self):
        self.report['commands'] = [c for c in self.report['commands'] if c['id'] != 'probe-dynamic']
        with self.assertRaisesRegex(ValueError, 'native command is not recorded exactly once: probe-dynamic'):
            verify_scan_verdicts(self.report, self.root)

    def test_altered_scanner_log_is_rejected(self):
        log = self.root / self.report['commands'][0]['stdout']['path']
        log.write_text(log.read_text() + 'changed\n')
        with self.assertRaisesRegex(ValueError, 'scan diagnostic log changed: probe-headers'):
            verify_scan_verdicts(self.report, self.root)

    def test_absolute_loader_path_hazard_is_rejected(self):
        library = self.root / 'libfixture.so'
        source = self.root / 'library.c'
        source.write_text('int fixture(void) { return 42; }\n')
        subprocess.run(['gcc', '-shared', '-fPIC', str(source), '-Wl,-soname,/opt/example/libfixture.so',
                        '-o', str(library)], check=True, capture_output=True)
        binary = self.root / 'linked'
        source.write_text('extern int fixture(void); int main(void) { return fixture() != 42; }\n')
        subprocess.run(['gcc', str(source), str(library), '-o', str(binary)], check=True, capture_output=True)
        self.report['scans']['linked'] = self.scan('linked', binary)
        with self.assertRaisesRegex(ValueError, 'absolute loader path: linked'):
            verify_scan_verdicts(self.report, self.root)


class RepeatedCaptureInstallationTests(unittest.TestCase):
    """A repeated capture scans the archive it selected, not the previous attempt's tree."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-install-tests-')
        self.work = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def archive(self, name: str, marker: str) -> Path:
        files = {'src/wirestack/probe.cj': f'package wirestack.probe\n// {marker}\n'.encode()}
        entries = [{'path': path, 'bytes': len(data), 'sha256': release.artifact_payload_sha256(data)}
                   for path, data in sorted(files.items())]
        fingerprint = release.evidence_digest.text_evidence_bytes_sha256(release.canonical_json(entries))
        manifest = {'schema_version': 2, 'package': 'wirestack', 'version': release.VERSION,
                    'payload': entries, 'payload_sha256': fingerprint,
                    'artifactBuildFingerprint': fingerprint}
        payload = {**files, 'release-manifest.json': release.canonical_json(manifest)}
        path = self.work / name
        release.write_reproducible_archive(path, payload)
        return path

    def test_second_capture_replaces_the_previous_installation(self):
        first = self.archive('first.tar.gz', 'first')
        second = self.archive('second.tar.gz', 'second')
        installed = install_selected_archive(first, self.work)
        self.assertIn('first', (installed / 'src/wirestack/probe.cj').read_text())
        self.assertEqual(install_selected_archive(second, self.work), installed)
        self.assertIn('second', (installed / 'src/wirestack/probe.cj').read_text())
        _, manifest = release.read_verified_payload(second)
        self.assertEqual(json.loads((installed / 'release-manifest.json').read_text())['payload_sha256'],
                         manifest['payload_sha256'])

    def test_leftover_installation_cannot_survive_a_new_capture(self):
        archive = self.archive('selected.tar.gz', 'selected')
        stale = self.work / 'wirestack'
        (stale / 'src').mkdir(parents=True)
        (stale / 'src/stale.cj').write_text('package wirestack.stale\n')
        installed = install_selected_archive(archive, self.work)
        self.assertFalse((installed / 'src/stale.cj').exists())
        self.assertIn('selected', (installed / 'src/wirestack/probe.cj').read_text())

    def test_report_payload_must_be_the_selected_archive(self):
        first = self.archive('first.tar.gz', 'first')
        second = self.archive('second.tar.gz', 'second')
        _, manifest = release.read_verified_payload(first)
        bind_installed_payload({'payload_sha256': manifest['payload_sha256']}, first)
        with self.assertRaisesRegex(ValueError, 'installed payload is not the selected archive'):
            bind_installed_payload({'payload_sha256': manifest['payload_sha256']}, second)

class RepeatedScanCacheTests(unittest.TestCase):
    """Reused scanner observations are rebound to the current capture command namespace."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='m12-scan-cache-')
        self.base = Path(self.directory.name)
        self.work = self.base / 'scratch'
        self.work.mkdir()
        self.output = self.base / 'docs/evidence/M12-002/binary'
        self.output.mkdir(parents=True)
        self.artifact = self.work / 'library.so'
        self.artifact.write_bytes(b'unchanged scanner input')

    def tearDown(self):
        self.directory.cleanup()

    def test_cached_scan_commands_are_rebound_to_current_attempt(self):
        prior_commands = []
        for suffix in SCAN_SUFFIXES:
            command_id = f'attempt-1-probe-{suffix}'
            record = {'id': command_id}
            for stream in ('stdout', 'stderr'):
                log = self.output / f'{command_id}.{stream}.log'
                log.write_text(f'{suffix} {stream}\n')
                record[stream] = {'path': log.relative_to(self.base).as_posix(),
                    'digest': text_evidence_digest(log).to_json()}
            prior_commands.append(record)
        prior_scan = {'path': '<scratch>/library.so',
            'digest': artifact_byte_digest(self.artifact).to_json(),
            'scanner': scanner_digest(),
            'symbol_inventory_command': 'attempt-1-probe-symbols'}
        with patch('tools.m12_002_binary.ROOT', self.base):
            capture = Capture(self.output, self.work, [])
            capture.prefix = 'attempt-2-'
            capture.prior = {'scans': {'probe': prior_scan}, 'commands': prior_commands}
            scan = capture.scan('probe', self.artifact)
        self.assertEqual(scan['symbol_inventory_command'], 'attempt-2-probe-symbols')
        self.assertEqual([record['id'] for record in capture.commands],
            [f'attempt-2-probe-{suffix}' for suffix in SCAN_SUFFIXES])



if __name__ == '__main__':
    unittest.main()

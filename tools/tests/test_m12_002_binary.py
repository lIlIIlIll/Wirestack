"""Behavioral ELF checks use real linked objects, not fabricated readelf output."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest
from tools.m12_002_binary import (dynamic_fields, scan_fields, validate_abi_matrix,
    verify_consumers, verify_scan_verdicts, versions, CONSUMER_APPS, CONSUMER_PROFILES,
    OPTIONAL_MODULES, consumer_identity)


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
                binary = self.root / profile / app / 'main'
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
        for index, (_, _, path) in enumerate(consumers):
            for module in OPTIONAL_MODULES:
                archive = path.with_name(f'{module}.a')
                archive.write_bytes(module.encode())
                label = f'optional-consumer-{index}-{module}'
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
                'timed_out': False,
                'stdout': {'path': str(log.relative_to(self.root)), 'digest': text_evidence_digest(log).to_json()},
                'stderr': {'path': str(log.relative_to(self.root)), 'digest': text_evidence_digest(log).to_json()}})
            output[suffix] = result.stdout
        counts = {'avx_mnemonics': 0, 'aes_mnemonics': 0, 'pclmul_mnemonics': 0}
        return {'path': str(path), 'digest': artifact_byte_digest(path).to_json(),
                'symbol_inventory_command': label + '-symbols',
                **scan_fields(output['headers'], output['dynamic'], output['versions'],
                    output['notes'], output['symbols'], counts)}

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


if __name__ == '__main__':
    unittest.main()

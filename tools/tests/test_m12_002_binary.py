"""Behavioral ELF checks use real linked objects, not fabricated readelf output."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from tools.m12_002_binary import dynamic_fields, validate_abi_matrix, versions


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


if __name__ == '__main__':
    unittest.main()

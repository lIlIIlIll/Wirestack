"""Exercise inventory rejection with a self-contained synthetic manifest."""
import copy
import subprocess
import unittest
from pathlib import Path
import tempfile
from unittest import mock
from tools import evidence_digest as digest
from tools import m12_004_inventory as inventory


def fixture_digest(value):
    return digest.text_evidence_bytes_sha256(value.encode('utf-8'))


def fixture_metadata(source_root, payload):
    supply = inventory.supply
    source_names = (
        'native/tls/aws_lc/wirestack_tls_provider.c',
        'native/tls/aws_lc/wirestack_tls_provider.h',
        'native/resolver/linux/wirestack_resolver.c',
        'native/resolver/linux/wirestack_resolver.h',
        'native/http_files/wirestack_http_files.c',
        'native/http_files/wirestack_http_files.h',
    )
    source_digests = {name: digest.text_evidence_sha256(source_root / name) for name in source_names}
    http_inputs = {'sources': {name: source_digests[name] for name in source_names if '/http_files/' in name}}
    http_fingerprint = digest.text_evidence_bytes_sha256(inventory.release.canonical_json(http_inputs))
    provider_archive = {'name': 'libwirestack_tls_provider.a', 'bytes': 17, 'sha256': fixture_digest('provider archive')}
    resolver_archive = {'path': 'lib/libwirestack_resolver.a', 'bytes': 19, 'sha256': fixture_digest('resolver archive')}
    http_archive_sha = fixture_digest('http files archive')
    provider_manifest_sha = fixture_digest('provider manifest')
    resolver_manifest_sha = fixture_digest('resolver manifest')
    http_manifest_sha = fixture_digest('http files manifest')
    provider_fingerprint = fixture_digest('provider build')
    provider_pin = {'provider': 'synthetic-test-provider', 'version': '1'}
    licenses = {name: fixture_digest('license:' + name) for name in supply.LICENSE_MEMBERS}
    suffix_license = fixture_digest('license:' + supply.PUBLIC_SUFFIX_FILES[0])
    suffix_source = fixture_digest('source:' + supply.PUBLIC_SUFFIX_FILES[1])
    licenses[supply.PUBLIC_SUFFIX_FILES[0]] = suffix_license
    gzip_sources = [
        {'path': name, 'sha256': digest.text_evidence_bytes_sha256(content)}
        for name, content in sorted(payload.items())
        if name.startswith('src/gzip/') and name.endswith('.cj')
    ]
    release = {
        'schema_version': 2,
        'package': 'wirestack',
        'target': 'linux-x86_64-glibc',
        'payload_sha256': fixture_digest('release payload'),
        'externalOpenSslDependency': False,
        'license': {'expression': supply.PROJECT_LICENSE_EXPRESSION, 'file': 'LICENSE', 'sha256': licenses['LICENSE']},
        'thirdPartyNotices': {
            'index': 'THIRD_PARTY_NOTICES.md',
            'files': [{'path': name, 'sha256': licenses[name]} for name in (*supply.LICENSE_MEMBERS[1:], supply.PUBLIC_SUFFIX_FILES[0])],
        },
        'provider': {'manifest_sha256': provider_manifest_sha, 'archive_sha256': provider_archive['sha256']},
        'resolver': {'manifest_sha256': resolver_manifest_sha, 'archive_sha256': resolver_archive['sha256']},
        'httpFiles': {
            'component': 'wirestack-http-files', 'abi_version': 1,
            'build_fingerprint': http_fingerprint, 'manifest_sha256': http_manifest_sha,
            'archive_sha256': http_archive_sha,
        },
        'optionalModules': [{
            'package': 'wirestack.gzip', 'nativeDependencies': [],
            'implementation': 'wirestack-cangjie-rfc1951-rfc1952',
            'selection': 'explicit-package-import', 'sources': gzip_sources,
        }],
    }
    return {
        'artifact_sha256': fixture_digest('release archive'),
        'artifact_bytes': 23,
        'release': release,
        'license_sha256': licenses,
        'provider': {
            'externalOpenSslDependency': False,
            'runtimeLoaderLibraryStrings': [],
            'build_fingerprint': provider_fingerprint,
            'build_inputs': {
                'provider': provider_pin,
                'shim': {
                    'source_sha256': source_digests[source_names[0]],
                    'header_sha256': source_digests[source_names[1]],
                },
                'test_only_key_log': False,
            },
            'test_only_key_log': False,
            'archive': provider_archive,
        },
        'provider_manifest_sha256': provider_manifest_sha,
        'provider_archive': provider_archive,
        'resolver': {
            'inputs': {'source_sha256': source_digests[source_names[2]], 'header_sha256': source_digests[source_names[3]]},
            'archive': resolver_archive,
        },
        'resolver_manifest_sha256': resolver_manifest_sha,
        'resolver_archive': resolver_archive,
        'http_files': {
            'schema_version': 1, 'component': 'wirestack-http-files', 'abi_version': 1,
            'private_runtime_abi': False, 'inputs': http_inputs, 'build_fingerprint': http_fingerprint,
            'archive': {'bytes': 29, 'sha256': http_archive_sha},
        },
        'http_files_manifest_sha256': http_manifest_sha,
        'http_files_archive_sha256': http_archive_sha,
        'http_files_archive_bytes': 29,
        'public_suffix': {
            'name': 'publicsuffix/list', 'license': 'MPL-2.0',
            'upstream_repository': 'https://github.com/publicsuffix/list',
            'upstream_revision': 'a' * 40, 'sha256': suffix_source,
            'license_file': 'LICENSE.MPL-2.0', 'license_sha256': suffix_license,
        },
        'public_suffix_payload': {
            supply.PUBLIC_SUFFIX_FILES[0]: {'sha256': suffix_license},
            supply.PUBLIC_SUFFIX_FILES[1]: {'sha256': suffix_source},
        },
    }


class InventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.source_root = Path(cls.temp.name)
        source_names = (
            'native/tls/aws_lc/wirestack_tls_provider.c',
            'native/tls/aws_lc/wirestack_tls_provider.h',
            'native/resolver/linux/wirestack_resolver.c',
            'native/resolver/linux/wirestack_resolver.h',
            'native/http_files/wirestack_http_files.c',
            'native/http_files/wirestack_http_files.h',
        )
        for name in source_names:
            path = cls.source_root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((inventory.ROOT / name).read_bytes())
        cls.payload = {
            path.relative_to(inventory.ROOT).as_posix(): path.read_bytes()
            for path in (inventory.ROOT / 'src/gzip').glob('*.cj')
        }
        cls.payload['target/native/resolver/current/include/wirestack_resolver.h'] = (
            b'int wirestack_resolver_open(void);\nint wirestack_resolver_close(void);\n'
        )
        cls.metadata = fixture_metadata(cls.source_root, cls.payload)

    def check(self, metadata=None, payload=None, root=None):
        return inventory.validate_components(metadata or self.metadata, payload or self.payload, root or self.source_root)


    def test_public_symbol_removed(self):
        header = self.payload['target/native/resolver/current/include/wirestack_resolver.h'].decode()
        symbols = inventory.re.findall(r'\b(wirestack_resolver_\w+)\s*\(', header)
        inventory.validate_symbols(header, symbols, 'wirestack_resolver_')
        with self.assertRaisesRegex(ValueError, 'public symbol declaration drift'):
            inventory.validate_symbols(header, symbols[:-1], 'wirestack_resolver_')

    def test_public_symbol_added(self):
        header = self.payload['target/native/resolver/current/include/wirestack_resolver.h'].decode()
        symbols = inventory.re.findall(r'\b(wirestack_resolver_\w+)\s*\(', header)
        with self.assertRaisesRegex(ValueError, 'public symbol declaration drift'):
            inventory.validate_symbols(header, symbols + ['wirestack_resolver_unlisted'], 'wirestack_resolver_')

    def test_replaced_native_archive(self):
        metadata = copy.deepcopy(self.metadata)
        metadata['resolver_archive']['sha256'] = '0' * 64
        with self.assertRaisesRegex(inventory.supply.SupplyChainError, 'resolver archive'):
            self.check(metadata=metadata)

    def test_source_revision_drift(self):
        metadata = copy.deepcopy(self.metadata)
        metadata['provider']['build_inputs']['shim']['source_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'native source drift'):
            self.check(metadata=metadata)

    def test_psl_bytes_drift(self):
        metadata = copy.deepcopy(self.metadata)
        metadata['public_suffix_payload'][inventory.supply.PUBLIC_SUFFIX_FILES[1]]['sha256'] = '0' * 64
        with self.assertRaisesRegex(inventory.supply.SupplyChainError, 'public suffix source digest'):
            self.check(metadata=metadata)

    def test_psl_license_drift(self):
        metadata = copy.deepcopy(self.metadata)
        metadata['public_suffix']['license'] = 'Apache-2.0'
        with self.assertRaisesRegex(inventory.supply.SupplyChainError, 'public suffix source identity'):
            self.check(metadata=metadata)

    def test_gzip_compression_dependency(self):
        metadata = copy.deepcopy(self.metadata)
        metadata['release']['optionalModules'][0]['nativeDependencies'] = ['libz.so']
        with self.assertRaisesRegex(ValueError, 'gzip native dependency'):
            self.check(metadata=metadata)

    def test_gzip_changed_code(self):
        payload = dict(self.payload)
        payload['src/gzip/decoder.cj'] += b'\n// changed implementation\n'
        with self.assertRaisesRegex(ValueError, 'gzip source digest'):
            self.check(payload=payload)

    def test_gzip_unlisted_source(self):
        payload = dict(self.payload)
        payload['src/gzip/extra.cj'] = b'package wirestack.gzip\n'
        with self.assertRaisesRegex(ValueError, 'gzip source inventory'):
            self.check(payload=payload)

    def test_keylog_manifest(self):
        metadata = copy.deepcopy(self.metadata)
        metadata['provider']['test_only_key_log'] = True
        with self.assertRaisesRegex(ValueError, 'keylog artifact'):
            self.check(metadata=metadata)

    def test_license_notice_drift(self):
        metadata = copy.deepcopy(self.metadata)
        metadata['license_sha256']['third_party/aws-lc/NOTICE'] = '0' * 64
        with self.assertRaisesRegex(inventory.supply.SupplyChainError, 'notice inventory'):
            self.check(metadata=metadata)


class ArtifactRevalidationTests(unittest.TestCase):
    """The emitted artifact block must describe the bytes that were inspected."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifact = self.root / 'candidate.tar.gz'
        self.artifact.write_bytes(b'first inspected archive bytes')
        self.inspected = inventory.artifact_binding(self.artifact)
        self.sdk = self.root / 'sts-sdk'
        self.sdk.mkdir()
        self.work = self.root / 'work'
        self.work.mkdir()
        self.output = self.root / 'output'
        self.payload = {}
        for base, name in (('target/native/current', 'libwirestack_tls_provider.a'),
                           ('target/native/resolver/current', 'libwirestack_resolver.a'),
                           ('target/native/http_files/current', 'libwirestack_http_files.a')):
            self.payload[base + '/lib/' + name] = b'archive'
            self.payload[base + '/include/' + name.removeprefix('lib').removesuffix('.a') + '.h'] = b'int x(void);\n'
        for name in inventory.supply.LICENSE_MEMBERS:
            self.payload[name] = b'license\n'
        for name in inventory.supply.PUBLIC_SUFFIX_FILES:
            self.payload[name] = b'suffix\n'

    def fake_run(self, argv, **kwargs):
        if argv[0] == 'nm' and '-u' not in argv:
            name = Path(argv[-1]).name
            prefix = {'libwirestack_tls_provider.a': 'wirestack_tls_',
                      'libwirestack_resolver.a': 'wirestack_resolver_',
                      'libwirestack_http_files.a': 'wirestack_http_files_'}[name]
            return subprocess.CompletedProcess(argv, 0, f'0000000000000000 T {prefix}abi_version\n'.encode(), b'')
        return subprocess.CompletedProcess(argv, 0, b'', b'')

    def collect(self, intake):
        sdk_binding = mock.patch.object(inventory, 'sdk_binding', return_value={})
        with mock.patch.object(inventory.subprocess, 'run', side_effect=self.fake_run), \
             mock.patch.object(inventory.supply, 'artifact_metadata', return_value=self.metadata()), \
             mock.patch.object(inventory.release, 'read_verified_payload',
                               return_value=(self.payload, {'package': 'wirestack', 'version': '1.0.0',
                                                            'production_source_files': 1, 'artifactBuildFingerprint': 'a' * 64,
                                                            'payload_sha256': 'b' * 64})), \
             mock.patch.object(inventory, 'validate_components', return_value=([], {})), \
             mock.patch.object(inventory, 'intake', side_effect=intake), \
             mock.patch.object(inventory, 'validate_symbols'), \
             sdk_binding:
            return inventory.collect(self.artifact, self.sdk, self.output, self.work)

    def metadata(self):
        provider = {'providerVersion': '5.11.0', 'patchLevel': '0', 'build_fingerprint': 'c' * 64,
                    'build_inputs': {'provider': {'source': {'kind': 'git'}, 'patches': [],
                                                  'license_expression': 'Apache-2.0'}}}
        return {'provider': provider, 'resolver': {}, 'http_files': {},
                'public_suffix': {'name': 'publicsuffix/list'}}

    def test_untouched_artifact_revalidates(self):
        self.assertEqual(inventory.require_artifact_unchanged(self.artifact, self.inspected), self.inspected)

    def test_same_size_replacement_is_rejected(self):
        # A same-length replacement defeats any size-only comparison, and the
        # window covers symbol checks, compiler smoke, SDK commands and intake.
        self.artifact.write_bytes(b'other inspected archive bytes')
        self.assertEqual(self.artifact.stat().st_size, self.inspected['bytes'])
        with self.assertRaisesRegex(ValueError, 'artifact changed during inspection: candidate.tar.gz'):
            inventory.require_artifact_unchanged(self.artifact, self.inspected)

    def test_missing_artifact_is_reported_as_drift(self):
        self.artifact.unlink()
        with self.assertRaisesRegex(ValueError, 'artifact changed during inspection'):
            inventory.require_artifact_unchanged(self.artifact, self.inspected)

    def test_artifact_replaced_during_the_run_aborts_instead_of_reporting(self):
        def replacing(output, versions):
            self.artifact.write_bytes(b'second inspected archive byt')
            return {'channels': []}

        with self.assertRaisesRegex(ValueError, 'artifact changed during inspection'):
            self.collect(replacing)

    def test_emitted_artifact_block_is_the_inspected_identity(self):
        report = self.collect(lambda output, versions: {'channels': []})
        self.assertEqual(report['status'], 'PASS')
        self.assertEqual(report['artifact']['digest'], self.inspected['digest'])
        self.assertEqual(report['artifact']['bytes'], self.inspected['bytes'])


if __name__ == '__main__':
    unittest.main()

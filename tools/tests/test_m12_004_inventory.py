"""Exercise inventory rejection against real embedded baseline manifests."""
import copy
import unittest
from pathlib import Path
import tempfile
from tools import evidence_digest as digest
from tools import m12_004_inventory as inventory


class InventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.artifact = inventory.ROOT / 'docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz'
        cls.metadata = inventory.supply.artifact_metadata(cls.artifact)
        cls.payload, _ = inventory.release.read_verified_payload(cls.artifact)
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.source_root = Path(cls.temp.name)
        # Isolate the source-binding boundary from an immutable old archive:
        # each expected source digest below belongs to this real fixture tree.
        for name in ('native/tls/aws_lc/wirestack_tls_provider.c',
                     'native/tls/aws_lc/wirestack_tls_provider.h',
                     'native/resolver/linux/wirestack_resolver.c',
                     'native/resolver/linux/wirestack_resolver.h',
                     'native/http_files/wirestack_http_files.c',
                     'native/http_files/wirestack_http_files.h'):
            path = cls.source_root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((inventory.ROOT / name).read_bytes())
        cls.metadata['provider']['build_inputs']['shim']['source_sha256'] = digest.text_evidence_sha256(
            cls.source_root / 'native/tls/aws_lc/wirestack_tls_provider.c')
        cls.metadata['provider']['build_inputs']['shim']['header_sha256'] = digest.text_evidence_sha256(
            cls.source_root / 'native/tls/aws_lc/wirestack_tls_provider.h')
        for part, suffix in (('source', 'c'), ('header', 'h')):
            cls.metadata['resolver']['inputs'][part + '_sha256'] = digest.text_evidence_sha256(
                cls.source_root / ('native/resolver/linux/wirestack_resolver.' + suffix))
        for name in cls.metadata['http_files']['inputs']['sources']:
            cls.metadata['http_files']['inputs']['sources'][name] = digest.text_evidence_sha256(cls.source_root / name)

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


if __name__ == '__main__':
    unittest.main()

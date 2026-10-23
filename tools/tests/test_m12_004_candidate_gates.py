"""Candidate orchestration rejection controls. No SDK or provider builds."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from tools import m12_004_candidate_gates as gate

PACKAGE = 'wirestack-0.1.0'


def write_tree(root, files):
    for name, content in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    return root


def fake_extract(archive, destination):
    """Stand in for the real extractor: same destination semantics, no archive.

    ``release.extract_archive`` reads the verified payload again, so the
    regression supplies the payload directly and keeps checking which
    directory the gate extracted into and what it bound.
    """
    write_tree(destination / PACKAGE, PAYLOADS[archive.name])
    return destination / PACKAGE


PAYLOADS = {
    'candidate.tar.gz': {'src/main.cj': b'main\n', 'target/native/current/lib/p.a': b'archive\n'},
    'baseline.tar.gz': {'src/main.cj': b'base\n', 'target/native/current/lib/p.a': b'older\n'},
}


class CandidateGatesTests(unittest.TestCase):
    def temporary(self):
        return tempfile.TemporaryDirectory()

    def archives(self, root):
        for name in PAYLOADS:
            (root / name).write_bytes(name.encode())
        return type('Args', (), {'artifact': root / 'candidate.tar.gz',
                                 'baseline': root / 'baseline.tar.gz'})()

    def test_native_same_size_mutation_rejected(self):
        with self.temporary() as directory:
            root = Path(directory)
            archive = root / 'provider.a'
            archive.write_bytes(b'abcd')
            payload = {'provider.a': b'abcd'}
            before = gate.tree_inventory(root)
            archive.write_bytes(b'abce')
            with self.assertRaisesRegex(ValueError, 'payload changed'):
                gate.assert_unchanged(root, payload, before)

    def test_default_build_hook_rejected(self):
        with self.temporary() as directory:
            root = Path(directory)
            (root / 'build.cj').write_text('unexpected hook')
            with self.assertRaisesRegex(ValueError, 'payload changed'):
                gate.assert_unchanged(root, {}, {})

    def test_overlay_cannot_replace_production(self):
        with self.temporary() as directory:
            root = Path(directory)
            source, installed = root / 'source', root / 'installed'
            name = gate.TEST_FILES[0]
            for base in (source, installed):
                path = base / name
                path.parent.mkdir(parents=True)
                path.write_text('same')
            with self.assertRaisesRegex(ValueError, 'collides'):
                gate.overlay(source, installed, [])

    def test_added_fuzz_sources_and_build_output_are_visible(self):
        # The former inventory hashed only archive-declared paths, so the fuzz
        # overlay, its corpora and the `target` build output were invisible.
        with self.temporary() as directory:
            root = Path(directory)
            payload = dict(PAYLOADS['candidate.tar.gz'])
            write_tree(root, payload)
            before = gate.tree_inventory(root)
            gate.assert_pristine(root, payload)
            for added in ({'src/internal/tls_engine/m3_028_fuzz_test.cj': b'test\n'},
                          {'fuzz/corpus/m7-023/v1/one.hex': b'00\n'},
                          {'target/release/unittest_bin/pkg/main': b'\x7fELF'}):
                with self.subTest(added=sorted(added)):
                    write_tree(root, added)
                    with self.assertRaisesRegex(ValueError, 'does not equal the extracted archive'):
                        gate.assert_pristine(root, payload)
                    with self.assertRaisesRegex(ValueError, 'payload changed'):
                        gate.assert_unchanged(root, payload, before)
                    for name in added:
                        (root / name).unlink()

    def test_symbolic_link_in_the_installation_is_rejected(self):
        with self.temporary() as directory:
            root = Path(directory)
            write_tree(root, {'src/main.cj': b'main\n'})
            (root / 'escape.cj').symlink_to('/etc/hostname')
            with self.assertRaisesRegex(ValueError, 'symbolic link'):
                gate.tree_inventory(root)

    def runner(self, work):
        return type('Runner', (), {'work': work, 'redact': str, 'env': {},
                                   'output': work / 'output', 'run': lambda *a, **k: ('', {})})()

    def test_performance_leg_measures_a_fresh_extraction(self):
        with self.temporary() as directory:
            root = Path(directory)
            args = self.archives(root)
            work = root / 'work'
            work.mkdir()
            # A fuzz-era directory is present and polluted; it must not be measured.
            write_tree(work / 'candidate-install' / PACKAGE, {'src/main.cj': b'main\n',
                                                              'fuzz/corpus/added.hex': b'00\n'})
            measured = {}

            def fake_performance(runner, installations):
                for label, installed in installations.items():
                    measured[label] = (installed, sorted(
                        path.relative_to(installed).as_posix() for path in installed.rglob('*') if path.is_file()))
                return {'status': 'PASS'}

            report = {}
            with patch.object(gate.release, 'extract_archive', side_effect=fake_extract), \
                 patch.object(gate, 'performance_gate', side_effect=fake_performance):
                result = gate.performance_action(self.runner(work), args,
                                                 PAYLOADS['candidate.tar.gz'], PAYLOADS['baseline.tar.gz'], report)
            candidate, produced = measured['candidate']
            self.assertEqual(produced, sorted(PAYLOADS['candidate.tar.gz']))
            self.assertEqual(candidate.parent.name, 'performance-candidate')
            for label, name in (('candidate', 'candidate.tar.gz'), ('baseline', 'baseline.tar.gz')):
                binding = report['performance_installations'][label]
                self.assertEqual(binding['archive'], gate.d.artifact_byte_digest(root / name).to_json())
                self.assertEqual(binding['tree'], gate.tree_digest(gate.tree_inventory(work / ('performance-' + label) / PACKAGE)))
            self.assertEqual(result['installations'], report['performance_installations'])
            self.assertEqual(result['status'], 'PASS')

    def test_performance_leg_rejects_a_touched_installation(self):
        with self.temporary() as directory:
            root = Path(directory)
            args = self.archives(root)

            def polluting(runner, installations):
                write_tree(installations['candidate'], {'fuzz/corpus/added.hex': b'00\n'})
                return {'status': 'PASS'}

            with patch.object(gate.release, 'extract_archive', side_effect=fake_extract), \
                 patch.object(gate, 'performance_gate', side_effect=polluting):
                with self.assertRaisesRegex(ValueError, 'does not equal the extracted archive'):
                    gate.performance_action(self.runner(root / 'work'), args,
                                            PAYLOADS['candidate.tar.gz'], PAYLOADS['baseline.tar.gz'], {})

    def test_failures_do_not_reduce_fuzz_target_list(self):
        with self.temporary() as directory:
            root = Path(directory)
            with patch.object(gate.release, 'extract_archive', side_effect=fake_extract), \
                 patch.object(gate, 'overlay', return_value={}), \
                 patch.object(gate.fuzz, 'execute_target',
                              side_effect=[{'decision': 'FAIL'}] + [{'decision': 'PASS'} for _ in range(9)]) as execute:
                result = gate.fuzz_gate(self.runner(root), root / 'candidate.tar.gz',
                                        PAYLOADS['candidate.tar.gz'], {})
        self.assertEqual(execute.call_count, 10)
        self.assertEqual(result['status'], 'FAIL')

    def test_fuzz_overlay_uses_its_own_extraction(self):
        with self.temporary() as directory:
            root = Path(directory)
            touched = []

            def fake_overlay(source, installed, targets):
                touched.append(installed)
                write_tree(installed, {'fuzz/corpus/added.hex': b'00\n'})
                return {}

            with patch.object(gate.release, 'extract_archive', side_effect=fake_extract), \
                 patch.object(gate, 'overlay', side_effect=fake_overlay), \
                 patch.object(gate.fuzz, 'execute_target', return_value={'decision': 'PASS'}):
                gate.fuzz_gate(self.runner(root), root / 'candidate.tar.gz', PAYLOADS['candidate.tar.gz'], {})
            self.assertEqual(len(touched), 1)
            self.assertEqual(touched[0].parent.name, 'fuzz-candidate')
            # The fuzz-era additions live only in the fuzz extraction.
            self.assertTrue((touched[0] / 'fuzz/corpus/added.hex').is_file())

    def test_original_markers_reject_skip(self):
        with self.temporary() as directory:
            path = Path(directory) / 'out'
            path.write_text('NATIVE_TLS_VERSIONS=PASS\nSKIP\n')
            with self.assertRaisesRegex(RuntimeError, 'skipped'):
                gate.tls.require_marker(path, 'versions12')

    def test_nested_tls_log_digest_rebound_after_normalization(self):
        with self.temporary() as directory:
            output = Path(directory)
            log = output / 'consumer-decrypt.stdout.log'
            log.write_text('normalized output\n')
            report = {'commands': [], 'scenario': {'stdout': {'path': log.name, 'digest': {'domain': 'text-utf8-lf-v1', 'sha256': '0' * 64}}}}
            runner = unittest.mock.Mock(output=output)
            runner.redact = lambda text: text
            gate.write_report(output / 'report.json', report, runner)
            self.assertEqual(report['scenario']['stdout']['digest'], gate.d.text_evidence_digest(log).to_json())


if __name__ == '__main__':
    unittest.main()

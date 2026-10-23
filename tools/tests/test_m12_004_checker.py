"""The archived Server checker reports withheld inputs as blocked, not broken."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools.evidence_digest import text_evidence_digest
from tools.repository import repository_tooling as tooling


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / 'docs/evidence/M12-004/repaired-server-performance/checker/check.py'
BASE = ROOT / 'docs/evidence/M12-004/repaired-server-performance'
INPUT = BASE / 'input'


class CheckerTests(unittest.TestCase):
    def test_withheld_archives_are_reported_as_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'verification.json'
            result = subprocess.run(
                [sys.executable, '-B', str(CHECKER), '--output', str(output)],
                cwd=ROOT, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            report = json.loads(output.read_text())
            self.assertEqual(report['verification_status'], 'BLOCKED')
            self.assertEqual(report['performance_status'], 'NOT_VERIFIED')
            self.assertEqual(
                report['blockers'],
                ['required evidence archives unavailable: baseline.tar.gz, candidate.tar.gz'],
            )

    def test_repaired_input_bundle_matches_the_capture_manifest(self):
        manifest = json.loads((BASE / 'input-manifest.json').read_text())
        self.assertTrue(INPUT.is_dir())
        for name, expected in manifest['source_inputs'].items():
            with self.subTest(source=name):
                path = INPUT / 'repo' / name
                self.assertTrue(path.is_file())
                self.assertEqual(text_evidence_digest(path).to_json(), expected)
        self.assertEqual(json.loads((INPUT / 'inputs.json').read_text()), manifest)
        self.assertEqual(text_evidence_digest(INPUT / 'sdk-oracle.json').to_json(), manifest['sdk_oracle'])
        self.assertEqual(set(json.loads((INPUT / 'glibc244/provenance.json').read_text())['files']),
                         set(manifest['prerequisite_environment_metadata']['glibc_file_modes']))

    def test_checker_resolves_the_repaired_input_bundle(self):
        # Import the checker module without running its main; it must select the repaired
        # durable bundle, not the pre-repair server-performance snapshot.
        script = (
            "import importlib.util, sys\n"
            "spec = importlib.util.spec_from_file_location('archived_checker', sys.argv[1])\n"
            "module = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(module)\n"
            "print(module.INPUT)\n"
        )
        result = subprocess.run([sys.executable, '-B', '-c', script, str(CHECKER)],
                                cwd=ROOT, capture_output=True, text=True, check=True)
        self.assertEqual(Path(result.stdout.strip()).resolve(), INPUT.resolve())


TASK_MANIFEST = 'tools/tasks/M12-004.json'


class ManifestSourceBindingTests(unittest.TestCase):
    """The task manifest must hash itself, so edits invalidate sealed evidence."""

    def test_task_manifest_is_in_its_own_source_inventory(self):
        task = json.loads((ROOT / TASK_MANIFEST).read_text())
        self.assertIn(TASK_MANIFEST, task['source_paths'])
        self.assertEqual(len(task['source_paths']), len(set(task['source_paths'])))

    def test_manifest_edit_drift_is_reported_against_the_manifest_path(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ManifestFixture(Path(directory))
            self.assertEqual('PASS', fixture.verify()['status'])
            fixture.edit_manifest()
            report = fixture.verify()
            self.assertEqual('STALE', report['status'])
            self.assertEqual(
                [{'code': 'DIGEST_STALE', 'detail': fixture.manifest_path}],
                report['tasks'][0]['issues'])

    def test_manifest_omitted_from_the_inventory_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ManifestFixture(Path(directory))
            fixture.evidence['source_sha256'].pop(fixture.manifest_path)
            fixture.write_evidence()
            report = fixture.verify()
            self.assertEqual('FAIL', report['status'])
            self.assertEqual('SOURCE_INVENTORY', report['tasks'][0]['issues'][0]['code'])
            self.assertIn('does not match manifest', report['tasks'][0]['issues'][0]['detail'])

    def test_sealed_evidence_records_the_manifest_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ManifestFixture(Path(directory))
            sealed = fixture.seal()
            self.assertIn(fixture.manifest_path, sealed['source_sha256'])
            self.assertEqual(text_evidence_digest(fixture.root / fixture.manifest_path).to_json(),
                             sealed['source_sha256'][fixture.manifest_path])


class ManifestFixture:
    """A throwaway repository with one task that hashes its own manifest."""

    manifest_path = 'tools/tasks/TEST-004.json'

    def __init__(self, root: Path):
        self.root = root
        (root / 'tools/tasks').mkdir(parents=True)
        (root / 'docs/planning').mkdir(parents=True)
        (root / 'docs/evidence/TEST-004').mkdir(parents=True)
        (root / 'source.txt').write_text('current\n')
        rows = '| TEST-004 | task | source | condition |\n'
        (root / 'docs/planning/implementation-backlog.md').write_text(rows)
        (root / 'docs/planning/status.md').write_text(
            '| TEST-004 | IN_PROGRESS | evidence | note |\n')
        (root / 'docs/evidence/TEST-004/report.json').write_text(
            json.dumps({'status': 'PASS', 'source_task': 'TEST-004'}))
        self.manifest = {
            'schema_version': 1, 'task_id': 'TEST-004', 'dependencies': [],
            'allowed_paths': ['tools/tasks', 'source.txt'],
            'platforms': ['linux-x86_64-glibc'],
            'acceptance_commands': [{'id': 'unit', 'argv': ['python3', '-c', 'pass'],
                                     'timeout_seconds': 10, 'long_running': False, 'gate': 'task'}],
            'required_evidence': ['docs/evidence/TEST-004/evidence.json',
                                  'docs/evidence/TEST-004/report.json'],
            'timeout_seconds': 60, 'long_running_gate': False,
            'source_paths': ['source.txt', self.manifest_path],
        }
        self.write_manifest()
        self.git('init', '--quiet')
        self.git('config', 'core.hooksPath', str(root / 'disabled-hooks'))
        self.git('config', 'user.name', 'Wirestack Test')
        self.git('config', 'user.email', 'wirestack-test@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('add', '--force', 'source.txt', self.manifest_path,
                 'docs/evidence/TEST-004/report.json')
        self.git('commit', '--quiet', '-m', 'fixture')
        self.revision = self.git('rev-parse', 'HEAD').stdout.strip()
        self.evidence = {
            'schema_version': 2, 'source_task': 'TEST-004',
            'platform': tooling.platform_identity(),
            'toolchain': tooling.toolchain_identity(root),
            'acceptance_status': 'PASS', 'generated_at_utc': tooling.utc_now(),
            'revision': self.revision,
            'reports': [{'path': 'docs/evidence/TEST-004/report.json',
                         'sha256': text_evidence_digest(root / 'docs/evidence/TEST-004/report.json').to_json(),
                         'source_task': 'TEST-004', 'acceptance_status': 'PASS'}],
            'source_sha256': {name: text_evidence_digest(root / name).to_json()
                              for name in self.manifest['source_paths']},
        }
        self.write_evidence()

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.root, capture_output=True, text=True,
                              timeout=10, check=True)

    def write_manifest(self):
        path = self.root / self.manifest_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.manifest, indent=2))

    def edit_manifest(self):
        changed = dict(self.manifest, timeout_seconds=61)
        self.manifest = changed
        self.write_manifest()

    def write_evidence(self):
        (self.root / 'docs/evidence/TEST-004/evidence.json').write_text(json.dumps(self.evidence))

    def verify(self):
        return tooling.verify(self.root, 'TEST-004')

    def seal(self):
        return tooling.seal_evidence(
            self.root, 'TEST-004', ['docs/evidence/TEST-004/report.json'],
            self.root / 'docs/evidence/TEST-004/sealed-evidence.json', self.revision)


if __name__ == '__main__':
    unittest.main()

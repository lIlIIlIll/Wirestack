"""The archived Server checker reports withheld inputs as blocked, not broken."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools.evidence_digest import text_evidence_digest


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


if __name__ == '__main__':
    unittest.main()

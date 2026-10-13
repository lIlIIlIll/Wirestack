"""The archived Server checker reports withheld inputs as blocked, not broken."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / 'docs/evidence/M12-004/repaired-server-performance/checker/check.py'


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


if __name__ == '__main__':
    unittest.main()

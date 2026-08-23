from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import codex_fleet_core as fleet  # noqa: E402

SAMPLE = """
| ID | 任务 | 责任域 | 复杂度 | 依赖 | PRD 追踪 | 合并/验收条件 |
|---|---|---|---:|---|---|---|
| M0-001 | inventory | architecture | C1 | — | P | A |
| M0-002 | layout | architecture | C1 | M0-001 | P | A |
| M0-003 | guard | infra | C1 | M0-002 | P | A |
| M0-004 | gates | test | C1 | M0-001 | P | A |
| M0-005 | baseline | perf | C1 | M0-004 | P | A |
| M0-006 | close | test | C1 | M0-004 | P | A |
| M0-007 | race | test | C1 | M0-004 | P | A |
| M0-008 | deadline | test | C1 | M0-004 | P | A |
| M0-009 | eof | test | C1 | M0-004 | P | A |
| M0-010 | copy | perf | C1 | M0-005 | P | A |
| M0-011 | soak | reliability | C1 | M0-004 | P | A |
| M0-012 | mobile | platform | C1 | M0-004 | P | A |
| M0-013 | dns | perf | C1 | M0-004 | P | A |
| M0-014 | windows | platform | C1 | M0-005 | P | A |
| M0-015 | provider | security | C1 | M0-001 | P | A |
| M0-016 | provider poc | security | C1 | M0-015 | P | A |
| M0-019 | transport rfc | architecture | C1 | M0-006..M0-014 | P | A |
| M1-001 | transport skeleton | architecture | C1 | M0-019 | P | A |
| M1-002 | span | core | C1 | M1-001 | P | A |
| M2-001 | endpoint | core | C1 | M1-001 | P | A |
| M7-001 | audit | quality | C1 | M1..M2 | P | A |
"""

class FleetTests(unittest.TestCase):
    def tasks(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name) / "backlog.md"
        path.write_text(SAMPLE, encoding="utf-8")
        return fleet.parse_backlog(path)

    def state(self):
        return {"schema_version": 1, "completed": [f"M0-{i:03d}" for i in range(1, 8)],
                "blocked": {}, "branch_overrides": {}, "issue_numbers": {}}

    def test_range_expansion(self):
        tasks = self.tasks()
        self.assertEqual({f"M0-{i:03d}" for i in range(6, 15)},
                         set(tasks["M0-019"].dependencies))
        self.assertEqual({"M1-001", "M1-002", "M2-001"},
                         set(tasks["M7-001"].dependencies))

    def test_ready_wave(self):
        self.assertEqual([f"M0-{i:03d}" for i in range(8, 16)],
                         [task.task_id for task in fleet.ready_tasks(self.tasks(), self.state())])

    def test_blocked_excluded(self):
        state = self.state()
        state["blocked"] = {"M0-012": "no device"}
        self.assertNotIn("M0-012", [t.task_id for t in fleet.ready_tasks(self.tasks(), state)])

    def test_prompt_boundaries(self):
        prompt = fleet.render_prompt(self.tasks()["M0-008"], "task/M0-008", 13)
        self.assertIn("GitHub issue: #13", prompt)
        self.assertIn("with-host-gate-lock", prompt)
        self.assertIn("docs/planning/status.md", prompt)
        self.assertIn("docs/evidence/M0-008/", prompt)

    def test_atomic_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            fleet.atomic_write_json(path, {"schema_version": 1, "completed": ["M0-001"]})
            self.assertEqual(["M0-001"], json.loads(path.read_text())["completed"])

if __name__ == "__main__":
    unittest.main()

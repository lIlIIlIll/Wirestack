from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EXPECTED_IDS = {f"M7-{number:03d}" for number in range(18, 34)}


class M7LinuxTaskGraphTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def linux_rows(self) -> dict[str, list[str]]:
        backlog = self.read("docs/planning/implementation-backlog.md")
        section = backlog.split("## 5.9 M7：Linux glibc 稳定版收口", 1)[1]
        section = section.split("## 6. 远期上游增强", 1)[0]
        rows = {}
        for line in section.splitlines():
            if not line.startswith("| M7-"):
                continue
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            rows[cells[0]] = cells
        return rows

    def test_linux_graph_has_the_exact_frozen_task_set(self) -> None:
        rows = self.linux_rows()
        self.assertEqual(EXPECTED_IDS, set(rows))
        self.assertTrue(all(len(cells) == 7 for cells in rows.values()))

    def test_linux_dependencies_exclude_global_and_upstream_blockers(self) -> None:
        for task_id, cells in self.linux_rows().items():
            dependencies = cells[4]
            self.assertNotIn("M1-026", dependencies, task_id)
            self.assertNotIn("M4", dependencies, task_id)
            self.assertNotIn("UP-", dependencies, task_id)

    def test_task_graph_has_fail_closed_audit_and_release_edges(self) -> None:
        rows = self.linux_rows()
        self.assertEqual("M7-018", rows["M7-019"][4])
        self.assertEqual("M7-019..M7-030,M7-032", rows["M7-031"][4])
        self.assertEqual("M7-026,M7-027", rows["M7-032"][4])
        self.assertIn("M7-032 和 M7-029 后", rows["M7-022"][6])
        self.assertIn("22 条发布验收", rows["M7-019"][6])
        self.assertIn("NOT_APPLICABLE_TO_LINUX_PROFILE", rows["M7-019"][6])
        self.assertIn("任一 Linux P0 FAIL", rows["M7-031"][6])

    def test_task_counts_include_linux_profile_and_formal_follow_up_work(self) -> None:
        backlog = self.read("docs/planning/implementation-backlog.md")
        milestone_ids = set(re.findall(r"^\| (M\d+-\d{3}) \|", backlog, re.MULTILINE))
        upstream_ids = set(re.findall(r"^\| (UP-\d{3}) \|", backlog, re.MULTILINE))
        p1_ids = set(re.findall(r"^\| (P1-\d{3}) \|", backlog, re.MULTILINE))
        self.assertEqual(201, len(milestone_ids))
        self.assertEqual(185, len(milestone_ids - EXPECTED_IDS))
        self.assertEqual(7, len(upstream_ids))
        self.assertEqual(14, len(p1_ids))
        self.assertIn("**全平台主线任务数：** 185", backlog)
        self.assertIn("**Linux 稳定版收口任务数：** 16", backlog)
        self.assertIn("**当前发布任务数：** 201", backlog)
        self.assertIn("当前发布相关任务总数：**201**", backlog)
        self.assertIn("全部已记录任务总数：**222**", backlog)




if __name__ == "__main__":
    unittest.main()

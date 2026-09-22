from __future__ import annotations

import re
import sys
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import codex_fleet_core as fleet  # noqa: E402


PUBLISHED_COUNT_RE = re.compile(
    r"^(?:\*\*(?P<header>[^*]+?)：\*\*\s*|-\s+(?P<summary>[^：]+)：\*\*)"
    r"(?P<count>\d+)"
)
TASK_REFERENCE_RE = re.compile(r"\b(?:M\d+|P1)-\d{3}\b")
EXPECTED_M7_IDS = {f"M7-{number:03d}" for number in range(18, 34)}
EVOLUTION_IDS = (
    "M9-001",
    "M9-002",
    "M9-003",
    "M10-001",
    "M10-002",
    "M10-003",
    "M10-004",
    "M10-005",
    "M11-001",
    "M11-002",
    "M11-003",
    "M11-004",
    "M12-001",
    "M12-002",
    "M12-003",
    "M12-004",
)
EXPECTED_EVOLUTION_DEPENDENCIES = {
    "M9-001": {"P1-015"},
    "M9-002": {"M9-001"},
    "M9-003": {"M9-002"},
    "M10-001": {"M9-001"},
    "M10-002": {"M9-001"},
    "M10-003": {"M10-001", "M10-002"},
    "M10-004": {"M10-003"},
    "M10-005": {"M9-001"},
    "M11-001": {"M9-001"},
    "M11-002": {"M9-001"},
    "M11-003": {"M9-001"},
    "M11-004": {"M9-001"},
    "M12-001": {"M9-001"},
    "M12-002": {"M9-001"},
    "M12-003": {"M9-001"},
    "M12-004": {"M9-001"},
}


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

    def evolution_rows(self) -> dict[str, list[str]]:
        backlog = self.read("docs/planning/implementation-backlog.md")
        section = backlog.split("## 6.1 M9–M12：Linux 后续演进", 1)[1]
        section = section.split("### 当前开发的前置规则", 1)[0]
        rows = {}
        for line in section.splitlines():
            if not line.startswith("| M"):
                continue
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            rows[cells[0]] = cells
        return rows

    def evolution_status_rows(self) -> dict[str, list[str]]:
        status = self.read("docs/planning/status.md")
        section = status.split("## M9–M12 Linux evolution", 1)[1]
        rows = {}
        for line in section.splitlines():
            if not line.startswith("| M"):
                continue
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            rows[cells[0]] = cells
        return rows

    def task_ids(self) -> list[str]:
        task_ids = []
        for line in self.read("docs/planning/implementation-backlog.md").splitlines():
            if not line.startswith("|"):
                continue
            first_cell = line.strip().strip("|").split("|", 1)[0].strip()
            if fleet.TASK_ID_RE.fullmatch(first_cell):
                task_ids.append(first_cell)
        return task_ids

    def published_counts(self) -> dict[str, int]:
        counts = {}
        for line in self.read("docs/planning/implementation-backlog.md").splitlines():
            match = PUBLISHED_COUNT_RE.match(line)
            if match is None:
                continue
            label = match.group("header") or match.group("summary")
            self.assertNotIn(label, counts, f"duplicate published count: {label}")
            counts[label] = int(match.group("count"))
        return counts

    def test_linux_graph_has_the_exact_frozen_task_set(self) -> None:
        rows = self.linux_rows()
        self.assertEqual(EXPECTED_M7_IDS, set(rows))
        self.assertTrue(all(len(cells) == 7 for cells in rows.values()))

    def test_evolution_graph_has_unique_issues_dependencies_and_acceptance(self) -> None:
        rows = self.evolution_rows()
        self.assertEqual(set(EVOLUTION_IDS), set(rows))
        self.assertTrue(all(len(cells) == 7 for cells in rows.values()))

        completion_conditions = set()
        for issue_number, task_id in enumerate(EVOLUTION_IDS, start=170):
            cells = rows[task_id]
            self.assertEqual(
                f"[#{issue_number}](https://github.com/lIlIIlIll/Wirestack/issues/{issue_number})",
                cells[1],
            )
            self.assertEqual(
                EXPECTED_EVOLUTION_DEPENDENCIES[task_id],
                set(TASK_REFERENCE_RE.findall(cells[5])),
                task_id,
            )
            self.assertNotIn("UP-", cells[5], task_id)
            self.assertTrue(cells[6], task_id)
            completion_conditions.add(cells[6])
        self.assertEqual(len(EVOLUTION_IDS), len(completion_conditions))

    def test_evolution_status_matches_readiness_classification(self) -> None:
        backlog_rows = self.evolution_rows()
        rows = self.evolution_status_rows()
        self.assertEqual(set(EVOLUTION_IDS), set(rows))
        self.assertTrue(all(len(cells) == 4 for cells in rows.values()))
        all_status = {}
        for line in self.read("docs/planning/status.md").splitlines():
            if line.startswith("| "):
                cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
                if len(cells) >= 2:
                    all_status[cells[0]] = cells[1]
        for task_id, cells in rows.items():
            self.assertIn(backlog_rows[task_id][1], cells[2], task_id)
            self.assertIn(cells[1], {"READY", "IN_PROGRESS", "BLOCKED", "COMPLETE"})
            if cells[1] != "BLOCKED":
                for dependency in EXPECTED_EVOLUTION_DEPENDENCIES[task_id]:
                    self.assertEqual("COMPLETE", all_status[dependency], task_id)

    def test_task_counts_include_linux_profile_and_formal_follow_up_work(self) -> None:
        declared_ids = self.task_ids()
        occurrences = Counter(declared_ids)
        duplicates = {
            task_id: count for task_id, count in occurrences.items() if count != 1
        }
        self.assertEqual({}, duplicates)

        unique_ids = set(declared_ids)
        linux_ids = set(self.linux_rows())
        evolution_ids = set(self.evolution_rows())
        m8_ids = {task_id for task_id in unique_ids if task_id.startswith("M8-")}
        release_ids = {task_id for task_id in unique_ids if task_id.startswith("M")}
        mainline_ids = release_ids - linux_ids - m8_ids - evolution_ids
        upstream_ids = {
            task_id for task_id in unique_ids if task_id.startswith("UP-")
        }
        p1_ids = {task_id for task_id in unique_ids if task_id.startswith("P1-")}

        self.assertEqual(unique_ids, release_ids | upstream_ids | p1_ids)

        derived_counts = {
            "全平台主线任务数": len(mainline_ids),
            "Linux 稳定版收口任务数": len(linux_ids),
            "Linux 后续演进任务数": len(evolution_ids),
            "远期上游任务数": len(upstream_ids),
            "当前发布任务数": len(release_ids),
            "全平台主线任务": len(mainline_ids),
            "Linux 稳定版收口任务": len(linux_ids),
            "Linux 网络底座任务": len(m8_ids),
            "Linux 后续演进任务": len(evolution_ids),
            "远期上游任务": len(upstream_ids),
            "稳定版后 P1/独立项目": len(p1_ids),
            "当前发布相关任务总数": len(release_ids),
            "全部已记录任务总数": len(unique_ids),
        }
        published_counts = self.published_counts()
        for label, derived_count in derived_counts.items():
            self.assertIn(label, published_counts)
            self.assertEqual(
                derived_count,
                published_counts[label],
                f"{label} does not match declared unique task IDs",
            )

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
        self.assertTrue(all(cells[6] for cells in rows.values()))


if __name__ == "__main__":
    unittest.main()

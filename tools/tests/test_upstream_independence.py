from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
BACKLOG = ROOT / "docs/planning/implementation-backlog.md"


class UpstreamIndependenceTest(unittest.TestCase):
    def test_current_tasks_do_not_depend_on_upstream_candidates(self) -> None:
        for line in BACKLOG.read_text(encoding="utf-8").splitlines():
            if re.match(r"^\| M\d+-\d{3} \|", line) is None:
                continue
            columns = [column.strip() for column in line.split("|")[1:-1]]
            self.assertGreaterEqual(len(columns), 5, line)
            dependency_column = columns[4]
            self.assertNotIn("UP-", dependency_column, line)

    def test_issue_template_marks_upstream_candidates_as_optional(self) -> None:
        backlog = BACKLOG.read_text(encoding="utf-8")
        self.assertIn(
            "关联的远期上游候选（非依赖，可选）：<UP-ID 或无>",
            backlog,
        )
        self.assertNotIn("上游任务：<依赖 ID>", backlog)
        self.assertNotIn("阻断的里程碑：<M0–M7>", backlog)


if __name__ == "__main__":
    unittest.main()

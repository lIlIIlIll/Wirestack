from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class LinuxProfileScopeTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_prd_defers_musl_and_requires_glibc(self) -> None:
        prd = self.read("docs/product/prd.md")
        self.assertIn("| Linux glibc | 必须 | 必须 | 必须 | 必须 |", prd)
        self.assertIn("| Linux musl | 延后 | 延后 | 延后 | 延后 |", prd)

    def test_active_backlog_uses_glibc_and_future_task_owns_musl(self) -> None:
        backlog = self.read("docs/planning/implementation-backlog.md")
        self.assertIn("| M2-005 | 实现 Linux glibc SystemResolver |", backlog)
        self.assertIn("| M3-013 | 实现 Linux glibc system trust adapter |", backlog)
        self.assertIn("| P1-011 | Linux musl 采纳 |", backlog)
        m7004 = next(line for line in backlog.splitlines() if line.startswith("| M7-004 |"))
        self.assertIn("Linux glibc", m7004)
        self.assertNotIn("musl", m7004)

    def test_linux_status_closes_glibc_tasks_without_claiming_musl(self) -> None:
        status = self.read("docs/planning/linux-status.md")
        m2005 = next(line for line in status.splitlines() if line.startswith("| M2-005 "))
        m3013 = next(line for line in status.splitlines() if line.startswith("| M3-013 "))
        self.assertIn("| COMPLETE |", m2005)
        self.assertIn("| COMPLETE |", m3013)
        self.assertIn("ADR-0004", m2005)
        self.assertIn("ADR-0004", m3013)

    def test_accepted_adr_defines_the_sdk_trigger(self) -> None:
        adr = self.read("docs/architecture/adr/0004-linux-glibc-support.md")
        self.assertIn("- Status: Accepted", adr)
        self.assertIn("P1-011", adr)
        self.assertIn("supported musl target, standard", adr)


if __name__ == "__main__":
    unittest.main()

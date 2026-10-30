# M9-001 dependency status capture

- Command: `python3 tools/repository/repository_tooling.py --root . check task M9-001 --json`
- Exit code: `2`
- Base: draft PR #247 head `7ec86d2993081b319e7fabcd5efacdddce22af78`; the M9-001 row was reclassified in the working tree before this check.
- Result: `INVALID` (`DEPENDENCY_INCOMPLETE`); the command returned `commands: []`, so M9-001 acceptance commands did not run.
- Interpretation: M9-001 depends on P1-015, now BLOCKED by its P1 prerequisite chain. Existing M9-001 source-bound acceptance evidence is preserved, not refreshed.

```json
{
  "commands": [],
  "issues": [
    {
      "code": "DEPENDENCY_INCOMPLETE",
      "detail": "M9-001 dependency is not COMPLETE: P1-015"
    }
  ],
  "kind": "repository-check",
  "mode": "task",
  "schema_version": 1,
  "status": "INVALID",
  "task_id": "M9-001"
}
```

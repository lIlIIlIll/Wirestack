# M10-005 dependency status capture

- Command: `python3 tools/repository/repository_tooling.py --root . check task M10-005 --json`
- Exit code: `2`
- Base: draft PR #250 head `63dc602b14d23f66e0128a57051570ce92c02161`; the M10-005 row was reclassified in the working tree before this check.
- Result: `INVALID` (`DEPENDENCY_INCOMPLETE`); the command returned `commands: []`, so M10-005 acceptance commands did not run.
- Interpretation: M10-005 depends on M9-001, now BLOCKED by P1-015. Existing Linux event/resource acceptance evidence is preserved, not refreshed.

```json
{
  "commands": [],
  "issues": [
    {
      "code": "DEPENDENCY_INCOMPLETE",
      "detail": "M10-005 dependency is not COMPLETE: M9-001"
    }
  ],
  "kind": "repository-check",
  "mode": "task",
  "schema_version": 1,
  "status": "INVALID",
  "task_id": "M10-005"
}
```

# M9-002 dependency status capture

- Command: `python3 tools/repository/repository_tooling.py --root . check task M9-002 --json`
- Exit code: `2`
- Base: draft PR #248 head `904d95df7d7ada489b204c1ae1a0cc9fe6e85805`; the M9-002 row was reclassified in the working tree before this check.
- Result: `INVALID` (`DEPENDENCY_INCOMPLETE`); the command returned `commands: []`, so M9-002 acceptance commands did not run.
- Interpretation: Dependency validation rejects M9-001 because P1-015 is BLOCKED. Existing M9-002 source-bound Linux option evidence is preserved, not refreshed.

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
  "task_id": "M9-002"
}
```

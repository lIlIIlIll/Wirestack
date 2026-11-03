# P1-014 dependency status capture

- Command: `python3 tools/repository/repository_tooling.py --root . check task P1-014 --json`
- Exit code: `2`
- Base: draft PR #243 head `62605b77020b51e94e03cfd251112202f068ff69`; the P1-014 row was reclassified in the working tree before this check.
- Result: `INVALID` (`DEPENDENCY_INCOMPLETE`); the command returned `commands: []`, so P1-014 acceptance commands did not run.
- Interpretation: Dependency validation rejects P1-013 because its P1-012 prerequisite is BLOCKED. Existing digest-domain acceptance evidence is retained but does not establish current readiness.

```json
{
  "commands": [],
  "issues": [
    {
      "code": "DEPENDENCY_INCOMPLETE",
      "detail": "P1-013 dependency is not COMPLETE: P1-012"
    }
  ],
  "kind": "repository-check",
  "mode": "task",
  "schema_version": 1,
  "status": "INVALID",
  "task_id": "P1-014"
}
```

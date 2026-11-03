# P1-012 test results

The final retained machine reports are:

- `task-check.json`: repository plan validation and fault-injection unit tests.
- `full-check.json`: the existing `scripts/check` suite through `check-full`.
- `evidence.json`: source and report digest index.
- `freshness.json`: single-task evidence freshness result.

## Results

| Command | Result |
|---|---|
| External plan matrix validator | PASS; P=18, S=12, T=10 |
| Repository plan validator | PASS; 16 path rows, 12 scenarios, 10 tests |
| Repository tooling fault-injection tests | PASS; 16/16 |
| `scripts/check-fast --json` | PASS; one non-long contract command |
| `scripts/check-long P1-012 --json` | SKIPPED; exit 4; zero commands |
| `scripts/check-task P1-012 --json` | PASS; two non-long commands |
| `scripts/check-full --json` | PASS; 99 repository, 131 gate and 23 benchmark tests; architecture/CJPM check/build PASS; 554 Cangjie tests passed and 22 Performance tests skipped |
| `scripts/verify-evidence P1-012 --json` | PASS after evidence seal |

No long-duration command ran. The first full check correctly detected that the
new backlog row changed three retained M7 planning fingerprints. Those three
digest fields were refreshed to the current backlog bytes; no M7 decision,
measurement, product artifact, or status changed.

The first sandboxed Cangjie run could not create the unittest transport socket
and returned `Operation not permitted`. The identical full command passed in
the authorized environment. Product code was not changed to accommodate the
sandbox restriction.

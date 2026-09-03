# M0-025 test results

## Local Linux control-plane checks

| Command | Result |
|---|---|
| `python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M0-025/test-plan.md --json` | PASS; 9 paths, 8 scenarios, 7 tests |
| `python3 -m unittest tools.gates.tests.test_m0_025_windows_resource_diagnostics tools.gates.tests.test_m0_011_windows_long -v` | PASS; 20/20 |
| `scripts/check-fast --json` | PASS |
| `scripts/check` | PASS; 611 total, 588 PASS, 23 SKIPPED, 0 ERROR, 0 FAILED |
| `scripts/check-task M0-025 --json` | PASS; plan, regression, fast, and canonical checks all passed |

No SDK, runtime, `std`, or `stdx` build was run.

## Native Windows rerun

GitHub Actions run `33733198358` used exact head
`b33f00e05af08ba45e0e07936fcc270cd36b7937` on `windows-2025` / AMD64 with
Cangjie `1.3.0-alpha.20260902010013` and cjpm `1.3.0-alpha.03`.

- Bounded mode-isolation diagnostics: job step PASS, report status INCOMPLETE.
  Each 60-second mode reached its timeout before emitting a RESULT; no mode is
  treated as a workload PASS.
- M0-011 native four-hour profile: process exit 0 and workload PASS after
  `14,400` seconds, but resource decision FAIL.
- Resource result: handle growth `146 > 8`; private-byte growth
  `65,368 KiB > 8,192 KiB`; RSS growth `28 KiB`, thread growth `0`, and socket
  growth `0` were within limits.
- Exact-revision validation: FAIL with `STATUS`, because the source report is
  correctly marked FAIL.

The workflow did not run the 24-hour Linux soak, one-hour SSE profile, mobile
gate, or any non-Windows native gate.

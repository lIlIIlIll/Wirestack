# M0-025 evidence: Windows resource-growth diagnosis

## Status

M0-025 is registered and approved as an independent Windows resource-growth
diagnosis and repair task. It is currently **BLOCKED**. Its entry evidence is the
failed native M0-011 run `33705670217`, which completed four hours but reported
handle growth of `127` over the limit `8` and private-byte growth of `65,704 KiB`
over the limit `8,192 KiB`.

The first approved workflow run used exact revision
`b33f00e05af08ba45e0e07936fcc270cd36b7937` (GitHub run `33733198358`) and
correctly retained four incomplete 60-second probes plus the failed four-hour
profile. The budget was then corrected so iteration count is explicit rather
than derived from the timeout. The complete diagnostic-only run used exact
revision `7e5252c55fdad5b1523641758d86260be3a17091` (GitHub run
`33826513099`), with a 600-second mode timeout, one-second sampling, and
per-mode budgets of 65,536 for `connect-close` and 16,384 for each other mode.

All four modes emitted a complete RESULT without a timeout. `peer-reset` passed
its workload and resource trend. `close-during-read` reproduced handle growth
of `29 > 8`; `echo-close` had one sampler `THREAD_QUERY` error; and
`connect-close` completed its budget but returned a non-zero probe status after
49,278 connection errors. The diagnostic report is therefore FAIL, not PASS.
The executable is still the public `std.net` probe, so no Wirestack-owned repair
is proven; the mode-level result is evidence for a suspected public
`std.net`/runtime ownership candidate, not a confirmed upstream root cause.

## Scope

- Windows x86_64 on the GitHub `windows-2025` runner.
- Short, bounded mode-isolation diagnostics before the four-hour gate.
- Explicit per-mode budgets and enough sampling to produce complete reports.
- Existing resource limits remain unchanged.
- Structured reports stay bound to the exact source revision and toolchain.
- The fresh native rerun is retained even though its resource decision is FAIL.

## Non-goals

- No runtime, `std`, `stdx`, SDK, or Cangjie toolchain changes.
- No system OpenSSL, private runtime ABI, or platform-specific workaround.
- No threshold increase, sampler weakening, process splitting, or evidence
  promotion after a timeout or incomplete workload.
- No 24-hour soak, SSE profile, or non-Windows native gate.

The task does not patch a sibling repository or claim that M0-011 passed. A
separately reviewed upstream candidate may be opened only after a correctly
budgeted mode-isolation run produces complete results.

## Evidence files

The retained evidence includes:

- `diagnostic-results.json`, one bounded result per workload mode;
- `repair-decision.json`, the source-bound repair decision;
- `native-rerun.json`, the exact M0-011 four-hour result and digest;
- `native-rerun-source.json` and `native-rerun-validation.json`, the retained
  raw report and validator output;
- `task-check.json`, the machine-readable task gate result;
- `evidence.json`, a BLOCKED evidence index. The repository freshness verifier
  must reject it until all required reports provide PASS; and
- `evidence-validation.json`, the expected fail-closed freshness result;
- `test-results.md`, the bounded local and native command summary.

The test matrix is in [`test-plan.md`](test-plan.md).

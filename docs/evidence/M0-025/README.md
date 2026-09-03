# M0-025 evidence: Windows resource-growth diagnosis

## Status

M0-025 is registered and approved as an independent Windows resource-growth
diagnosis and repair task. It is currently **BLOCKED**. Its entry evidence is the
failed native M0-011 run `33705670217`, which completed four hours but reported
handle growth of `127` over the limit `8` and private-byte growth of `65,704 KiB`
over the limit `8,192 KiB`.

The approved workflow ran four bounded mode probes and then one fresh M0-011
four-hour native profile at exact revision
`b33f00e05af08ba45e0e07936fcc270cd36b7937` (GitHub run `33733198358`). The
probes all timed out before their bounded `RESULT`, so they are retained as
INCOMPLETE rather than promoted to PASS. The four-hour workload completed, but
the resource gate still failed: handle growth was `146` and private-byte growth
was `65,368 KiB`; RSS, thread, and socket growth stayed within their limits.
No Wirestack-owned repair is proven. The tested executable is the public
`std.net` probe, so the current classification is a suspected public
`std.net`/runtime ownership issue with insufficient mode-level attribution.

## Scope

- Windows x86_64 on the GitHub `windows-2025` runner.
- Short, bounded mode-isolation diagnostics before the four-hour gate.
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

The final run will add:

- `diagnostic-results.json`, one bounded result per workload mode;
- `repair-decision.json`, the source-bound repair decision;
- `native-rerun.json`, the exact M0-011 four-hour result and digest;
- `native-rerun-source.json` and `native-rerun-validation.json`, the retained
  raw report and validator output;
- `task-check.json`, the machine-readable task gate result;
- `evidence.json`, a BLOCKED evidence index. The repository freshness verifier
  must reject it until all required reports provide PASS; and
- `test-results.md`, the bounded local and native command summary.

The test matrix is in [`test-plan.md`](test-plan.md).

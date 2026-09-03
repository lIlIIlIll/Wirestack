# M0-025 evidence: Windows resource-growth diagnosis

## Status

M0-025 is registered and approved as an independent Windows resource-growth
diagnosis and repair task. It is currently **IN_PROGRESS**. Its entry evidence is the
failed native M0-011 run `33705670217`, which completed four hours but reported
handle growth of `127` over the limit `8` and private-byte growth of `65,704 KiB`
over the limit `8,192 KiB`.

The task will separate the four workload modes into bounded native diagnostic
runs, identify whether growth follows a Wirestack-controlled probe path or the
public Cangjie socket implementation, and apply a repair only when the cause is
inside this repository. A fresh M0-011 four-hour native profile follows the
diagnostic and repair decision.

## Scope

- Windows x86_64 on the GitHub `windows-2025` runner.
- Short, bounded mode-isolation diagnostics before the four-hour gate.
- Existing resource limits remain unchanged.
- Structured reports stay bound to the exact source revision and toolchain.

## Non-goals

- No runtime, `std`, `stdx`, SDK, or Cangjie toolchain changes.
- No system OpenSSL, private runtime ABI, or platform-specific workaround.
- No threshold increase, sampler weakening, process splitting, or evidence
  promotion after a timeout or incomplete workload.
- No 24-hour soak, SSE profile, or non-Windows native gate.

If the diagnostic isolates an upstream `std.net` or runtime defect, this task
records the evidence and remains BLOCKED. It does not patch a sibling
repository or claim that M0-011 passed.

## Evidence files

The final run will add:

- `diagnostic-results.json`, one bounded result per workload mode;
- `repair-decision.json`, the source-bound in-scope repair decision;
- `native-rerun.json`, the exact M0-011 four-hour result and digest;
- `task-check.json`, the machine-readable task gate result; and
- `evidence.json`, the fail-closed evidence index when all required reports
  provide PASS.

The test matrix is in [`test-plan.md`](test-plan.md).

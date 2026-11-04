# P1-013 development and release gate separation evidence

## Status

Current qualification requires the current canonical repository gate and a valid
evidence seal. The records below describe historical acceptance and do not
qualify a new source candidate.

## Scope

P1-013 separates unit-level validation of frozen point-in-time release records
from production release freshness validation. Release validators remain strict
by default. Unit tests must opt out explicitly when they are testing schema,
semantic or fault-injection behavior that does not depend on the current source
digest.

The task also updates the native dependency regression expectation for the
implemented Darwin resolver path. Unknown platforms must still fail closed.

The focused development/release regression harness now establishes the same
`tools` module search path as the candidate CLI before importing it. It can run
independently of unittest discovery order. Structural fixture validation and
strict current-source validation retain their separate behavior.

## Current documentation-time maintenance

The first current canonical check reached its unchanged 1,800-second limit.
Its documentation phase took approximately 1,751 seconds and published PASS
only after that deadline. Native descendants then continued outside the failed
invocation; their later 1,090 passed and 28 skipped cases are diagnostic, not a
canonical PASS. P1-012 separately fixes that process-group lifetime.

One unchanged combined-DocIR `api-surface` render took 81.465 seconds. The
approved driver change bounds concurrent public-package/combined views at
three. Each view owns its staging paths and command list. All 40 commands
(41 with HTML), strict lint, complete DocIR validation, 100% symbol/parameter
coverage, the 65,536-entry cache bound, default heap profile and existing task
limits remain unchanged. Receipts retain manifest order and artifacts publish
only after every worker has joined and every view has passed.

The bounded-overlap regression and a required-view failure after sibling
staging exercise concurrency and all-or-nothing publication. They do not
establish native timing: current qualification still requires actual canonical
and HTML execution within their original limits.

## Release boundary

This task does not refresh M7-019 through M7-031 evidence and does not claim the
current source tree is a qualified release candidate. No long-duration gate is
part of P1-013.

## Historical verification

- The focused P1-013 regression suite passed 69 tests with no failures or
  errors.
- The complete repository Python suites passed 322 tooling tests, 168 gate
  tests and 24 benchmark tests.
- `scripts/check` passed the architecture guard, `cjpm check`, `cjpm build` and
  611 Cangjie tests: 588 passed, 23 were explicitly skipped, and none failed or
  errored.
- Strict M7-019, M7-020, M7-021 and M7-031 validation still exits non-zero for
  the current tree because their point-in-time release sources or artifact are
  stale. P1-013 does not refresh or promote them.

That historical toolchain requalification used Cangjie
`1.1.0-alpha.20260829040003`, CJPM `1.1.3` and Linux x86_64 glibc. It ran from
the exact P1-012 requalification commit
`f65893573d536aab46d05e8daf606c46c86eab24`.

## Long-duration gates

The one-hour SSE profile and 86,400-second soak were not run by P1-013. A
`SOAK_ALREADY_RUNNING` line in the canonical log comes from the M7-022 lock
fault-injection unit test; it is not evidence that a real soak process was
observed. These long gates are not part of this repository-tooling correction
and cannot be inferred from the passing development gate.

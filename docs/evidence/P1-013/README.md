# P1-013 development and release gate separation evidence

## Status

COMPLETE

## Scope

P1-013 separates unit-level validation of frozen point-in-time release records
from production release freshness validation. Release validators remain strict
by default. Unit tests must opt out explicitly when they are testing schema,
semantic or fault-injection behavior that does not depend on the current source
digest.

The task also updates the native dependency regression expectation for the
implemented Darwin resolver path. Unknown platforms must still fail closed.

## Release boundary

This task does not refresh M7-019 through M7-031 evidence and does not claim the
current source tree is a qualified release candidate. No long-duration gate is
part of P1-013.

## Verification

- The focused P1-013 regression suite passed 59 tests with no failures or
  errors.
- The complete repository Python suites passed 244 tooling tests, 159 gate
  tests and 24 benchmark tests.
- `scripts/check` passed the architecture guard, `cjpm check`, `cjpm build` and
  610 Cangjie tests: 587 passed, 23 were explicitly skipped, and none failed or
  errored.
- Strict M7-019, M7-020, M7-021 and M7-031 validation still exits non-zero for
  the current tree because their point-in-time release sources or artifact are
  stale. P1-013 does not refresh or promote them.

## Long-duration gates

The one-hour SSE profile and 86,400-second soak were not run. They are not part
of this repository-tooling correction and cannot be inferred from the passing
development gate.

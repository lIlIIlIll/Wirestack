# P1-013 maintained documentation rewrite

Status: **DRAFT — documentation validated; formal task registration deferred**

P1-013 reorganizes the maintained documentation around four reader paths:
adoption, integration, maintenance and review. It replaces stale root status,
adds a central documentation map, Linux getting-started and API orientation,
and separates contribution, security, change, performance, planning and
external-reference guidance.

## Scope

Rewritten or added:

- root `README.md`, `CONTRIBUTING.md`, `SECURITY.md` and `CHANGELOG.md`;
- `docs/README.md`, Linux getting-started and public API orientation;
- architecture, security, performance, planning and external-reference landing
  pages;
- current environment summary;
- a fail-closed maintained-documentation validator and task contract.

The rewrite preserves PRD requirements, accepted ADR decisions, machine API
baselines, historical task evidence, raw benchmark data and generated reports.

## Validation

- test-plan matrix: 10 paths, 8 scenarios and 8 tests, PASS;
- documentation validator unit tests: 4/4 PASS;
- maintained-documentation scan: 24 files, 100 links, 0 issues;
- clean temporary consumer: build and all nine public example markers PASS in
  an authorized native Linux loopback environment;
- task contract validation: PASS.
- final `scripts/check`: PASS outside the socket-restricted sandbox, including
  561 passed and 23 intentionally skipped non-Performance Cangjie tests.

The first sandboxed clean-consumer run built successfully but the sandbox
blocked local socket creation with `Operation not permitted`. The identical
task check passed outside that restriction; no product-code workaround was
introduced.

## Evidence boundary

No one-hour SSE, 24-hour soak, performance profile, fuzz campaign, independent
security review, signing flow or non-Linux platform gate ran for P1-013. The
ongoing M7-022 soak remains independent and its log is not part of this task.

P1-013 is intentionally absent from the backlog, status index and task manifest
while M7-022 is running. Those files are inputs to the qualified M7-021 release
artifact; registering a new task now would change its digest and invalidate the
already-running 24-hour soak. Register and seal this task after M7-022 reaches a
terminal result. The documentation changes and validator remain local until
then.

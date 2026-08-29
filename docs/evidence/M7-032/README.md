# M7-032 evidence

## Status

COMPLETE

## Scope

M7-032 establishes public ownership for Wirestack contracts and removes direct
`wirestack.internal.*` exposure from public declarations. It intentionally
does not preserve the historical experimental API.

## Acceptance evidence

- [ADR-0006](../../architecture/adr/0006-public-contract-ownership.md) records
  the public ownership and acyclic dependency direction.
- [The API report](linux_x86_64/public-api.json) records 243 declarations, 103
  public-to-public aliases, zero internal aliases, and
  `NOT_EVALUATED_PRE_1_0` compatibility policy.
- [The clean-consumer report](linux_x86_64/clean-consumer.json) records native
  build and runtime PASS for HTTPS, existing-transport TLS, CONNECT, H1/H2
  server, SSE, custom CA, mTLS, and scoped cancellation.
- [The task report](task-check.json) records the test-plan validator,
  fault-injection tests, architecture guard, API inventory, clean consumer,
  `cjpm check`, `cjpm build`, and non-Performance tests. All eight commands
  passed; the Python fault-injection set passed 54/54 and the Cangjie suite
  passed 561/561 executed cases with 23 declared skips and zero failures.
- The historical M7-026 baseline is retained but not compared.

## Release evidence boundary

The repository-wide `scripts/check` was run after the ownership change and
failed closed because M7-019, M7-020, M7-021, M7-025, and the historical
M7-026 reports are bound to the earlier source or artifact. Those failures are
expected stale-evidence signals, not M7-032 PASS evidence. The final candidate
must regenerate affected artifact, installation, performance, SBOM, and audit
reports before the single final M7-022 soak.

One earlier default-parallel Cangjie run observed the existing H2 SSE profile
finish before its producer close became visible. The same case passed on an
immediate focused rerun, and the complete 584-case suite passed with
`--parallel 1`. M7-032 does not claim that default-parallel scheduling race is
resolved.

The 86,400-second M7-022 soak, one-hour SSE profile, and every other long gate
were not run by M7-032.

# BOOTSTRAP-001 Repository Control Plane

Status: COMPLETE

## Scope

This bootstrap establishes the Wirestack repository identity and the control
plane required for task-by-task implementation. It deliberately does not
implement Transport, Resolver, TLS, HTTP/1.1, HTTP/2, platform adapters, or
provider integration.

## Changes

- Wirestack product identity and independent-repository boundary recorded.
- PRD updated so new public packages use `wirestack.*` while legacy
  `stdx.net.tls/http` names remain only where describing the old implementation.
- Implementation backlog updated from the old `cangjie_stdx` layout assumption
  to a Wirestack logical layout.
- Root `AGENTS.md` defines task discipline, architecture invariants, workspace
  safety, evidence requirements and completion reporting.
- Status, ADR, gate, evidence, reference, issue and PR templates established.
- No `cjpm.toml` or production package graph was invented; M0-002 must freeze
  physical package/target layout using the actual toolchain.

## Acceptance

- [x] Repository identity is Wirestack.
- [x] New package prefix is `wirestack`.
- [x] `cangjie_stdx`/SDK/runtime are external references/upstream repositories.
- [x] Architecture direction remains `HTTP → TLS → Transport SPI ← StdNetTransport → std.net`.
- [x] Conditional `UP-*` work remains gate-driven and upstream-owned.
- [x] No platform, protocol, provider or performance capability is falsely claimed.
- [x] M0-001 is the first READY implementation task.

# ADR-0006: Public contract ownership

- Status: Accepted
- Date: 2026-08-29
- Owner: Wirestack project owner
- Related task: M7-032
- PRD references: §7, §10, §13, §15, §17, §24

## Context

The public `wirestack.http` and `wirestack.tls` packages currently expose many
types through aliases whose targets live in `wirestack.internal.*`. That makes
internal package placement part of the public declaration graph and prevents
the internal implementation from changing independently.

Wirestack is still a greenfield, pre-1.0 library. The project owner has chosen
not to preserve source, API, ABI, or semantic compatibility with the existing
experimental declarations while this ownership defect is corrected.

## Decision

The root `wirestack` package owns the provider-neutral contracts shared by
HTTP, TLS, resolvers, and transports. User-constructible values, public
interfaces, structured errors, deadlines, cancellation primitives, endpoints,
and transport spans are declared there.

The root package owns contracts that internal implementations must consume, so
the dependency graph stays acyclic. `wirestack.http` and `wirestack.tls` own
facade-only types; they may re-export root-owned contracts through aliases whose
targets are public. No public package aliases an internal target.

The public packages may import other public packages. A public declaration
must not alias, inherit from, accept, return, or expose a
`wirestack.internal.*` type. Internal packages may depend on public contracts
and implement their interfaces. Provider state, protocol state machines,
native handles, and platform adapters remain internal.

The dependency direction is:

```text
wirestack.http -> wirestack.tls -> wirestack
       |               |              ^
       v               v              |
internal HTTP -> internal TLS -> internal Transport SPI <- StdNet adapter
```

Internal arrows to `wirestack` are allowed. Public-to-internal imports may be
used only inside implementation bodies and private/internal declarations; they
must never appear in a public declaration header. No compatibility alias or
migration shim is added.

## Consequences

- The M7-026 API baseline is historical evidence, not a compatibility target.
- M7-032 replaces it with a new Linux pre-1.0 API inventory after ownership
  migration.
- Existing experimental consumers may require source changes.
- Architecture checks fail on direct public aliases to internal packages and
  on any internal type exposed through a public declaration.
- Release artifact, installation, performance, SBOM, API inventory, and final
  soak evidence must be regenerated from the final candidate source.

## Evidence

- `docs/evidence/M7-032/README.md`
- `docs/evidence/M7-032/test-plan.md`

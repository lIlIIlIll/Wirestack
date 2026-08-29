# Wirestack documentation

Use this page to choose the shortest path to the information you need. The PRD,
accepted ADRs, backlog, status tables and retained evidence remain the sources
of truth; overview pages summarize and link to them rather than replacing them.

## Getting started

- [Install and run Wirestack on Linux](getting-started.md)
- [Use the Linux HTTP client and server](guides/http1-linux.md)
- [Migrate an existing Linux integration](guides/migrate-to-wirestack-linux.md)

## API

- [Public API orientation](api/README.md)
- [Frozen Linux v0 API baseline](api/baselines/wirestack-linux-v0.json)
- [Runnable public examples](../examples/linux/m7_027/)

The public packages are `wirestack.http` and `wirestack.tls`. Source declarations
are authoritative until generated API reference pages are available.

## Architecture

- [Architecture map and accepted ADRs](architecture/README.md)
- [Executable dependency guard](architecture/architecture-guard.md)
- [Current network-stack inventory](architecture/current-network-stack-inventory.md)
- [Linux TLS provider build boundary](architecture/linux-tls-provider-build.md)

## Security

- [Security policy and vulnerability reporting](../SECURITY.md)
- [Security documentation map](security/README.md)
- [P0 threat model](security/threat-model.md)

## Performance

- [Performance evidence map](performance/README.md)
- [HTTP/1 Linux benchmark](performance/http1-benchmark.md)
- [HTTP/2 stream benchmark](performance/http2-benchmark.md)

## Planning and current status

- [Planning map](planning/README.md)
- [Product requirements](product/prd.md)
- [Implementation backlog](planning/implementation-backlog.md)
- [Global task status](planning/status.md)
- [Linux delivery status](planning/linux-status.md)

Status is fail-closed: `SKIPPED`, missing native execution, cross-compilation,
or stale evidence is not a pass.

## Gates and Evidence

- [Validation and release gates](gates/README.md)
- [Gate execution framework](gates/framework.md)
- [Historical task evidence](evidence/README.md)
- [External references](references/README.md)

Long-duration gates are opt-in. `scripts/check-fast` and `scripts/check-full`
never start the one-hour SSE profile or the 24-hour soak.

## Contributing

- [Contribution workflow](../CONTRIBUTING.md)
- [Repository agent rules](../AGENTS.md)
- [Change history](../CHANGELOG.md)

Historical evidence, raw reports, accepted decisions and generated baselines are
records. Correct factual errors through a new scoped task instead of rewriting
old results in place.

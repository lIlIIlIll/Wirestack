# M0-024 upstream-independent transport capability decision

## Status

`COMPLETE` on 2026-08-27 for the Linux glibc delivery profile.

## Decision

ADR-0005 removes runtime and `std.net` source changes from the Wirestack
release dependency graph. The current public SDK remains the integration
boundary.

The decision keeps these rules:

- `StdNetTransport` uses only public `std.net` APIs.
- Unsupported directional TCP shutdown returns a typed `Unsupported` error.
- `NetworkException.nativeCode` is optional.
- Socket exception messages are not control flow.
- Exact runtime event-backend discovery is optional.
- TLS and HTTP protocol shutdown requirements remain unchanged.

## Existing implementation evidence

The current source already exposes `TransportInfo.supportsHalfClose`. The Linux
`StdNetTransport` reports `false` and rejects directional shutdown without
accessing a private socket handle. Its socket error mapper uses the operation
context and local lifecycle state before returning a generic stable failure.

The retained Linux evidence proves close wakeup, EOF and local-close
classification, cancellation, TLS `close_notify`, TLS truncation handling, and
HTTP/1 and HTTP/2 graceful shutdown. ADR-0005 changes the dependency model. It
does not relabel TCP directional shutdown as implemented.

## Documentation checks

The task checks that the PRD, ADR index, backlog, global status, Linux status,
and README describe the same capability policy. No runtime, standard library,
or Wirestack production source was changed.

Validation on native Linux glibc x86_64 used Cangjie
`1.1.0-alpha.20260817040003`:

- `scripts/check` passed 57 repository-tool tests, 114 gate tests, 23 benchmark
  tests, the architecture guard, `cjpm check`, and `cjpm build`. Its final test
  stage could not create the unittest loopback socket inside the restricted
  sandbox and exited with `Operation not permitted`.
- `cjpm test --exclude-tags=Performance` was rerun outside that socket
  restriction. It passed 538 tests, skipped 20 tagged or unavailable cases,
  failed 0 tests, and exited 0.

## Current release path

M1-019, M1-022, and M1-023 now have focused Linux qualification evidence. The
next Transport tasks are M1-024 and M1-025. UP-001 through UP-007 remain
independent future upstream tasks and do not block that work or a Wirestack
release.

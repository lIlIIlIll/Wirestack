# M0-003 evidence — architecture dependency guard

## Result

**COMPLETE** for the static architecture-guard scope.

The task adds a standard-library-only Python guard, negative unit tests, text/JSON diagnostics, a local wrapper, and a GitHub Actions blocking workflow. It introduces no Transport, TLS, HTTP, provider, or platform implementation.

## Rules covered

- package declaration must match the source path;
- only `wirestack.internal.transport_stdnet` may reference `std.net`;
- public/Core fully-qualified `std.net` types are rejected;
- `CJ_MRT_Sock*` is rejected;
- old `stdx.net.tls/http`, `stdx.net.tlsFFI`, `CJ_TLS_DYN_*`, and the OpenSSL dynamic-loader bridge are rejected;
- comments and source literals do not cause false positives;
- the same diagnostics are available as text and schema-versioned JSON.

## Verification commands

```text
python3 -m unittest discover -s tools/tests -p 'test_architecture_guard.py' -v
./scripts/architecture-guard
./scripts/architecture-guard --format json
```

Expected and observed local result:

```text
8 tests passed
architecture guard: PASS
JSON: ok=true, violation_count=0
```

The guard and its unit tests require no Cangjie SDK. The full repository check remains responsible for invoking this gate together with `cjpm check` and `cjpm build` in an SDK-enabled environment.

## Boundary

This evidence does not mark any GATE-NET item as passed and does not unlock `UP-*` work. It proves only the static repository dependency rules required by M0-003.

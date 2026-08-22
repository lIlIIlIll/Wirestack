# Architecture dependency guard

`tools/architecture_guard.py` converts Wirestack's package and dependency boundaries into an executable repository gate. It deliberately depends only on the Python standard library, so pull requests can be rejected by GitHub Actions even when a hosted runner does not contain the Cangjie SDK.

## Enforced rules

1. Every `src/**/*.cj` file must declare the package implied by its physical directory under `src/`.
2. Only `wirestack.internal.transport_stdnet` may reference `std.net`, whether through an `import` or a fully qualified name.
3. Production source must not reference `CJ_MRT_Sock*` private runtime symbols.
4. Production source and build configuration must not reuse `stdx.net.tls/http`, `stdx.net.tlsFFI`, `CJ_TLS_DYN_*`, or `cangjie-dynamicLoader-opensslFFI`.
5. Comments and Cangjie string/character literals are excluded from source-token checks. Build configuration is scanned as configuration text because linker dependencies normally appear inside strings.

## Commands

```bash
./scripts/architecture-guard
./scripts/architecture-guard --format json
python3 -m unittest discover -s tools/tests -p 'test_architecture_guard.py' -v
```

The text format is intended for developers and CI logs. JSON output has a versioned schema and is suitable for artifacts or later reporting automation.

## Scope

This guard establishes static dependency boundaries only. It does not prove runtime cancellation, EOF, timeout, ownership, protocol, performance, or platform behavior. Those claims remain subject to the M0 network gates and later milestone tests.

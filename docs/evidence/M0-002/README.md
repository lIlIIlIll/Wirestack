# M0-002 Evidence

## Result

```text
COMPLETE
```

The CJPM package and physical source layout is frozen by ADR-0001. No Transport,
TLS or HTTP API or behavior is implemented by this task.

## Toolchain

```text
Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)
Target: x86_64-unknown-linux-gnu
Cangjie Project Manager: 1.1.3
```

## Verification results

```text
cjpm check success
cjpm build success
./scripts/check success
```

The build generated independent `.cjo` files and static archives for:

```text
wirestack
wirestack.http
wirestack.tls
wirestack.internal
wirestack.internal.common
wirestack.internal.connector
wirestack.internal.http1
wirestack.internal.http2
wirestack.internal.identity
wirestack.internal.platform
wirestack.internal.platform.android
wirestack.internal.platform.apple
wirestack.internal.platform.harmony
wirestack.internal.platform.linux
wirestack.internal.platform.windows
wirestack.internal.resolver
wirestack.internal.tls_engine
wirestack.internal.transport
wirestack.internal.transport_stdnet
wirestack.internal.trust
```

## Negative checks

```text
public declarations under src/: none
std.net imports under src/: none
CJ_MRT_Sock references under src/: none
```

M0-002 intentionally introduces no placeholder public classes, functions,
properties or constants.

## CJPM behavior discovered

1. With no `.cj` file in `src/internal`, CJPM 1.1.3 warned that the directory's
   descendants would not be scanned. Adding `src/internal/package.cj` fixed the
   package graph.
2. Setting a non-empty manifest organization required package names in the form
   `organization::wirestack.*`. The final manifest keeps the organization empty
   to preserve `wirestack.*`.

## Acceptance checklist

| Item | Result | Evidence |
|---|---|---|
| Static Wirestack CJPM project exists | PASS | `cjpm.toml` |
| Required logical modules have real package paths | PASS | ADR-0001 and `src/**/package.cj` |
| Package graph checks | PASS | `cjpm check` |
| Static archives build | PASS | `cjpm build` |
| Canonical check entry point exists | PASS | `scripts/check` |
| Public API unchanged/unfrozen | PASS | no public declarations in `src/` |
| `std.net` ownership assigned only to adapter package | PASS | ADR-0001; mechanical enforcement is M0-003 |
| Six-platform compilation/runtime verified | NOT RUN | M0-002 is a host-layout task; platform evidence remains separate |

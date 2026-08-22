# ADR-0001: CJPM Package and Source Layout

- **Status:** Accepted
- **Date:** 2026-08-22
- **Task:** M0-002
- **Issue:** #3
- **Decision owners:** Wirestack maintainers

## Context

Wirestack needs physical Cangjie package boundaries that preserve the PRD's
mandatory dependency direction:

```text
HTTP -> TLS -> Transport SPI <- StdNetTransport -> std.net
```

The layout must be valid for the supplied toolchain rather than inferred from a
different language or CJPM release. The verified toolchain is:

```text
Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)
Target: x86_64-unknown-linux-gnu
Cangjie Project Manager: 1.1.3
```

CJPM 1.1.3 does not scan descendants of a source directory that contains no
`.cj` file. A parent package file is therefore required at `src/internal` and at
other nested package roots.

CJPM also prefixes package identities with `organization::` when the manifest's
`organization` field is non-empty. Setting `organization = "lIlIIlIll"` changed
the required package name from `wirestack.*` to `lIlIIlIll::wirestack.*`. The PRD
has already selected the public prefix `wirestack`, so the manifest keeps
`organization = ""`.

## Decision

Wirestack is one CJPM static-library project named `wirestack`, with a source root
of `src` and the following package mapping.

| Responsibility | Cangjie package | Physical path | Visibility role |
|---|---|---|---|
| module root and future runtime metadata | `wirestack` | `src/` | Public root; currently empty |
| public TLS API | `wirestack.tls` | `src/tls/` | Public |
| public HTTP API | `wirestack.http` | `src/http/` | Public |
| internal package anchor | `wirestack.internal` | `src/internal/` | Technical parent only |
| shared non-I/O primitives | `wirestack.internal.common` | `src/internal/common/` | Internal |
| Transport SPI and operation semantics | `wirestack.internal.transport` | `src/internal/transport/` | Internal Core |
| only default adapter allowed to use `std.net` | `wirestack.internal.transport_stdnet` | `src/internal/transport_stdnet/` | Internal adapter |
| resolver contract and orchestration | `wirestack.internal.resolver` | `src/internal/resolver/` | Internal Core |
| Happy Eyeballs and route selection | `wirestack.internal.connector` | `src/internal/connector/` | Internal Core |
| portable TLS provider bridge/pump | `wirestack.internal.tls_engine` | `src/internal/tls_engine/` | Internal Core |
| trust policy and normalized evidence | `wirestack.internal.trust` | `src/internal/trust/` | Internal contract |
| identity/private-key abstraction | `wirestack.internal.identity` | `src/internal/identity/` | Internal contract |
| HTTP/1.1 codec and connection state | `wirestack.internal.http1` | `src/internal/http1/` | Internal Core |
| HTTP/2 frame, HPACK, flow and stream state | `wirestack.internal.http2` | `src/internal/http2/` | Internal Core |
| platform adapter parent | `wirestack.internal.platform` | `src/internal/platform/` | Technical parent only |
| Windows platform adapters | `wirestack.internal.platform.windows` | `src/internal/platform/windows/` | Internal platform |
| Linux platform adapters | `wirestack.internal.platform.linux` | `src/internal/platform/linux/` | Internal platform |
| Apple/macOS/iOS adapters | `wirestack.internal.platform.apple` | `src/internal/platform/apple/` | Internal platform |
| Android platform adapters | `wirestack.internal.platform.android` | `src/internal/platform/android/` | Internal platform |
| HarmonyOS/OpenHarmony adapters | `wirestack.internal.platform.harmony` | `src/internal/platform/harmony/` | Internal platform |

The platform packages host trust, identity, random, native capability and
diagnostic adapters. Cross-platform contracts stay in `trust`, `identity`,
`transport` and `tls_engine`; platform-native types must not cross those boundaries.

## Dependency policy

The intended package-level dependency graph is:

```text
wirestack.http
  -> wirestack.internal.http1 / http2
  -> wirestack.tls
  -> wirestack.internal.tls_engine
  -> wirestack.internal.transport

wirestack.internal.connector
  -> wirestack.internal.resolver
  -> wirestack.internal.transport

wirestack.internal.transport_stdnet
  -> wirestack.internal.transport
  -> std.net

wirestack.internal.platform.*
  -> wirestack.internal.trust / identity / common
  -> target platform APIs
```

Mandatory restrictions:

1. Only `wirestack.internal.transport_stdnet` may import `std.net` for the default
   TCP data path.
2. Public packages may not expose any type from `std.net`, provider-native APIs,
   or platform-native APIs.
3. Core packages may not import `std.net`, `stdx.net.tls`, the legacy OpenSSL
   dynamic loader, or `CJ_MRT_Sock*` private runtime ABI.
4. `wirestack.internal.platform.*` packages implement adapters; they do not own
   protocol state machines.
5. Package placeholders created by M0-002 contain no public declarations. Public
   API remains unfrozen until its dedicated design tasks.

M0-003 must enforce these rules mechanically. ADR-0001 records the policy but is
not a substitute for the guard.

## Build contract

The canonical local verification command is:

```bash
source /path/to/cangjie/envsetup.sh
./scripts/check
```

At M0-002, `scripts/check` runs:

```text
cjpm check
cjpm build
```

Later tasks may extend the command with architecture checks, tests and generated
artifact validation, but they must preserve this single entry point.

## Consequences

### Positive

- All required logical modules map to real CJPM packages.
- Core/adapter/public/platform boundaries are visible in paths and build outputs.
- The layout compiles with the supplied SDK and creates separate `.cjo` and static
  archives for each package.
- Platform-native work has an explicit home without forcing separate TLS state
  machines per platform.

### Costs

- Empty parent package files are required for CJPM scanning.
- Cangjie package visibility is not made private merely by the `internal` name;
  CI and API-surface checks must enforce the boundary.
- A single CJPM project means package-level dependency policy needs an explicit
  repository guard rather than relying on separate package-manager projects.

## Rejected alternatives

### Put Wirestack under `src/stdx/net`

Rejected because Wirestack is an independent greenfield repository and product,
not a subtree of `cangjie_stdx`.

### Set `organization = "lIlIIlIll"`

Rejected because CJPM 1.1.3 then requires `lIlIIlIll::wirestack.*`, changing the
PRD-selected public package names.

### Put all implementation in `wirestack`

Rejected because it cannot mechanically isolate Core, platform, default adapter,
TLS provider and HTTP protocol dependencies.

### Create one repository/project per logical module now

Rejected for M0 because it adds publication and dependency-resolution overhead
before public APIs are stable. This ADR can be revisited if CJPM package-boundary
enforcement proves insufficient.

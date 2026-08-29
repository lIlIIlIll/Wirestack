# Get started on Linux

This guide verifies a Wirestack checkout on the only currently qualified product
profile: native Linux x86_64 with glibc. It does not qualify another platform or
build the Cangjie SDK.

## Prerequisites

- Cangjie Compiler `1.1.0-alpha.20260817040003`, target
  `x86_64-unknown-linux-gnu`.
- CJPM `1.1.3`.
- Python 3, Git, a C/C++ toolchain and the repository-pinned native provider
  inputs described in [the provider build guide](architecture/linux-tls-provider-build.md).

The current SDK does not support Linux musl. Do not substitute an AWS-LC musl
PoC or a cross-compiled binary for native Wirestack evidence.

## Check the environment

From the repository root:

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/repo-doctor
```

`READY` means all required checks passed. `DEGRADED` names an optional or
workspace issue. `BLOCKED` means a required platform, tool or capability is
missing. None of those states silently converts missing work to `PASS`.

## Build and test the checkout

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check-fast
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check-full
```

The compatibility entry point `scripts/check` remains available. These commands
do not run performance-tagged tests, the one-hour SSE profile, or the 24-hour
soak.

## Add Wirestack to a CJPM project

Use a repository dependency while the package is not published to a registry:

```toml
[dependencies]
wirestack = { git = "https://github.com/lIlIIlIll/Wirestack.git" }
```

For local development, use `{ path = "/absolute/path/to/Wirestack" }`. The
project builds a static Cangjie library and links pinned native resolver and TLS
provider artifacts from `target/native/...`; it does not fall back to system
`libssl`.

## Run verified examples

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check-m7-027-linux-examples
```

The gate copies the checked-in public examples into a clean temporary consumer,
then builds and runs cleartext HTTP/1.1, HTTPS, HTTP/2, caller-owned transport
TLS, CONNECT configuration, SSE, custom CA, mTLS and scoped cancellation. It is
a functional gate, not a performance or long-duration profile.

Continue with the [public API orientation](api/README.md) or the
[Linux HTTP guide](guides/http1-linux.md).

## Troubleshooting

- `UNSUPPORTED_PLATFORM` or `UNSUPPORTED_LIBC`: use native Linux x86_64 glibc.
- `BLOCKED` from `repo-doctor`: resolve the named required capability; do not
  edit product code to hide an environment failure.
- Missing provider/resolver artifacts: follow the pinned build guide and do not
  add `-lssl` or `-lcrypto`.
- Stale evidence: rerun the owning task and `scripts/verify-evidence <TASK-ID>`.

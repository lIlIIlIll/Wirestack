# Linux TLS provider build

Wirestack's Linux profile builds AWS-LC as a repository-controlled static
provider. The default build never probes for or falls back to a system TLS
library.

## Frozen inputs

- Provider: AWS-LC 5.5.0
- Commit: `991e67ff4cf04df4dd89e407f8b920c6936cb56a`
- Tree: `ae54cd9455f9630451d505855afe808a9f028b25`
- Source fingerprint:
  `0058686c2ce423c9c416c0597ae84bb30d07ee71271acf58e110f69f802f6478`
- Patch set: empty
- ABI: `wirestack_tls_provider` version 1

The canonical machine-readable input is
[`native/tls/aws_lc/provider.json`](../../native/tls/aws_lc/provider.json).
Changing its source identity, option set, capability inventory or patches is a
provider promotion and must rerun the ADR-0003 gates.

## Build behavior

`cjpm check`, `build`, `test`, `bench`, `run`, `install` and `publish` execute
the repository `build.cj` hook. The hook calls
`tools/build_linux_tls_provider.py`, which:

1. obtains only the exact pinned Git commit while ignoring user/system Git URL
   rewrites;
2. rejects a commit/tree mismatch or any tracked or untracked source change;
3. builds AWS-LC with shared libraries, tests, Go and the `bssl` tool disabled;
4. compiles the versioned Wirestack C ABI shim;
5. flattens the shim, `ssl` and `crypto` objects into one
   `libwirestack_tls_provider.a` archive;
6. compiles and executes a native provider/CSPRNG smoke binary; and
7. atomically activates a content-addressed build only after all checks pass.

Generated state lives below `target/native/`. The retained
`provider-manifest.json` records source identity, build inputs, compiler and
target identity, capabilities, archive size/SHA-256 and
`externalOpenSslDependency: false`. The build fingerprint includes the frozen
provider input, C ABI source/header, build-script source, tool identities and
Linux libc/architecture.

The default source cache is `.local/tls-provider/`. A release or offline job may
provide an already materialized checkout with:

```bash
WIRESTACK_AWS_LC_SOURCE=/verified/aws-lc cjpm build
```

The override is not trusted: the same exact commit, tree and clean-worktree
checks still run. `--offline` fails if no verified source or valid generated
artifact is available.

## Runtime boundary

`wirestack.internal.tls_engine.AwsLcTlsProvider` owns one opaque provider
instance. It exposes a provider-neutral immutable manifest and CSPRNG operation;
no AWS-LC/native handle appears in public Wirestack APIs. Close is idempotent,
use after close fails with `TlsProviderErrorCode.Closed`, and provider failures
map to stable structured errors without logging secret bytes.

This closes the Linux portions of M3-001, M3-002 and M3-003. TLS record/handshake
state begins at M3-004 and remains separate from this build/SPI boundary.

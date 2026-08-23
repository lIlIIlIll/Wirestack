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

`AwsLcTlsEngine` owns an AWS-LC `SSL` state machine attached only to bounded
memory BIOs. The C ABI exposes handshake step, pending-output, drain-output and
feed-input operations; it never accepts a socket or transport handle.
`TlsEnginePump` is the only bridge to `DuplexTransport`. It preserves one
absolute `OperationContext`, drains ciphertext through partial writes before
requesting more input, uses a bounded 1..65536-byte scratch size, treats
transport EOF during handshake as truncation evidence, and fails closed on any
zero-progress provider or transport result. Build-time native smoke and Cangjie
tests both exercise a real AWS-LC ClientHello.

`TlsConnection.handshake` consumes both the engine and transport on every path.
After success it is the only owner and exposes plaintext through the internal
`DuplexTransport` contract. One reader and one writer may overlap; a second
same-direction operation fails immediately. Engine output and transport input
are independently serialized so TLS control traffic cannot create concurrent
same-direction transport calls. Handshake or application-I/O failure aborts the
transport, while close/abort races release the engine and underlying transport
exactly once. TLS half-close remains deliberately unsupported until the
`close_notify` work in M3-026.

## Context and security policy

`TlsClientContext` and `TlsServerContext` use mutable builders but freeze all
configuration at `build()`. ALPN arrays are copied on input and output, so one
built context is safe to share across concurrent connection attempts. Context
construction validates the version range, ALPN names, trust and identity role,
mTLS prerequisites and every requested provider or platform capability before
network I/O begins.

The provider-neutral `TlsSecurityProfile` has three fixed policies:

- `Compatible` and `Modern` permit TLS 1.2 through TLS 1.3;
- `StrictTls13` permits TLS 1.3 only.

The selected minimum and maximum are passed as typed version numbers to the C
ABI and applied with AWS-LC protocol-version controls before `SSL` creation.
There is no public or internal OpenSSL cipher-string escape hatch. Compression,
renegotiation, NULL/anonymous cipher suites and 0-RTT remain disabled by the
provider defaults and Wirestack exposes no operation that enables them.

Capability reporting is explicit rather than inferred from provider names. The
Linux AWS-LC profile reports custom roots, client certificates, server mode,
TLS 1.2, TLS 1.3 and HTTP/2. System trust is reported only when the explicit
Linux adapter discovers a usable frozen CA source. Hardware keys and network
binding remain false until their adapters are implemented; requesting either
fails at context creation.

This closes the Linux portions of M3-001 through M3-008.

## Trust and reference identity

`TrustPolicy` now represents `System`, `CustomRoots`,
`SystemPlusCustomRoots` and `PinnedPublicKeys`; no `TrustAll` state is
representable. Every policy receives a SHA-256 content identity suitable for
session and pool isolation. SPKI pins are exactly 32-byte SHA-256 digests and
declare leaf-only or any-certificate scope. Pin verification treats the
matching certificate as the explicit trust anchor and still applies X.509 path,
validity and reference-identity checks.

Certificate input is exact DER only. The native adapter rejects trailing data,
malformed X.509, duplicate certificates and excess extensions before a context
can use the chain. Hard ceilings are 16 certificates, 256 KiB per certificate,
1 MiB per chain, 128 extensions per certificate and 256 SAN identities. Native
SAN extraction returns only bounded DNS/IP values to the provider-neutral
verifier.

DNS and IP reference identities are distinct types. DNS matching is SAN-only,
accepts canonical ASCII IDNA A-labels, never falls back to Common Name and only
permits a wildcard as the complete left-most label matching exactly one label.
SNI is supplied separately and a ClientHello test proves that changing the
reference identity does not change the emitted SNI extension.

Linux system trust never calls `SSL_CTX_set_default_verify_paths`. It selects
the first readable non-empty bundle in this frozen order:

1. `/etc/ssl/certs/ca-certificates.crt`;
2. `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`;
3. `/etc/pki/tls/certs/ca-bundle.crt`;
4. `/etc/ssl/ca-bundle.pem`.

Only when no bundle is usable does it select the first readable hashed
directory from `/etc/ssl/certs` then `/etc/pki/tls/certs`. If neither source is
usable, capability discovery reports system trust unavailable and context
construction fails; there is no environment or provider-default fallback.

## Local identity and end-to-end pin verification

`LocalIdentity` binds a leaf-first certificate chain to an opaque
`PrivateKeyRef`. The implemented Linux software-key variant accepts only one
exact, unencrypted DER PKCS#8 object, either from caller memory or an absolute,
readable, bounded regular file. AWS-LC checks the leaf/key match during identity
construction, before a context can be used. Transient key copies are zeroed,
and closing the reference clears the owned PKCS#8 bytes.

Server engines install the leaf, private key and any intermediate chain through
the pinned native provider. A paired memory-BIO test completes a real TLS
client/server handshake with the fixture's SPKI pin, while the same handshake
with a wrong pin fails in the provider verification path. M3-012 and M3-017 are
therefore complete. M3-013 still needs native musl adapter evidence, and M3-016
still needs system-handle and external-signer contracts.

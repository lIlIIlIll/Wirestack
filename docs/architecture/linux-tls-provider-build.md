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
exactly once. M3-026 implements TLS shutdown with `close_notify`; it does not
depend on directional TCP shutdown.

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
therefore complete.

The same opaque `PrivateKeyRef` now represents PKCS#8, a platform system
handle/alias, or an external signer. Handle/signer refs carry only a stable
identity, bounded DER SubjectPublicKeyInfo, an explicit hardware-backed bit and
1..16 non-duplicate TLS signature algorithms. AWS-LC validates that the public
key matches the leaf certificate before a context is usable.

External signing uses AWS-LC's retry protocol rather than a C-to-Cangjie user
callback. The native `SSL_PRIVATE_KEY_METHOD` copies at most 64 KiB of signing
input into instance-owned engine state and returns
`SSL_ERROR_WANT_PRIVATE_KEY_OPERATION`. The Cangjie pump retrieves that request,
releases its engine mutex, checks the same `OperationContext`, calls user code,
then supplies at most 16 KiB of signature or explicitly fails the pending
operation. User exceptions therefore never cross the C ABI, no provider-global
signer state or lock exists, and cancellation fails closed. Positive real
handshake, deliberate user exception and pre-invocation cancellation tests
close M3-016 and M3-018. M3-013 still needs native musl adapter evidence.

## Negotiation results, ALPN and mutual TLS

Configured ALPN values are encoded once into a bounded 4096-byte RFC 7301
protocol vector. Clients install their offer directly on the instance `SSL`;
servers retain an instance-owned immutable preference vector and select from the
peer offer without global state. Server preference order is authoritative. If
either endpoint configured ALPN, completing a handshake without a selected
protocol is an error; a server callback with no shared value emits a fatal
`no_application_protocol` path.

After a completed handshake the C ABI copies, rather than exposes, the TLS
version, IANA cipher-suite name, selected ALPN and leaf-first peer certificate
chain. The chain is limited to 16 certificates, 256 KiB each and 1 MiB total.
`TlsHandshakeInfo` combines those values with the session-reused bit, provider
manifest, configured trust identity, matched pin and verified reference
identity. `TlsConnection` snapshots that immutable result before taking
ownership of the engine and transport.

Client identities from `TlsClientContext` now use the same PKCS#8 or external
signer path as server identities. Server `ClientAuthentication.None`,
`Optional`, and `Required` map explicitly to AWS-LC verification modes. Optional
authentication accepts an absent certificate without fabricating chain or trust
evidence; Required rejects absence and returns the verified client chain and
normalized trust evidence on success. Paired memory-BIO tests cover successful
TLS 1.3 ALPN, no-shared-ALPN failure, required mTLS success/failure and optional
mTLS without a certificate, completing M3-021, M3-023 and M3-024.

## SNI server-context selection

SNI routing selects a complete immutable `TlsServerContext`, not only a
certificate. A `TlsServerContextSelector` contains 1..256 exact canonical
`HostName` routes belonging to the same provider identity. It defensively
copies its route table and rejects duplicates, so it remains safe to share
across concurrent handshakes.

AWS-LC's certificate-selection callback copies at most 253 bytes of requested
server name into engine-owned state and returns its retry result. It never calls
Cangjie or user code. The pump observes that state, releases the engine mutex,
performs the immutable lookup, then installs the selected context's protocol
range, identity, ALPN and client-authentication policy before completing the
native retry. No provider-global callback state or lock is used.

Once SNI routing is enabled, an absent, invalid or unknown name fails closed;
there is no implicit default-certificate fallback. The completed server
handshake result retains the requested name. Paired real memory-BIO tests use
two distinct certificates and policies to prove the selected name controls the
certificate, TLS version and ALPN, while missing and unknown names expose stable
selection error codes. This completes M3-022.

## Session resumption

Each provider owns a thread-safe LRU client-session store bounded to 256 entries,
4 MiB total encoded state and 256 KiB per session. Entries use a monotonic expiry
derived from the provider session lifetime. Replacement, expiry, eviction,
single-use consumption and provider close overwrite the encoded session bytes;
diagnostics expose only counts and byte totals.

The store key includes the reference server identity, ordered ALPN offer, trust
policy identity and selected Linux CA source, client identity, provider
id/fingerprint and TLS version policy. A session cannot therefore bypass a
changed authentication or negotiation context. TLS 1.3 tickets are consumed
once as required by RFC 8446 privacy guidance; TLS 1.2 tickets may remain until
expiry or eviction.

Servers use stateless tickets with a random provider-instance key shared across
fresh engine `SSL_CTX` objects and rotated after 48 hours. Each engine also
installs a 32-byte digest of its complete server context as the session-id
context, including SNI-selected identity, ALPN, protocol range and mTLS trust
source. This prevents a valid ticket from crossing virtual-host or client-auth
boundaries.

AWS-LC defers TLS 1.3 `NewSessionTicket` generation until the first write, so
the server engine performs one zero-length post-handshake write and the normal
memory-BIO path transports the ticket. Client callbacks serialize at most one
bounded ticket into engine-owned memory; Cangjie copies it into the store and
clears the native copy. Session parsing strips any early-data capability before
`SSL_set_session`, and early data is explicitly disabled on both `SSL_CTX` and
`SSL`.

Paired memory-BIO tests create fresh client and server engines and prove both
TLS 1.2 and TLS 1.3 report `resumed`. Deterministic store tests prove limits,
LRU eviction, expiry, single-use behavior and every isolation-key dimension.
This completes M3-025.

## TLS shutdown

Graceful connection close drives AWS-LC's two-stage `SSL_shutdown` through the
same memory-BIO pump used for handshake and application data. New application
writes stop when the connection enters `Closing`; the pump sends
`close_notify`, drains every partial ciphertext write, and processes the peer's
`close_notify` using the caller's single absolute `OperationContext`. Deadline
or cancellation failure still closes the underlying transport and releases the
engine exactly once.

`TlsConnection.closureEvidence` distinguishes an exchanged `CloseNotify`, a
bare transport EOF as `PeerClosedWithoutCloseNotify`, and `LocalAbort`. Abort
never calls the TLS shutdown state machine: it terminates the underlying
transport immediately so blocked I/O wakes, then releases the engine. A real
paired AWS-LC test proves both shutdown directions, while deterministic tests
cover truncation, expired close budgets, abort behavior and close/abort races.
This completes M3-026.

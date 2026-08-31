# TLS provider development

Wirestack treats the transport adapter and TLS provider as independent build
dimensions. The transport adapter connects Wirestack's transport SPI to a
platform network API. The TLS provider supplies TLS, certificates,
cryptography, secure random, and opaque native engines. A provider must not
import `std.net` or own `Deadline`, `CancellationToken`, or `OperationContext`.

The dependency direction is:

```text
wirestack.http -> wirestack.tls -> provider-neutral TLS Core
                                      |
                                      v
                             internal TlsProvider
                                      |
                              build-time factory

HTTP -> TLS -> Transport SPI <- platform transport adapter -> std.net
```

## Manifest and ABI

A provider manifest follows
`tools/tls_provider/provider-manifest-schema-v1.json`. It records the stable
provider ID and version, exact source tag/commit/tree/content digest, license,
build options, ABI identity, and capabilities. `abi-v1.json` defines the
provider-neutral native function set. Handles are opaque; buffers remain owned
by the caller unless a function explicitly copies them; destroy functions own
the final native release.

Capabilities are promises. A provider that advertises a capability must export
every mapped ABI function. Missing functions, an ABI mismatch, or a manifest
mismatch rejects the build. Close and abort are idempotent, cancellation races
have one winner, and EOF, TLS truncation, cancellation, deadline, and local
abort remain distinct results.

## Add a provider or platform adapter

1. Add a provider implementation under a provider-specific adapter directory.
2. Pin its source, license, build options, ABI, and capabilities in a manifest.
3. Add the allowed platform/provider pair to `selection.json`.
4. Add an adapter dispatch entry to the build-time provider factory.
5. Run manifest, ABI, architecture, lifecycle, negative, clean-consumer,
   release, SBOM, license, and evidence-freshness tests.
6. Add platform claims only after execution on that native platform or VM.

Adding an adapter must not modify generic TLS/HTTP state machines or public
APIs. Wirestack intentionally rejects runtime guessing and automatic fallback:
the resulting binary, security review, SBOM, and evidence must describe one
deterministic provider.

## Current support

Only `linux-x86_64-glibc + aws-lc` is implemented and accepted. AWS-LC is pinned
to 5.5.0 and its LICENSE and NOTICE ship in the Linux artifact. Windows, Apple,
HarmonyOS, Android, musl, and pure-Cangjie TLS providers are extension points,
not supported implementations.

## M0-016 PoC source ledger

The M0-016 comparison uses the following exact external sources. Mbed TLS and
OpenSSL are PoC candidates or controls, not supported Wirestack providers.

| Role | Source | Release identity | Content identity |
|---|---|---|---|
| Linux default | AWS-LC 5.5.0 | tag `v5.5.0`, commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a`, tree `ae54cd9455f9630451d505855afe808a9f028b25` | content SHA-256 `0058686c2ce423c9c416c0597ae84bb30d07ee71271acf58e110f69f802f6478` |
| PoC candidate | Mbed TLS 4.2.0 | annotated tag `mbedtls-4.2.0`, peeled commit `ece41aa84d7879d7e55c59e955a5884b541f7f3b` | archive SHA-256 `2bed9d713b4668f76553b097e72b8aa30bc8f112a940d7ae228d524bbde6ffea` |
| PoC control | OpenSSL 3.6.4 | annotated tag `openssl-3.6.4`, peeled commit `d3c1b1169b3569ff3069e5b399f47b2b28e03d79` | archive SHA-256 `9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef` |

Archive runs resolve the annotated tag through the upstream GitHub Git-object
API and fail closed unless the peeled commit equals this ledger and
`tools/tls_provider_poc/providers.json`.

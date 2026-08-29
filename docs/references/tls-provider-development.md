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

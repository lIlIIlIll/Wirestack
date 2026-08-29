# M3-030 TLS provider contract

The generic TLS and HTTP layers depend on `TlsProvider`, `TlsEngine`, Wirestack
contexts, and opaque native handles. They do not depend on an AWS-LC class,
source path, native structure, or runtime library name.

## Identity and ownership

Every provider instance publishes a stable provider ID, version, source/build
fingerprint, ABI version, and capabilities. Contexts, engines, selectors, and
sessions retain an instance binding in addition to the stable build identity.
Combining objects from different instances fails with `ProviderMismatch`.
Engines retain provider lifetime state until they close. Provider `close` and
engine `close` are idempotent; no operation completes more than once.

## Selection and capabilities

`tools/tls_provider/selection.json` is the build-time platform/provider matrix.
Linux x86_64 glibc selects the sole production provider `aws-lc`. Unknown
platforms, unknown providers, disallowed combinations, missing manifests,
unknown schemas, ABI mismatches, and false capabilities fail closed. There is
no runtime probing or fallback.

## ABI and errors

`tools/tls_provider/abi-v1.json` fixes the required C ABI function set, the
functions implied by each capability, every parameter and return type, and the
C calling convention. The ABI uses fixed-width integers and opaque integer
handles. Contract schema v2 is independent from provider ABI version 1: the
schema version describes this machine-readable document, while the provider ABI
version is the value exported by the built archive.

The selector parses every production Cangjie `foreign func` declaration and
compares its parameter and return ABI to the contract. The generic build entry
also compiles a generated C function-pointer probe against the adapter header
with incompatible function pointer diagnostics promoted to errors. This catches
parameter, return, header and calling-convention drift before the archive is
accepted. The adapter owns native allocation and release. Native failures map
to stable Wirestack categories and preserve the operation phase, native code
when available, retryability, and cause; exception message text is not control
flow.

The build selector enumerates every production `wirestack_tls_*` Cangjie
foreign import. A function missing from the canonical ABI contract fails with
`abi-contract-incomplete`. A contracted function missing from the selected
archive fails with `abi-function-missing`. A Cangjie signature mismatch fails
with `abi-signature-mismatch`; a native header mismatch fails with
`native-abi-signature-mismatch`.

## Current acceptance boundary

Production acceptance is Linux x86_64 glibc with pinned AWS-LC 5.5.0 only.
`TestTlsProvider` is compiled only as a test source and proves factory
substitution, instance separation, and retained lifetime. It is not a crypto
implementation and is excluded from release payloads.

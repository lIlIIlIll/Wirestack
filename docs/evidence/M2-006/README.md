# M2-006 Apple SystemResolver evidence

Status: INCOMPLETE

M2-006 adds a build-time Apple resolver adapter for macOS arm64 and iOS
Simulator arm64. The adapter reuses the bounded POSIX worker implementation,
retains the provider-neutral resolver ABI, and does not import `std.net`, call a
private runtime ABI, create an event loop, or own a second cancellation or
Deadline policy.

## Current evidence

- The P/S/T test plan passes the repository matrix validator with 10 paths,
  10 scenarios, and 10 tests.
- Build selection accepts native `macos-arm64` and explicit
  `ios-simulator-arm64`; unsupported targets fail closed.
- Python fault-injection tests reject wrong platforms, stale revisions,
  unknown schemas, cross-compile-only output, SKIPPED cases, timeout, missing
  simulator evidence, and a missing fixture binding.
- The Apple C adapter compiles with strict C11 warnings in a local structural
  probe. This is not Apple platform evidence.
- The selected Cangjie test package compiles locally. Local Linux execution is
  not counted as Apple platform evidence.

## Pending hosted evidence

The `M2-006 Apple SystemResolver` GitHub workflow has two independent jobs:

- native macOS arm64 execution on `macos-15`;
- iOS Simulator arm64 execution on `macos-15` with the official prebuilt
  `cangjie-sdk-mac-aarch64-ios` nightly.

Both jobs must run seven selected Cangjie cases and retain exact-revision
reports. The iOS job packages the generated Cangjie unittest runner and
resolver test executable into a Simulator app, installs it, then executes the
runner inside the booted Simulator. `cjpm test --no-run` alone cannot satisfy
the task.

## Test-only link support

The resolver test target retains three unused TLS certificate-helper foreign
references from the root package. The hosted gate builds a separate
`m2_006_tls_link_stub` archive for the selected Apple target. Every entry fails
closed. The archive is test-only and is not a provider or release payload.

## Limits

M2-006 does not establish physical iPhone/iPad support, Apple TLS or trust
support, Android or HarmonyOS support, or any release/performance claim. It
does not run the one-hour SSE profile or the 86,400-second soak.

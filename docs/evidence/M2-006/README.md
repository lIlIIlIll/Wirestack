# M2-006 Apple SystemResolver evidence

Status: COMPLETE

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
  simulator evidence, incomplete or duplicated native trace sequences, and a
  missing fixture binding, unsafe cache eviction, stale leases, malformed lease
  metadata, and cache saturation by active builds. All 30 focused tests pass.
- GitHub Actions run
  [`33369108722`](https://github.com/lIlIIlIll/Wirestack/actions/runs/33369108722)
  passed both hosted jobs at exact revision
  `451af03abba6a511c2504e3280be9c1c88b0d337`.
- The native `macos-15` arm64 job ran all eight selected Cangjie resolver cases
  with zero failures and stored its exact-revision report and validation.
- The native iOS Simulator arm64 job built the standalone Cangjie probe,
  bundled and signed the official simulator runtime, installed the app, and
  ran all eight cases with zero failures on the booted iOS 26.2 Simulator. The
  gate validates the unbuffered native `START`/`PASS` trace sequence because
  `std.env.exit` does not guarantee that Cangjie stdout is flushed.
- The iOS gate permits one recorded Simulator restart only when the first
  `simctl launch --console` attempt times out before producing any app output.
  Partial protocol execution, case output, and nonzero exits are never retried.
- Both reports record Cangjie
  `1.3.0-alpha.20260831010012`, Apple clang, runner image identity, adapter
  source digests, build fingerprint, platform, and exact repository revision.

## Hosted Apple evidence

The `M2-006 Apple SystemResolver` GitHub workflow has two independent jobs:

- native macOS arm64 execution on `macos-15`;
- iOS Simulator arm64 execution on `macos-15` with the official prebuilt
  `cangjie-sdk-mac-aarch64-ios` nightly.

Both jobs ran eight selected Cangjie cases and retained exact-revision reports.
The iOS job compiles a standalone Cangjie resolver probe, packages the
official `ios_simulator_aarch64_cjnative` runtime under the app's `Frameworks`
directory, records the signed bundle inputs, installs the app, and launches it
in the booted Simulator. This avoids a child-process test runner, which the app
sandbox cannot launch. The probe terminates with `std.env.exit` after emitting
all eight case records so process-wide resolver workers cannot keep the test app
alive. Compilation alone does not satisfy the task.

## Test-only link support

The resolver test target retains three unused TLS certificate-helper foreign
references from the root package. The hosted gate builds a separate
`m2_006_tls_link_stub` archive for the selected Apple target. Every entry fails
closed. The archive is test-only and is not a provider or release payload.

## Limits

M2-006 does not establish physical iPhone/iPad support, Apple TLS or trust
support, Android or HarmonyOS support, or any release/performance claim. It
does not run the one-hour SSE profile or the 86,400-second soak.

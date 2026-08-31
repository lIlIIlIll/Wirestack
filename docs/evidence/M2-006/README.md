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
  simulator evidence, and a missing fixture binding.
- GitHub Actions run
  [`33352734478`](https://github.com/lIlIIlIll/Wirestack/actions/runs/33352734478)
  passed both hosted jobs at exact revision
  `843cec9644d3fb4ae844045fca7f56cc6ed0a1a4`.
- The native `macos-15` arm64 job ran all seven selected Cangjie resolver cases
  with zero failures and stored its exact-revision report and validation.
- The native iOS Simulator arm64 job built the standalone Cangjie probe,
  bundled and signed the official simulator runtime, installed the app, and
  ran all seven cases with zero failures on the booted iOS 26.2 Simulator.
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

Both jobs ran seven selected Cangjie cases and retained exact-revision reports.
The iOS job compiles a standalone Cangjie resolver probe, packages the
official `ios_simulator_aarch64_cjnative` runtime under the app's `Frameworks`
directory, records the signed bundle inputs, installs the app, and launches it
in the booted Simulator. This avoids a child-process test runner, which the app
sandbox cannot launch. The probe terminates with `std.env.exit` after emitting
all seven case records so process-wide resolver workers cannot keep the test app
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

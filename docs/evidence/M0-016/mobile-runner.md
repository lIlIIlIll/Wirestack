# M0-016 mobile runner contract

The mobile provider PoC now has two GitHub-hosted native-VM jobs:

| Target cell | Hosted runner | Native execution environment |
|---|---|---|
| `android-aarch64` | `ubuntu-24.04` | arm64 Android Emulator, API 33 or newer, NDK 26.3.11579264 |
| `ios-aarch64` | `macos-15` | arm64 iOS Simulator supplied by Xcode |

Each job builds the pinned provider for the target, links the PoC statically,
stages the executable and fixtures inside the VM, executes the complete
schema-v11 capability set, and validates the result against `GITHUB_SHA`.
The Android job installs the pinned NDK and uses `adb`. Emulator discovery has
both a 90-second `wait-for-device` bound and a 240-second overall boot bound;
each `getprop sys.boot_completed` probe is limited to 15 seconds. License
acceptance records the `sdkmanager` pipeline status explicitly so a normal
`yes` SIGPIPE cannot turn a successful installation into a false failure. The
iOS job builds an unsigned simulator app bundle, installs it with `simctl`, and
captures `simctl launch --console` output.

## Run the hosted gate

Open the `M0-016 Mobile Provider PoC` workflow and select **Run workflow**, or
push a change touching the workflow, provider runner, or M0-016 contract. The
workflow first runs the fail-closed Python contract tests, then runs AWS-LC and
Mbed TLS independently on each mobile VM. OpenSSL remains a desktop control per
the candidate matrix; mobile control builds are omitted because they add no
required decision information. Every provider job uploads `result.json`,
`build.log`, and the provider license bundle even when the job fails.

After reviewing a successful artifact, copy it into the committed evidence tree
with the fail-closed retention helper:

    python3 tools/tls_provider_poc/retain_mobile.py \
      --result <artifact>/result.json \
      --license-bundle <artifact>/license-bundle \
      --expected-revision <exact-GITHUB_SHA> \
      --report /tmp/m0-016-mobile-retention.json

The helper accepts only a validated `PASS` or `PARTIAL` Android/iOS result,
refuses path escapes, symlinks, digest changes, and replacement of a different
retained cell, and publishes the result, license tree, and one matrix-cell
update without silently overwriting existing evidence. Re-running it for the
same bytes is idempotent. A failed or incomplete hosted run remains outside the
canonical matrix and must not be recorded as `PASS`.

The retained result includes:

- the exact repository revision and hosted image identity;
- the target triple, compiler, SDK/NDK and configure/build provenance;
- a `native_runtime` object identifying `android-emulator` or
  `ios-simulator`, including architecture and API/runtime identity; and
- all capability, allocation, cancellation, and cleanup metrics required by
  schema v11.

`tools/tls_provider_poc/validate.py` rejects a mobile result without the
native-runtime object, with a mismatched hosted runner, or with
`is_device=true`. This keeps simulator/emulator evidence distinct from a
physical-device result.

## Current boundary

This workflow is a native VM gate, not physical-device evidence. It does not
close GATE-NET-07, M0-012, or the full M0-016 six-platform acceptance. Harmony
OS/OpenHarmony and physical Android/iOS devices remain `BLOCKED` until a
corresponding native environment is available. A successful mobile VM result
also does not change the Linux-only provider selection in ADR-0003.

The workflow does not build the Cangjie SDK and does not modify runtime,
`std`, `stdx`, or SDK sources.

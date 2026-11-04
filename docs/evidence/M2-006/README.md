# M2-006 Apple SystemResolver evidence

Status: BLOCKED at the full M2-006 task level. Current desktop qualification is determined by the current-desktop receipts; mobile/iOS remains unverified.

M2-006 adds a build-time Apple resolver adapter for macOS arm64 and iOS Simulator arm64. The adapter reuses the bounded POSIX worker implementation, retains the provider-neutral resolver ABI, and does not import `std.net`, call a private runtime ABI, create an event loop, or own a separate cancellation or Deadline policy.

## Current desktop qualification

The macOS workflow uses the official Cangjie STS 1.2.0 macOS arm64 archive specified in [`docs/references/m2-006-sts-sdk.json`](../../references/m2-006-sts-sdk.json):

- Archive: `cangjie-sdk-mac-aarch64-1.2.0.tar.gz`
- Size: 163,787,681 bytes
- SHA-256: `de88d6ba2185c94979e0ab2fe8ac1d81535dfdff3fcb51fbba71e4b99d851f97`
- Official sources: [STS 1.2.0 downloads](https://cangjie-lang.cn/en/download/1.2.0), [release notes](https://cj-docs.gitcode.com/zh/1.2.0/release-notes/cangjie_1.2_release_notes.html), and the [macOS installation guide](https://cj-docs.gitcode.com/zh/1.2.0/dev-guide/source_zh_cn/first_understanding/install.html).

The workflow checks out the exact source revision, verifies the official
archive checksum, and extracts the SDK. Before accepting a report, the shared
SDK identity helper checks the pinned archive byte count, streams each archive
file against the installation, and requires an exact installed-file inventory.
It invokes `cjc` and `cjpm` by their SDK-root paths to record version and
native-target identity. The runner requires a clean checkout whose `HEAD`
matches the requested SHA. The typed source inventory follows the ordered
`source_paths` in `tools/tasks/M2-006.json`, including the workflow, task
manifest, gate tests and digest helper while excluding generated current
reports and logs to avoid self-reference. It binds the Apple and shared
resolver sources, Cangjie resolver test sources, build inputs and SDK pin. The
native report records the resolver archive as an artifact-byte digest and
retains typed text digests for each command log.

Initial capture requires a clean checkout. Post-capture and report validation
exclude only the named generated report, validation receipt and five command
logs from the cleanliness check. Other tracked or untracked changes still fail;
an output path that overlaps a bound source input also fails.

`xcrun` discovery returns raw operational compiler, archiver and SDK paths.
Only recorded commands, diagnostics and logs are sanitized. A redacted
`<XCODE_PATH>` is never used as an executable or sysroot.
The [executable-path regression receipt](maintenance/xcrun-path-regression.json)
retains the failed native stage and the real Linux compiler-consumer red/green
proof. That smoke and the gate unit tests do not qualify native macOS behavior.

The current desktop receipt location is
`docs/evidence/M2-006/current-desktop/macos-arm64/`. A desktop PASS requires
the native gate to record all eight named cases as passed with no failed or
skipped targeted case, command error, or timeout. This frozen source overview
does not itself establish qualification.

## Current native desktop STS result

The [current report](current-desktop/macos-arm64/report.json) and
[validation](current-desktop/macos-arm64/validation.json) passed on native
`macos-15` arm64 at source `6c5eb96e8552975dbc17651f1e86ca947e78b0ac`.
[Run 41698885481](https://github.com/lIlIIlIll/Wirestack/actions/runs/41698885481),
job `126136636324`, was dispatched once on
`fix/M10-002-resource-owner-backpressure`.

All eight selected cases passed without targeted skips, errors, failures or
timeout. The 26 other filtered cases were skipped, not qualified. Native SDK
identity matched 283 archive files, compiler/CJPM 1.2.0 and target
`aarch64-apple-darwin`. Artifact `13262723175` retained the report, validation
and five logs. Its raw ZIP is 11,024 bytes, artifact-byte SHA-256
`505cc5c4ed0c84606f10a05d2f95a00adf9a183c01737f28e08716c5a569c7ce`.
Full M2-006 remains BLOCKED; this is desktop-only qualification.

## Mobile and historical evidence

The selected workflow now runs only the native macOS desktop STS job. It does not download a nightly SDK or run an iOS Simulator job. Mobile/iOS remains a separate required qualification for full M2-006 completion and is explicitly unverified.

The older schema-1 generic index and existing macOS/iOS reports remain unchanged as historical records. They used prerelease/nightly toolchains and do not qualify the current STS desktop source. The previous hosted run [`33369108722`](https://github.com/lIlIIlIll/Wirestack/actions/runs/33369108722) is historical evidence only; it is not a current-source STS result.

## Resolver test-only link support

The resolver test target retains unused TLS certificate-helper foreign references from the root package. The hosted macOS gate builds a separate `m2_006_tls_link_stub` archive for the selected Apple target. Every entry fails closed. The archive is test-only and is not a provider or release payload.

## Limits

M2-006 does not establish physical iPhone/iPad support, Apple TLS or trust support, Android or HarmonyOS support, or any release/performance claim. It does not run the one-hour SSE profile or the 86,400-second soak.

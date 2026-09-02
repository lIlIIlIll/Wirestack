# M0-016 mobile runner test plan

## Semantics

This plan covers the GitHub-hosted native-VM extension to the M0-016 provider
PoC. Android runs an arm64 API-33-or-newer emulator on the arm64 `macos-15`
runner; iOS runs an arm64 Simulator on `macos-15`. A hosted VM is native execution for the
target ABI, but it is not physical-device evidence and does not close
GATE-NET-07. The mobile gate tests AWS-LC and Mbed TLS. OpenSSL remains a
desktop control as permitted by the candidate matrix.

Every successful result must bind the exact repository SHA, target triple,
runner image, emulator/Simulator identity, provider pin, static archives,
license manifest, capability statuses, metrics and bounded cleanup. A result
with missing native-runtime metadata, a failed or unexecuted capability, a
system TLS dependency, a stale SHA, or an unsafe license path is rejected.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | GitHub arm64 `macos-15` with Android SDK, API 33 arm64 image and pinned NDK | runner, ABI, API and NDK identity | reachable | Eligible Android VM gate. |
| P002 | GitHub `macos-15` arm64 with Xcode iOS Simulator | host architecture, SDK, runtime and device identity | reachable | Eligible iOS VM gate. |
| P003 | missing SDK/NDK/Xcode/ADB/simctl, wrong host, or unavailable VM | bounded failure result | reachable error | Must not be reported as PASS. |
| P004 | AWS-LC or Mbed TLS provider build | pinned source, target, archives and dependency scan | reachable | Provider controls are independent matrix cells. |
| P005 | OpenSSL mobile control | candidate-matrix policy | excluded | Desktop control remains sufficient for decision information. |
| P006 | complete provider PoC in the VM | capability, metrics and exit checks | reachable | Only zero-exit, complete capabilities can PASS. |
| P007 | Android staging path or iOS app container | path and ownership checks | reachable | No path traversal or unbounded staging. |
| P008 | result or license bundle is retained | schema, digest, source and matrix checks | reachable | One cell is updated atomically after review. |
| P009 | result, bundle or matrix is malformed, stale, or already different | fail-closed retention | reachable error | Existing managed evidence is never silently replaced. |
| P010 | physical device or HarmonyOS claim | platform boundary | excluded | Not inferred from hosted VM or cross-compilation. |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Android hosted VM | clean checkout | P001,P004,P006 | build, stage, run and validate the provider | arm64 ABI, API floor, exact SHA and all metrics | native-platform | P0 |
| S002 | iOS hosted Simulator | clean checkout | P002,P004,P006 | build, install, launch and validate the provider | arm64 host/runtime, exact SHA and all metrics | native-platform | P0 |
| S003 | absent or incorrect mobile toolchain | clean checkout | P003 | bounded FAIL result | stable stage and bounded message | negative | P0 |
| S004 | Android staging or iOS bundle lifecycle | valid binary and fixtures | P007 | execute once and clean up | no escaped path, app, process or emulator residue | lifecycle | P0 |
| S005 | complete AWS-LC/Mbed TLS capabilities | native VM | P004,P006 | PASS or explicit PARTIAL | no `NOT_RUN`/`FAIL` capability in a successful result | integration | P0 |
| S006 | OpenSSL mobile control | candidate matrix | P005 | remain outside mobile workflow | no false mobile PASS claim | policy | P1 |
| S007 | validated result and bundle | blocked matrix cell | P008 | copy and update exactly one cell | result/manifest digests and paths agree | evidence | P0 |
| S008 | path escape, symlink, digest drift, schema drift or wrong platform | retention input | P009 | reject without replacing managed evidence | stable failure code and old matrix bytes preserved | fault-injection | P0 |
| S009 | physical device, HarmonyOS, or cross-build only | no native environment | P010 | remain BLOCKED | no unsupported platform claim | boundary | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P004,P006 | Android matrix job | PASS/PARTIAL or bounded FAIL | runner, NDK, ABI, capabilities and cleanup | native-platform |
| T002 | S002 | P002,P004,P006 | iOS matrix job | PASS/PARTIAL or bounded FAIL | runner, SDK, runtime, capabilities and cleanup | native-platform |
| T003 | S003 | P003 | missing toolchain fixture | FAIL | stable provider-build stage and bounded output | fault-injection |
| T004 | S004 | P007 | staging/container lifecycle fixture | PASS | cleanup command and bounded paths | lifecycle |
| T005 | S005 | P004,P006 | provider result fixture | PASS/PARTIAL | schema-v11 metrics, no forbidden dependency | unit |
| T006 | S006 | P005 | workflow matrix inspection | PASS | only AWS-LC/Mbed TLS mobile cells; OpenSSL desktop control | static |
| T007 | S007 | P008 | validated artifact and blocked cell | PASS | atomic result, license tree and matrix update | integration |
| T008 | S008 | P009 | escape, symlink, stale, schema and write-failure mutations | FAIL | stable code; no partial matrix publication | fault-injection |
| T009 | S009 | P010 | hosted-VM and physical-device metadata mutations | FAIL/BLOCKED | `is_device` and platform boundary remain explicit | negative |

## Excluded gates

This bounded plan does not run an Android/iOS physical device, HarmonyOS, the
one-hour SSE profile, or the 86,400-second soak. It also does not build the
Cangjie SDK or modify runtime, `std`, `stdx`, or SDK sources.

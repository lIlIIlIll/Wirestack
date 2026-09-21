# M8-007 test plan: Linux release artifact and final evidence

This plan freezes the Linux x86_64 glibc candidate after M8-006. It rebuilds
the installable source-plus-pinned-native artifact, regenerates the API
baseline and supply-chain sidecars, and validates installation and security
properties against the exact artifact digest. The 86,400-second soak is a
separate explicit long gate and is never selected by fast, task or full checks.

## Semantics

| ID | Contract or failure scenario | Expected result |
|---|---|---|
| P001 | Reproducible Linux release artifact | Two archives from identical inputs are byte-identical; the release manifest records Linux x86_64 glibc, AWS-LC 5.5.0, payload and provider fingerprints. |
| P002 | Installed clean consumer | Extracted artifact builds and runs HTTPS client/server plus runtime/provider information through public APIs only. |
| P003 | API baseline regeneration | The final Linux public inventory is generated from current source, has a deterministic digest and a compatibility report bound to that baseline. |
| P004 | SBOM, license and NOTICE closure | SPDX 2.3, provider manifest, build fingerprint, Apache-2.0 license and AWS-LC LICENSE/NOTICE are bound to the artifact and have no host-local or secret data. |
| P005 | Security and dependency fail-closed checks | Architecture guard is zero; dependency scan rejects system OpenSSL, loader strings, unsafe archive members and missing metadata. |
| P006 | Final candidate resource soak | Only the frozen candidate artifact runs the 86,400-second mixed H1/H2/SSE/cancellation/churn workload; every resource trend and terminal owner is bounded. |
| P007 | Connection cancellation scope separation | HTTP/1 connection setup keeps the full operation context, while an HTTP/2 selected connection receives the connection token once and stream work excludes that token. |

## Fault-injection matrix

| ID | Injection | Expected result |
|---|---|---|
| S001 | Change one source/input between the two archive builds | Reproducibility or source digest validation fails; the old PASS is not reused. |
| S002 | Remove a release manifest, provider/resolver manifest or license/NOTICE member | Artifact qualification or supply-chain validation fails closed. |
| S003 | Add `libssl.so`, `libcrypto.so` or an OpenSSL loader string to payload/consumer | Security/dependency validation fails; no PASS is recorded. |
| S004 | Change a public declaration without regenerating the M8 baseline/report | API compatibility report fails or becomes stale. |
| S005 | Tamper with SBOM/provider/fingerprint sidecar or artifact digest | Supply-chain bundle validation rejects the mismatch. |
| S006 | Extract an archive containing a link or path escape | Installation validator rejects the archive before consumer build. |
| S007 | Run the soak with a short duration or an older artifact digest | Long-gate report is INCOMPLETE/FAIL, never PASS. |
| S008 | Interrupt or time out the long gate | The report records FAIL and bounded diagnostics; no partial run is promoted to PASS. |
| S009 | Cancel one HTTP/2 connection whose operation context also contains that handle | The stream context is not cancelled a second time; the connection callback fans out once and all active exchanges still terminate. |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Result |
|---|---|---|---|
| T001 | P001,S001 | `python3 tools/m8_007_release.py --json` | PASS |
| T002 | P002,S002,S006 | Artifact qualification and clean-consumer smoke in `artifact-validation.json` | PASS |
| T003 | P003,S004 | `api-baseline.json` and `api-compatibility.json` | PASS |
| T004 | P004,S005 | `supply-chain-validation.json`, SPDX/provider/fingerprint sidecars | PASS |
| T005 | P005,S003 | `security-validation.json` and `python3 tools/architecture_guard.py --format json` | PASS |
| T006 | P006,S007,S008 | Explicit `scripts/check-long M8-007 --json` candidate soak | PASS only at >=86,400 seconds |
| T007 | P001..P005,S001..S006 | Native Linux `cjpm check`, `cjpm build`, task contract and artifact validation | PASS |
| T008 | P007,S009 | HTTP facade cancellation-scope regression and native HTTP test suite | PASS |

No non-Linux execution, one-hour SSE profile, or SDK build is part of this
task. A short diagnostic preflight may be run during development, but it is
not evidence for T006 and cannot promote the task to COMPLETE.

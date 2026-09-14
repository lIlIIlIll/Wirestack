# M8-006 Linux TLS context and hook qualification

Status: all fourteen acceptance commands PASS. Native provider-boundary execution, full repository checks, strict HTML documentation and browser verification are retained; commit binding is recorded separately in `evidence.json`.

Scope: Linux x86_64 glibc with AWS-LC 5.5.0. The plan covers immutable context versions, atomic store replacement, session partitioning, store-backed listener ownership, external signer and raw RSA decrypt hooks, test-only NSS key logging, typed failures, and the installed public consumer.

Exclusions: non-Linux execution, hardware-key devices, preemption of a blocking synchronous callback, performance, production key logging, publication, and the M8-007 final 86,400-second soak.

## Control-flow paths

| ID | Entry and branch | Observable result |
|---|---|---|
| P001 | Build a client or server context | The immutable context receives a nonzero process-local `contextVersion` and owns snapshots of private-key metadata |
| P002 | Snapshot or replace a client or server context store | One atomic snapshot governs each handshake. Replacement affects only later handshakes |
| P003 | Accept through a store-backed `TlsListener` | Accept and handshake share one `OperationContext`; the listener and accepted transport each have one owner |
| P004 | Resume after replacing either TLS context | A new context performs a full first handshake and resumes only its own-version state |
| P005 | Service an external signer or decryptor request | The callback runs outside the engine lock with the handshake context, then returns a bounded result or a typed failure |
| P006 | Configure and service `KeyLogSink` | Only an explicit test-keylog build emits bounded NSS traffic-secret records; release admission and packaging reject it |
| P007 | Build and run the installed public consumer | The extracted install compiles the complete native example and executes the requested profile without checkout imports |
| P008 | Enable native keylog capture during pending SNI selection | Capture can be enabled before selected-identity completion and key derivation; raw-output digests bind the real handshake proof |
| P009 | Hand a public context to a consumer without the configured service | Context use does not grant direct access to the raw RSA decryptor |

## Semantics

| ID | Paths | Input or state | Required assertion |
|---|---|---|---|
| S001 | P001 | Independent successful context builds | Built contexts have distinct nonzero process-local versions. Exhaustion rejection is a source-level guard, not an executed exhaustion test |
| S002 | P001 | Caller mutates or closes original private-key inputs after `build()` | The built context retains immutable certificates and a private-key metadata snapshot. Closing the source key does not invalidate the context |
| S003 | P002 | Hold the external signer while replacing both stores | Both in-flight handshakes finish with the old ALPN and identity; later handshakes use a complete replacement |
| S004 | P002,P003 | Active connection while both stores are replaced | The active connection keeps its original ALPN and transport ownership; later handshakes use the replacement |
| S005 | P003 | Listener close after one or more successful accepts | The listener closes its owned `TransportListener`; returned `TlsConnection` values remain independently owned |
| S006 | P004 | TLS 1.2 replacement | The replacement's first handshake is full and its next handshake resumes only a TLS 1.2 session with the same `contextVersion` |
| S007 | P004 | TLS 1.3 replacement | The replacement's first handshake is full and its next handshake resumes only a TLS 1.3 ticket with the same `contextVersion` |
| S008 | P004 | Same server, ALPN, trust, client identity, provider and security policy, but different context version | The old session is not offered to the replacement context |
| S009 | P005 | External signer success, exception, cancellation, or Deadline expiry inside the callback | The exact handshake context reaches the callback. User code runs outside the lock. Success completes once; failures retain typed TLS classification and abort the accepted transport |
| S010 | P005 | External decryptor configured on a client, PKCS#8 server identity, non-RSA external identity, or provider without capability | Context build rejects the hook with `InvalidHook` or `UnsupportedCapability` and the relevant `TlsCapability` |
| S011 | P005 | `ExternalDecryptionRequest` algorithm and ciphertext length boundaries | Only exact `RSA_RAW` and 1 through 1,024 ciphertext bytes are admitted; constructor and getter own copies. Native requests use the RSA key's full block size |
| S012 | P005 | Decrypt success, exception, cancellation, Deadline, or short result | Success requires the ciphertext's exact length. Wirestack clears the transferred output after native completion. All other outcomes fail closed with typed codes |
| S013 | P005 | TLS 1.2 static-RSA peer | The external peer restricts its cipher policy; Wirestack's configured cipher policy is not widened by the test |
| S014 | P006 | NSS line label, random, and secret boundaries | Label is 1 through 128 uppercase ASCII letters, digits, or underscores; random is exactly 32 bytes; secret is 1 through 64 bytes; getters return owned copies |
| S015 | P006 | TLS 1.2 and TLS 1.3 test-keylog handshakes | The sink receives `CLIENT_RANDOM` for TLS 1.2 and bounded handshake and traffic-secret labels for TLS 1.3 |
| S016 | P006 | Sink exception, cancellation, or Deadline | The handshake fails closed, does not retain exception secret material, and clears native and Cangjie temporary buffers |
| S017 | P006,P007 | Default release provider and explicit test-keylog provider | Production compiles out key logging. The test provider requires a separate non-default native output directory and is marked `test_only_key_log: true` |
| S018 | P006,P007 | Release collector sees `test_only_key_log` or `key-log` capability | Collection fails with the dedicated test-only secret-logging rejection |
| S019 | P007 | Release and keylog installed profiles | Release executes 13 scenarios. Keylog executes its existing 5 scenarios unchanged. Reports retain typed text or artifact digests for raw outputs and binaries |
| S020 | P008 | Enable capture during pending SNI selection, before installing the selected identity | The real native TLS 1.3 handshake has no pre-key records, emits bounded NSS records after key derivation, and rejects capture re-enabling after completion. This does not claim a Cangjie selector-policy test |
| S021 | P007,P009 | Compile a consumer that reads `TlsServerContext.externalDecryptor` and invokes `decrypt` directly | The vulnerable baseline compiles; the installed candidate rejects the unavailable context member |

## Test-plan matrix

| ID | Paths | Scenarios | Execution and evidence | Status |
|---|---|---|---|---|
| T001 | P001,P004,P005,P006 | S002,S008,S010,S011,S014 | [Internal TLS engine](engine-tests.json): 66 passed; [public TLS](tls-tests.json): 9 passed. Both reports retain the exact command and raw output; zero failures, errors or skips | PASS |
| T002 | P001,P002,P003,P004,P007 | S001,S002,S003,S004,S005,S006,S007,S008,S019 | [`native-release.json`](native-release.json), modes `versions12` and `versions13`, runs the [installed consumer](../../../examples/linux/m8_006/native_tls.cj). Both original keys close before use; held handshakes and active connections survive replacement; listener close preserves an accepted connection | PASS |
| T003 | P005,P007 | S009,S019 | [`native-release.json`](native-release.json), modes `sign-ok`, `sign-throw`, `sign-cancel`, and `sign-deadline` | PASS |
| T004 | P005,P007 | S010,S011,S012,S013,S019 | [`native-release.json`](native-release.json), modes `decrypt-ok`, `decrypt-throw`, `decrypt-cancel`, `decrypt-deadline`, `decrypt-short`, and `reject-non-rsa` | PASS |
| T005 | P006,P007 | S017,S018,S019 | [`native-release.json`](native-release.json), mode `release-keylog-rejected`, verifies production context rejection | PASS |
| T006 | P006,P007 | S014,S015,S016,S017,S018,S019 | [`native-keylog.json`](native-keylog.json) preserves the five modes `keylog12-ok`, `keylog13-ok`, `keylog13-throw`, `keylog13-cancel`, and `keylog13-deadline`; it also records the separate provider output and release-collector rejection | PASS |
| T007 | P001,P005,P006 | S008,S010,S011,S014 | [`TlsM8006ContextTest`](../../../src/internal/tls_engine/m8_006_test.cj) and [`TlsM8006ContractTest`](../../../src/tls/m8_006_test.cj) cover session partition, role and capability admission, RSA request ownership, and NSS record bounds | PASS |
| T008 | P007 | S019 | [`api-inventory.json`](api-inventory.json) exactly matches [`wirestack-linux-pre1-m8-006.json`](../../api/baselines/wirestack-linux-pre1-m8-006.json): 324 declarations and 114 aliases. This static inventory does not prove runtime ownership or callback behavior | PASS |
| T009 | P008 | S020 | The [native C program](../../../native/tls/aws_lc/tests/m8_006_keylog_boundary.c) passes a real TLS 1.3 handshake. [`native-keylog.json`](native-keylog.json) records its separate `provider_boundary`, typed source/stdout/stderr digests, and successful command exit | PASS |
| T010 | P001,P002,P003,P004,P005,P006,P007,P008 | S001,S002,S003,S004,S005,S006,S007,S008,S009,S010,S011,S012,S013,S014,S015,S016,S017,S018,S019,S020 | [All 14 commands](task-check.json) PASS. [Full check](full-check.json): 773 passed, 23 skipped. [Tooling](regression-tests.json): 254 passed. [Documentation](docs-report.json): symbols and parameters fully documented. [Browser proof](browser-smoke.json): six searched references and eight HTTP 200 responses, including both opaque context pages | PASS |
| T011 | P007,P009 | S021 | The [same escape consumer](security/external-decryptor-readback.cj.txt) compiles against the [baseline](security/baseline.json) and is rejected by the [candidate](security/candidate.json). The installed release harness retains this negative compilation as `public_context_authority` | PASS |

## Execution and evidence rules

Run the installed release profile with:

```text
python3 tools/m8_006_native_tls.py --profile release --report docs/evidence/M8-006/native-release.json
```

Run the isolated test-keylog profile with:

```text
python3 tools/m8_006_native_tls.py --profile keylog --report docs/evidence/M8-006/native-keylog.json
```

The runner must build a release archive, extract it outside the checkout import path, and compile the complete [`native_tls.cj`](../../../examples/linux/m8_006/native_tls.cj) consumer against that install. The release report must retain exactly 13 existing scenarios. The keylog report must retain exactly 5 existing scenarios.

A test-keylog provider must use an explicit non-default `--out-dir`. It may overlay only the extracted test install. The release collector must reject that provider. Keylog reports must keep `key_log_release_qualified: false` because PASS means the secret-logging exclusion works.

The provider test is separate from the five keylog scenarios. Its `provider_boundary` field identifies the native program, expected marker and typed raw-output digests; the corresponding command entry records exit status 0.

Buffer cleanup is also inspected in the native and Cangjie source. These tests do not provide memory-forensic proof or deterministic erasure of immutable, GC-managed `TlsKeyLogLine` storage and sink-retained copies.

A matrix row remains `PASS` only while its linked reports and raw logs agree with the source revision bound in `evidence.json`. M8-007 must run its own final 86,400-second candidate soak; this task does not qualify that release gate.

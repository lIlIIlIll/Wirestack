# M8-006 Linux TLS context and hook qualification

Status: all fourteen local acceptance commands PASS. Native provider boundary, full repository, strict documentation and browser evidence are retained. Commit-bound inputs and reports are recorded in [evidence.json](evidence.json).

The supported profile is Linux x86_64 glibc with AWS-LC 5.5.0. The [test plan](test-plan.md) maps the observed behavior. This qualification does not replace M8-007 release-artifact or final-soak evidence.

## Qualified implementation

- Every built client or server context has a nonzero, process-local `contextVersion`. Session keys include that version.
- `TlsClientContextStore` and `TlsServerContextStore` atomically replace the context used by future handshakes. Active handshakes and connections keep their original snapshot.
- A newly built context starts with a full handshake. Later connections can resume eligible sessions or tickets from that version.
- Context builders retain immutable certificate chains and copy PKCS#8 and external-key public metadata. Closing the source `PrivateKeyRef` clears its exportable data without invalidating an already built context.
- A store-backed `TlsListener` owns its transport listener. It snapshots the server context after transport acceptance and immediately before the TLS handshake. The returned `TlsConnection` owns the accepted transport.
- `ExternalSigner`, `ExternalDecryptor`, and `KeyLogSink` receive the handshake's `OperationContext`. User callbacks run outside the engine lock.
- Public contexts do not return configured decryptor or key-log sink objects. Possession of a context does not grant direct raw-RSA service authority; hooks remain in internal context state.
- Raw RSA decryption is limited to compatible RSA external or system signer server identities whose modulus-sized raw block is 1 through 1,024 bytes. Requests use only `RSA_RAW` and require an exact-size result. Wirestack clears the transferred result after native completion.
- Context admission and handshake failures use typed `TlsContextException` and `TlsEngineException` codes. No provider or native handle enters the public API.

## Observed qualification

| Gate | Observed result | Durable evidence state |
|---|---|---|
| Focused TLS packages | 75/75 passed, zero skipped or failed | [Public TLS](tls-tests.json): 9; [internal TLS engine](engine-tests.json): 66; both retain raw command output |
| [Installed release-profile consumer](native-release.json) | PASS, 13/13 scenarios | Retained report and raw stdout and stderr digests |
| [Isolated test-keylog consumer](native-keylog.json) | PASS, 5/5 scenarios | Retained report, separate test provider manifest, raw stdout and stderr digests |
| [Public API inventory](api-inventory.json) | PASS, 324 declarations and 114 resolved aliases | Exact match to [`wirestack-linux-pre1-m8-006.json`](../../api/baselines/wirestack-linux-pre1-m8-006.json) |
| [Native SNI/keylog boundary](native-keylog.json) | PASS, independent `provider_boundary` | Real TLS 1.3 handshake, pre-key queue checks, bounded NSS records and post-handshake rejection |
| [Full repository check](full-check.json) | PASS, 773 passed and 23 skipped | All 796 cases accounted for; zero failures or errors |
| [Selected tooling regressions](regression-tests.json) | PASS, 254 tests | Raw unittest output retained |
| [Compatibility classification](compatibility.json) | Two source breaks reproduced | Classification PASS does not mean backward compatibility |
| [Strict documentation](docs-report.json) | PASS, symbols and parameters both 100% documented | Separate HTML generation also passed |
| [Browser smoke](browser-smoke.json) | PASS, six searched/navigated symbols and eight HTTP 200 responses | Both context references omit hook objects; rendered text, served-byte digests and two visually checked WebP screenshots are retained |
| [Task aggregate](task-check.json) | PASS, 14/14 commands | Exact commands and raw output retained |
| [Documentation preflight](docs-preflight.json) | FAIL, `wirestack.tls` strict check returned 1 | Preserved failure. It is not relabeled as qualification |
| [Raw-RSA authority regression](security/candidate.json) | Public member access rejected by the installed candidate | The same [consumer](security/external-decryptor-readback.cj.txt) compiled against the [vulnerable baseline](security/baseline.json); baseline PASS means reproduction succeeded, not security qualification |
| [Provider archive integrity](security/provider-overlay-candidate.json) | Real test-keylog partial overlay rejected | The [baseline](security/provider-overlay-baseline.json) accepted the mismatch. `native-keylog.json` also rejects a same-length binary mutation with the production manifest unchanged |

The release-profile consumer builds from a fresh release archive extracted outside the source checkout. Its 13 scenarios cover TLS 1.2 and TLS 1.3 context replacement, version-local resumption, release keylog rejection, external signing success and failures, external raw RSA decryption success and failures, exact-size enforcement, and non-RSA admission rejection.

The keylog profile preserves the existing five scenarios unchanged. They cover TLS 1.2 NSS output, TLS 1.3 traffic-secret output, sink failure, cancellation, and Deadline. The test provider is compiled with key logging into a separate native output directory and overlaid only onto the extracted test install. The report records `test_only_key_log: true`. Its release-collector control passes because the collector rejects the test provider.

The archive-integrity correction reran both native profiles, the 254 tooling tests and the task's fast gates. Public Cangjie source, native provider source, API inventory and generated API documentation inputs were unchanged, so their prior full-check, documentation and browser results remain applicable. The real archive used by the partial-overlay reproduction has the same SHA-256 as the archive exercised by the passing keylog profile.

## Secret logging boundary

`KeyLogSink` contains TLS traffic secrets. `TlsKeyLogLine` accepts a 1 through 128 byte uppercase NSS label, an exact 32-byte client random, and a 1 through 64 byte secret. Production builds compile out the native keylog callback and do not advertise `TlsCapability.KeyLog`. The context builder rejects a sink when that capability is absent. Release collection rejects either `test_only_key_log: true` or a `key-log` capability.

The collector parses the manifest bytes captured in the release payload and binds its archive name, byte count and SHA-256 to the packaged static library before accepting production flags. The native gate covers both a same-length mutation and a real test-keylog archive copied beneath an unchanged production manifest. These are payload-integrity checks, not signed build attestation.

The separate [native C program](../../../native/tls/aws_lc/tests/m8_006_keylog_boundary.c) reaches pending SNI selection before enabling capture, installs the selected identity, and completes selection. It verifies an empty queue before key derivation, completes a real TLS 1.3 handshake, drains bounded NSS records, and rejects re-enabling capture after completion. The `provider_boundary` field retains the source and raw-output digests; its command entry records exit status 0. This is native boundary proof, not an end-to-end Cangjie selector-policy test.

## Ownership and callback limits

A successful external decrypt callback transfers its returned array to Wirestack. The callback must not retain, reuse, or mutate that array. Wirestack clears it on success and failure paths after callback return. Request getters return owned copies.

External callbacks receive the same absolute Deadline, cancellation token, and trace that entered the handshake. Wirestack checks the context before and after user code. Callback execution occurs outside the engine lock. This design does not preempt a synchronous callback that blocks without checking its context.

The native evidence uses an external process as the private-key service. It does not qualify a hardware-key device or a non-Linux key adapter.

Native queues and temporary decoding buffers are explicitly cleared. Immutable `TlsKeyLogLine` storage is GC-managed; sink-owned copies are the sink's responsibility. This record does not claim deterministic erasure of every managed secret copy or memory-forensic verification.

## Compatibility boundary

The [compatibility report](compatibility.json) compares the M8-005 and M8-006 inventories and retains executable minimal proofs. `TlsCapability` adds `ExternalDecryptor` and `KeyLog`; `TlsContextErrorCode` adds `InvalidHook`. The unchanged exhaustive clients compile and run with the baseline variants, then fail compilation with the new variants.

Update exhaustive matches and rebuild consumers. Public Cangjie context layouts also changed; binary compatibility was not qualified. The native C header preserves existing signatures and numeric values while adding entrypoints, but no mixed old-binary/new-library matrix was run. Inventory equality proves only the current snapshot, not backward or forward compatibility.

## Commit and release boundary

The [task manifest](../../../tools/tasks/M8-006.json) declares the fourteen acceptance commands. [task-check.json](task-check.json) records their aggregate result. The source revision, source inputs and required reports must match [evidence.json](evidence.json); exact-head CI and review remain publication gates.

```text
python3 tools/repository/repository_tooling.py --root . verify-evidence --task M8-006 --json
```

M8-007 must rebuild the final artifact and run a new 86,400-second candidate soak. No earlier M7 soak or development run substitutes for it.

No non-Linux execution, hardware-key device, synchronous callback preemption, performance result, release publication, or final soak is claimed by this record.

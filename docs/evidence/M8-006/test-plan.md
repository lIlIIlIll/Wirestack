# M8-006 test plan: TLS context versioning and external hooks

This plan covers immutable, provider-neutral TLS contexts on Linux x86_64
glibc. Context replacement changes only future handshakes; existing snapshots
and connections retain their context epoch. External decryptor and key-log
callbacks receive the caller's handshake `OperationContext` and do not create a
second deadline or cancellation owner.

## Semantics

| ID | Contract or failure scenario | Expected result |
|---|---|---|
| P001 | Immutable client/server context construction | A built context owns bounded policy, provider identity, callback references and a monotonically allocated version; builder mutation cannot change it. |
| P002 | Future-handshake-only replacement | `TlsClientContextStore` and `TlsServerContextStore` replace the snapshot used by future handshakes; a held old snapshot remains unchanged. |
| P003 | Versioned session and resumption state | Client session keys and server session identity material include the effective context version, so replacement cannot reuse stale identity/trust/security state. |
| P004 | External decryptor and key-log context inheritance | Callbacks are provider-neutral public contracts and receive the exact handshake `OperationContext`; no independent timeout, cancellation source or global callback state is created. |
| P005 | Provider-neutral Linux AWS-LC facade | Public TLS facade and context stores retain only provider-neutral contracts; AWS-LC remains behind the selected provider factory and the architecture guard reports no leakage. |
| P006 | Clean consumer boundary | An external consumer can build contexts, install hooks and replace a context through `wirestack.tls` only. |

## Fault-injection matrix

| ID | Injection | Expected result |
|---|---|---|
| S001 | Empty/oversized decrypt request, key-log label, random or secret | Construction fails with a bounded stable TLS context error; no unbounded allocation is accepted. |
| S002 | Mutate a builder after `build()` or retain an old store snapshot after `replace()` | Built context and old snapshot remain unchanged; only the store's next snapshot changes. |
| S003 | Replace context while a connection or session key is retained | Retained connection/key keeps its original provider/context epoch; new keys differ by version. |
| S004 | Invoke decryptor/key-log sink with a cancelled or deadline-bound operation | The callback observes the supplied operation state and does not invent a new timeout/cancellation owner. |
| S005 | Attempt to mix provider/context epochs | Session-key equality rejects the mismatch; provider factory and context ownership remain fail-closed. |
| S006 | Reintroduce an AWS-LC type into public/facade/TLS-core code | `tools/architecture_guard.py --format json` reports a violation and the task gate fails. |
| S007 | Clean consumer imports internal/native types or places test key logging in the release path | Consumer/build or architecture guard fails; no `SKIPPED` result is accepted as PASS. |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Result |
|---|---|---|---|
| T001 | P001,S001,S002 | `TlsContextVersioningTest` plus public context builder/store tests | PASS |
| T002 | P003,S003,S005 | `TlsContextSessionVersionTest` and session-key partition tests | PASS |
| T003 | P004,S004 | `TlsContextVersioningTest.externalHooksReceiveTheCallerOperationContext` | PASS |
| T004 | P005,S006 | `python3 tools/architecture_guard.py --format json` | PASS |
| T005 | P006,S007 | `python3 tools/m8_006_clean_consumer.py --json` | PASS |
| T006 | P001..P005,S001..S006 | `cjpm test src/tls --no-progress --no-color` on native Linux | PASS |
| T007 | P003,S003,S005 | `cjpm test src/internal/tls_engine --no-progress --no-color` on native Linux | PASS |
| T008 | P001..P006,S001..S007 | `cjpm check` and `cjpm build` with the selected Linux AWS-LC provider | PASS |

No non-Linux run, one-hour SSE profile, or 86,400-second soak is run by this
task. M8-007 owns final release-artifact regeneration and the candidate long
gate.

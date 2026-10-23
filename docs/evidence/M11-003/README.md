# M11-003: ws/wss URL and bounded WebSocket lifecycle

**BLOCKED — no receipt under this directory binds the current sources.
Source-bound evidence must be regenerated before this task can return to COMPLETE.**
Issue [#180](https://github.com/lIlIIlIll/Wirestack/issues/180).
[Current source status](verification.json), [task inventory](../../../tools/tasks/M11-003.json),
and [historical receipts](historical/README.md).

The task inventory is authoritative for what this task owns. `tools/tasks/M11-003.json`
now lists every non-evidence file the merged owner PR #206 changed. Two inputs had
been omitted: `.gitignore` and
`src/internal/http1/proxy_literal_connect_deadline_test.cj`, the test that was
updated for the new TLS reference identity. Both are bound in `allowed_paths` and
`source_paths`, so a sealed record hashes every changed file. This round's new
regression sources are bound the same way.

## Review fixes on this branch

Historical owner PR #206 is merged and is not rewritten. Issues #278-#282 were
still true against `d496a242fec98cc3271f8f71b5a79a3aba60feea`; this branch repairs
them at current source.

| Issue | Current-source defect | Repair |
|---|---|---|
| [#278](https://github.com/lIlIIlIll/Wirestack/issues/278) | With an application writer active and a caller close queued, an inbound Ping or Close reply threw `CapacityExceeded` after its bytes were consumed, so the session aborted without the required reply. A caller close also wrote its close frame before reader admission, so a rejected third reader wrote bytes and terminated a usable session. | `src/http/websocket.cj` gives protocol replies one reserved writer slot and caller close frames their own reserved slot. The application writer yields both before taking the active writer. `closeWithContext` reserves the reader before any close-frame byte, so a rejected close is side-effect free. One active plus one pending operation per direction is unchanged; only the two protocol-reserved slots are additional, bounded and single-entry. |
| [#279](https://github.com/lIlIIlIll/Wirestack/issues/279) | With HTTP/2 push enabled, a cancellation that won after the rejected CONNECT response was published made `retainLifetime()` throw, after `RequestCompleted/Succeeded` had already been emitted; the catch then emitted a failure, giving one request two terminal events. | `src/http/client.cj` wraps the response and retains its lifetime before publishing completion. A winning cancellation therefore reaches the single failure path and produces exactly one terminal event. |
| [#280](https://github.com/lIlIIlIll/Wirestack/issues/280) | When cancellation or the TCP deadline won while a custom connector was returning, a throwing `abort` replaced the canonical stop with `SystemFailure`. | `src/internal/connector/happy_eyeballs.cj` isolates the abort failure, keeps it as the cause, and still reports the canonical `Cancelled`/`TimedOut` connect exception, which drives the stopped-attempt event. |
| [#281](https://github.com/lIlIIlIll/Wirestack/issues/281) | Both `HttpCancellationHandles.retainCancellation` once-gate tests were removed with no replacement. | `src/http/facade_test.cj` restores both tests next to the authority canonicalization case and adds a concurrent three-handle case. |
| [#282](https://github.com/lIlIIlIll/Wirestack/issues/282) | `src/internal/http1/proxy_literal_connect_deadline_test.cj` was modified by the owner PR but absent from `source_paths`, so a seal could report COMPLETE without hashing it. | `tools/tasks/M11-003.json` binds that test, `.gitignore` and this round's regression sources. `tools/tests/test_m11_003_evidence_inventory.py` fails if the owner-PR change set is not fully covered. |

## Current regressions

| Finding | Regression |
|---|---|
| #278 | `WebSocketConnectionTest.rejectedCloseWritesNoFrameAndLeavesTheSessionUsable`; `WebSocketConnectionTest.reservedReplySurvivesABlockedApplicationWriterAndWaitingClose` |
| #278 | `WebSocketConnectionTest.terminalCleanupRunsExactlyOnceAfterGracefulCloseAndAfterFailure` (exactly one terminal transport call after graceful close, after transport failure and across a four-way close race) |
| #279 | `HttpUpgradeTerminalOrderingTest.cancellationWinningBeforeTheWrapYieldsExactlyOneFailedCompletion` |
| #280 | `HappyEyeballsConnectorTest.literalCleanupFailureKeepsCanonicalCancellationAndCause`; `HappyEyeballsConnectorTest.literalCleanupFailureKeepsCanonicalDeadlineAndCause` |
| #281 | `HttpCancellationHandlesCallbackTest.retainedCallbackRunsAtMostOnceAcrossSequentialCancellations`; `retainedCallbackRunsAtMostOnceWhenHandlesWereAlreadyCancelled`; `concurrentHandleCancellationRunsTheGateExactlyOnce` |
| #282 | `tools/tests/test_m11_003_evidence_inventory.py` |

These cases exist in source. **Their outcomes are not claimed here**: no Cangjie
toolchain was available in this environment, so nothing in this branch was
compiled, executed, installed or documented by a gate.

## What is not covered

Every receipt that previously sat at this path — the native regression log,
installed consumers for SDK 1.3.0-alpha.06 and 1.1.3, strict docs report, public
API report, task gate, workspace receipt, scenario matrix and the earlier
verification index — was moved byte-for-byte to [historical/](historical/README.md).
It describes the 2026-10-09 working tree and is **not** current validation.

No commit, push, PR, merge or issue mutation was performed by this branch's
authoring step; the branch is task-scoped and awaits integration. Native Linux
x86_64 glibc remains the only contemplated platform, and this branch makes no
platform, release, ABI or performance claim.

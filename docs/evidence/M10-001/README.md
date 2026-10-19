# M10-001 — unified total deadline and stream progress

**Status:** COMPLETE for the task's declared Linux x86_64 glibc target. No other platform qualification is claimed.

## Delivered contract

- Public `OperationTimeoutPolicy` supplies optional, positive limits for request admission, connection-pool wait, DNS, TCP connect, proxy, TLS handshake, request write, response headers, body-read idle, and stream-read idle.
- `OperationContext.forStage` derives each stage deadline beneath the parent absolute deadline. A stage cap cannot extend the parent; retries, redirects, DNS retries, and address candidates retain the same request operation.
- Body-read idle begins when the application reads, so time processing an already-delivered chunk is not reported as remote inactivity. HTTP/2 body idleness belongs to the target stream; sibling traffic and connection activity do not refresh it.
- Existing `HttpClientBuilder.requestTimeout` semantics are unchanged. The public guide explains migration, phase limits, SSE body reads, WebSocket reads, and how to omit a total deadline while retaining phase and active-read limits.
- Deadline and cancellation failures retain structured codes/phases. EOF remains an EOF result. Body abandonment and TLS/connection cleanup remain exactly-once.

## Acceptance evidence

| Acceptance area | Evidence |
|---|---|
| Parent-capped stage budgets | `src/internal/transport/operation_context_test.cj` uses a controllable monotonic clock to verify independent stage caps, retry-stage derivation, and total-deadline clamping. |
| Admission before network work | `deadlineAdmissionRemovesWaiterWithoutGrantingResource` proves deadline expiry removes the waiter without granting the resource. `HttpClient.sendInternal` acquires the request lease before `executeWithRetries`, so an admission error exits before DNS/connect dispatch. `preCancelledParentStartsNeitherDnsNorAttempts` verifies the preflight network boundary. |
| DNS, retries, redirects, and connect completion | `retryCannotRestartTheOriginalAbsoluteDeadline` and `redirectCannotRestartTheOriginalAbsoluteDeadline` advance a fake clock through resolver retries/redirects and assert the original expiry is retained. `deadlineAtSuccessBoundaryPreventsWinnerPublication` rejects a connection success after the parent deadline. |
| TLS completion/cancellation boundary | `cancellationAtTlsHandshakeCompletionBoundaryWinsDeterministically` cancels during a fake engine step that reports handshake completion; the caller observes one structured handshake-cancel result and no transport I/O. |
| Body progress and terminal races | `bodyReadIdleStartsWhenTheCallerBeginsReading` and `timeoutAndCancellationRaceAbandonsBodyExactlyOnce` pass. The race asserts one body abandonment after timeout/cancellation and after close. |
| HTTP/2 per-stream behavior and native wakeup | `publicHttp2BodyIdleDeadlineIgnoresSiblingResponses` runs a local TLS/HTTP/2 server over the Linux native transport: sibling responses complete while the stalled target stream reaches its own idle timeout. This is native loopback evidence, not a mock-only test. |
| Close/reset and exception cleanup | `closeDeadlineExpiresWhileAnExistingBackgroundReadOwnsPumpAdmission`, `closeCancellationInterruptsAnExistingBackgroundReadWithinTheBound`, and `racingLocalAndPeerResetCompletesEveryStreamExactlyOnce` pass in the full suite. |
| Public examples and migration | [`docs/guides/http1-linux.md`](../../guides/http1-linux.md) documents unchanged `requestTimeout`, stage-specific configuration, SSE/WebSocket reads, and the distinction between response-body activity and decoded SSE business events. An SSE event-level watchdog is intentionally deferred until the SSE codec/session task, consistent with issue #173's non-goal. |

## Timing and cleanup measurements

The final Cangjie run recorded these test-case wall times (including fixture setup and cleanup; they are not isolated callback-to-return latency measurements):

- `timeoutAndCancellationRaceAbandonsBodyExactlyOnce`: 49,933,499 ns.
- `bodyReadIdleStartsWhenTheCallerBeginsReading`: 64,385,695 ns.
- `cancellationAtTlsHandshakeCompletionBoundaryWinsDeterministically`: 77,747 ns.
- `publicHttp2BodyIdleDeadlineIgnoresSiblingResponses`: 972,913,862 ns.

The deadline path does not allocate a scheduled timer handle: it passes the remaining absolute duration to the blocking wait/native operation. In the `MemoryTransport` blocked-read fixture, source-derived counts are one active cancellation registration and one condition waiter; the `finally` path unregisters the registration. These are per-read source-derived counts, not runtime aggregate telemetry. The admission test observes zero waiters after expiry and confirms the held request was not granted. No end-to-end latency SLA or process-wide timer/registration metric is claimed.

## Verification

- Prescribed SDK `cjpm check`: exit 0.
- Prescribed SDK `cjpm build`: exit 0.
- Prescribed SDK `cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color`: exit 0; 863 total, 840 passed, 23 skipped, 0 errors, 0 failures. The final run includes the TLS completion/cancellation regression.
- `scripts/check`: exit 1, unrelated repository baseline failures: 8 M7-030 tests cannot read the absent M7-021 Linux archive; one M7 task-graph test derives 16 unique IDs while the published count is 15. The run reports 497 tests, 8 errors, 1 failure.
- `scripts/check-code`: exit 1. The architecture guard and root API documentation pass (688/688 symbols and 275/275 parameters); the HTTP package documentation check reports existing undocumented `value` parameters in `src/http/client.cj` and `src/http/server.cj`. No M10 HTTP signature change is implicated.
- Only the declared native Linux x86_64 glibc environment was exercised. Cross-platform behavior is not inferred from this run.

## Review follow-up

The review regression run covers literal proxy TCP-connect budgets, reuse of one response-header budget across a `100-continue` body write, HTTP/2 flow-control updates under the total deadline, and retention of flow-control update-write failures. Stack #200 follow-ups add post-read context checks for HTTP/1 headers/body/upgrades, terminal HTTP/2 ticket waits, late literal proxy success, and WebSocket stream reads. Exact commands and results: [review-deadline-regressions.md](review-deadline-regressions.md).

The additional follow-up tests ran on the available wrapper toolchain (Cangjie 1.3.0-alpha.20261010001050, CJPM 1.3.0-alpha.06) as focused smoke checks. They do not replace or repeat the original full acceptance run on SDK 1.1.3.

## Workspace snapshot (initial task capture; historical)

- GitButler workspace view: `gitbutler/workspace`; the M10-001 changes remain uncommitted in the workspace, and the named `m10-001-unified-deadline` branch has no task commits. HEAD: `b2ab351ab3ee`; merge base with `main`: `00d6864f5d`.
- Existing unrelated dirty paths `.gitignore` and `tools/docs/m7_033_docs.py` were preserved. M10 source, guide, evidence, and status changes remain uncommitted. No commit, push, or PR was created.

# M10-001 review regression tests

SDK: Cangjie STS 1.1.3. Target: `x86_64-unknown-linux-gnu`.

The commands below were run after sourcing `$HOME/cangjie_sdk/sts1.1.3/envsetup.sh`; `TMPDIR`, `TMP`, and `TEMP` pointed to a disk-backed task-owned directory (normalized as `<task-tmp>`).

## HTTP/1

```sh
cjpm test src/internal/http1 --filter=Http1LiteralProxyDialDeadlineReviewTest.forwardProxyLiteralDialUsesTcpConnectBudget,Http1LiteralProxyDialDeadlineReviewTest.forwardProxyLiteralDialAppliesTcpConnectCapWithoutCallerDeadline,Http1LiteralProxyDialDeadlineReviewTest.httpsProxyLiteralDialAppliesTcpConnectCapWithoutCallerDeadline,Http1HttpsProxyDialCapReviewTest.httpsLiteralProxyDialTimesOutAtTcpConnectCap,Http1ResponseHeaderBudgetReviewTest.expectContinueRetainsOneResponseHeadersBudgetAcrossBodyWrite,Http1ResponseHeaderBoundaryReviewTest.responseHeaderBudgetExpiryBeforeContinueDoesNotSendBody,Http1ResponseHeaderBoundaryReviewTest.finalResponseWithinOriginalHeaderBudgetAfterContinueBodyWriteSucceeds --no-color --no-progress
```

Exit: 0. `TOTAL: 157`; `PASSED: 7`; `SKIPPED: 150`; `ERROR: 0`; `FAILED: 0`.

## HTTP/2 failing-before reproduction

Before the WINDOW_UPDATE write-context fix, the event-sink-enabled regression failed while the writer exceeded the short body-idle cap:

```sh
cjpm test src/internal/http2 --filter=Http2ClientBodyUpdateReviewTest.bodyWindowUpdatesUseTotalBudgetInsteadOfInboundIdleBudget --no-color --no-progress
```

Exit: 1. `TOTAL: 198`; `PASSED: 0`; `SKIPPED: 197`; `ERROR: 1`. Error: `NetworkException: HTTP/2 writer deadline exceeded`.

## HTTP/2 fixed

```sh
cjpm test src/internal/http2 --filter=Http2ClientBodyUpdateReviewTest.bodyWindowUpdatesUseTotalBudgetInsteadOfInboundIdleBudget,Http2ClientBodyUpdateReviewTest.bodyWindowUpdateWriteFailuresAreRetained --no-color --no-progress
```

Exit: 0. `TOTAL: 198`; `PASSED: 2`; `SKIPPED: 196`; `ERROR: 0`; `FAILED: 0`.

## Stack #200 terminal-boundary follow-ups

These focused deterministic tests cover successful transport returns that arrive after their operation context stopped. They were run on Linux x86_64 with the available wrapper toolchain: Cangjie compiler `1.3.0-alpha.20261010001050`, CJPM `1.3.0-alpha.06`. This is smoke evidence only; it is not a repeat of the full task qualification on SDK 1.1.3. Commands below use normalized `<repo>`, `<task-tmp>`, and `<qualified-wrapper>` placeholders. Each invocation set `TMPDIR`, `TMP`, and `TEMP` to `<task-tmp>` and `DISABLE_ZOXIDE=1`.

### Failing-before reproductions

HTTP/1 headers, body reads, and upgraded reads failed before the post-read context check:

```sh
<qualified-wrapper> --cwd <repo> -- cjpm test src/internal/http1 \
  --filter=Http1LateReadDeadlineReviewTest.responseHeadersReturnedAfterBudgetExpiryAreRejected,Http1LateReadDeadlineReviewTest.responseBodyBytesReturnedAfterIdleExpiryAreRejected,Http1LateReadDeadlineReviewTest.upgradedBytesReturnedAfterIdleExpiryAreRejected \
  --no-color --no-progress
```

Exit: 1. Three selected cases failed because no `api.NetworkException` was thrown after the fake transport advanced the clock and returned bytes.

The literal proxy dial and terminal HTTP/2 ticket wait had the same completion-boundary failure:

```sh
<qualified-wrapper> --cwd <repo> -- cjpm test src/internal/http1 \
  --filter=Http1LiteralProxyLateSuccessReviewTest.lateLiteralProxyDialIsRejectedBeforeRequestAndSuccessEvent \
  --no-color --no-progress
```

Exit: 1. The selected case failed because late literal proxy success was returned without a `NetworkException`.

```sh
<qualified-wrapper> --cwd <repo> -- cjpm test src/internal/http2 \
  --filter=Http2WriteSchedulerTest.completedTicketWaitRejectsAnExpiredContext \
  --no-color --no-progress
```

Exit: 1. The selected case failed because a completed ticket returned despite its expired wait context.

The WebSocket regression uses a valid masked client text frame. Without the post-read check, the late payload was accepted:

```sh
<qualified-wrapper> --cwd <repo> -- cjpm test src/http \
  --filter=WebSocketLateReadDeadlineReviewTest.successfulBytesAfterStreamIdleAreNotPublished \
  --no-color --no-progress
```

Exit: 1. `@AssertThrows` reported that no `WebSocketException` was raised after the fake transport advanced the stream-read-idle clock and returned the payload.

### Fixed focused runs

```sh
<qualified-wrapper> --cwd <repo> -- cjpm test src/internal/http1 \
  --filter=Http1LateReadDeadlineReviewTest.responseHeadersReturnedAfterBudgetExpiryAreRejected,Http1LateReadDeadlineReviewTest.responseBodyBytesReturnedAfterIdleExpiryAreRejected,Http1LateReadDeadlineReviewTest.upgradedBytesReturnedAfterIdleExpiryAreRejected,Http1LiteralProxyLateSuccessReviewTest.lateLiteralProxyDialIsRejectedBeforeRequestAndSuccessEvent \
  --no-color --no-progress
```

Exit: 0. `TOTAL: 169`; `PASSED: 4`; `SKIPPED: 165`; `ERROR: 0`; `FAILED: 0`.

```sh
<qualified-wrapper> --cwd <repo> -- cjpm test src/internal/http2 \
  --filter=Http2WriteSchedulerTest.completedTicketWaitRejectsAnExpiredContext \
  --no-color --no-progress
```

Exit: 0. `TOTAL: 204`; `PASSED: 1`; `SKIPPED: 203`; `ERROR: 0`; `FAILED: 0`.

```sh
<qualified-wrapper> --cwd <repo> -- cjpm test src/http \
  --filter=WebSocketLateReadDeadlineReviewTest.successfulBytesAfterStreamIdleAreNotPublished \
  --no-color --no-progress
```

Exit: 0. `TOTAL: 163`; `PASSED: 1`; `SKIPPED: 162`; `ERROR: 0`; `FAILED: 0`.
## Stack #200 T1–T5 focused replay on SDK 1.1.3

All commands below used the qualified SDK wrapper with `TMPDIR`, `TMP`, and `TEMP` set to `<task-tmp>`, and `DISABLE_ZOXIDE=1`.

The T4 and T5 red runs used the new regression tests before their production fixes. The first combined green run used the composite GitButler stack workspace, including the M10-002 child changes. The exact M10-001 candidate replay is recorded in [review-regressions.json](stack-200-review/review-regressions.json).

### T4: one HTTP/1 RequestWrite budget across head and body

Failing before the production change:

```sh
<qualified-wrapper> --sdk-root <qualified-sdk> --cwd <repo> -- \
  cjpm test src/internal/http1 \
  --filter=Http1RequestWriteBudgetReviewTest.completeRequestReusesOneRequestWriteBudgetForHeadAndBody \
  --no-color --no-progress
```

Exit: 1. The selected assertion failed because `Http1RequestWriteException` was not thrown; the request-body writer received a restarted stage budget.

After the change, the same command exited 0: `TOTAL 170`, `PASSED 1`, `SKIPPED 169`, `ERROR 0`, `FAILED 0`.

### T5: transferred push retains parent cancellation context

Failing before the production change:

```sh
<qualified-wrapper> --sdk-root <qualified-sdk> --cwd <repo> -- \
  cjpm test src/http \
  --filter=HttpFacadeTest.requestCancellationOutlivesCompletedParentWhileTransferredPushStalls \
  --no-color --no-progress
```

Exit: 1. The selected real TLS HTTP/2 integration case errored with `NoneValueException` when checking the transferred response's missing `operationContext`.

After the change, the same command exited 0: `TOTAL 165`, `PASSED 1`, `SKIPPED 164`, `ERROR 0`, `FAILED 0`. The test also verifies typed cancellation stops the pushed body while a sibling request remains healthy.

### Combined owner regressions

```sh
<qualified-wrapper> --sdk-root <qualified-sdk> --cwd <repo> -- \
  cjpm test src/internal/http1 src/internal/http2 src/http \
  --filter=Http1LateReadDeadlineReviewTest.responseHeadersReturnedAfterBudgetExpiryAreRejected,Http1LateReadDeadlineReviewTest.responseBodyBytesReturnedAfterIdleExpiryAreRejected,Http1LateReadDeadlineReviewTest.upgradedBytesReturnedAfterIdleExpiryAreRejected,Http1LiteralProxyLateSuccessReviewTest.lateLiteralProxyDialIsRejectedBeforeRequestAndSuccessEvent,Http2WriteSchedulerTest.completedTicketWaitRejectsAnExpiredContext,WebSocketLateReadDeadlineReviewTest.successfulBytesAfterStreamIdleAreNotPublished,Http1RequestWriteBudgetReviewTest.expectContinueReusesOneRequestWriteBudgetForHeadAndBody,Http1RequestWriteBudgetReviewTest.completeRequestReusesOneRequestWriteBudgetForHeadAndBody,HttpFacadeTest.requestCancellationOutlivesCompletedParentWhileTransferredPushStalls \
  --no-color --no-progress
```

Exit: 0. `TOTAL 539`, `PASSED 9`, `SKIPPED 530`, `ERROR 0`, `FAILED 0`. This is focused regression evidence, not a rerun of the full M10-001 acceptance suite or a release qualification.

### Exact-head full-suite observation on SDK 1.1.3

At earlier exact source revision `935351da4880f2d4e1be963100ca19146ea8b6f5`, the nine T1–T5 focused regressions passed: `TOTAL 537`, `PASSED 9`, `SKIPPED 528`, `ERROR 0`, `FAILED 0`.
The evidence-registration candidate `6223022ef3943437596ad9fedcd8571b975a382e` changes only evidence, task-manifest, and ignore metadata from that source. The same focused command was rerun on that exact candidate and passed with the same counts. The separate composite-stack run in the preceding section included the M10-002 child and is not the M10-001 candidate result.

The complete HTTP package run returned exit 1:

```sh
<qualified-wrapper> --sdk-root <qualified-sdk> --cwd <candidate> -- \
  cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color \
  src/internal/http1 src/internal/http2 src/http
```

Result: `TOTAL 537`, `PASSED 530`, `SKIPPED 6`, `ERROR 0`, `FAILED 1`. The failure was `HttpClientExtensionsTest.closingClientWakesStalledConnectorConnectionAdmission`; `secondRejected` was false at its assertion.

The isolated case passed on source revision `935351da4880f2d4e1be963100ca19146ea8b6f5`, then passed again on evidence-registration candidate `6223022ef3943437596ad9fedcd8571b975a382e`: `TOTAL 163`, `PASSED 1`, `SKIPPED 162`, `ERROR 0`, `FAILED 0`.

The M10-002 Stack #200 follow-up report records an earlier full `src/http` failure at this same case, an isolated pass, and a subsequent full-suite pass. Treat the M10-001 full-suite result as an observed intermittent failure, not a pass; its cause is not established. M10-001 does not change the resource-admission implementation or this test. At exact candidate source revision `6223022ef3943437596ad9fedcd8571b975a382e`, all listed applicable GitHub checks passed; the latest-main documentation deployment was skipped by its workflow. This focused follow-up does not replace the historical full M10-001 acceptance or requalify other platforms.

## Current-source follow-up: late final response after `100-continue`

The original follow-up test at `97cac410c727b301e1f85a0b8e61595980292287`
asserted that a final HTTP 417 arriving after the short `100-continue` wait
should fail with a deadline error. Review showed that this consumed response
must instead be returned when it arrives within the longer response-header
budget. The replacement regression,
`Http1LateReadDeadlineReviewTest.lateFinalResponseAfterContinueDeadlineIsReturnedWithoutRequestBody`,
asserts status 417 and zero request-body bytes. The implementation is
`18a2b9a79b0b8886db8bfae3fdd48184ff45d23c`.

All commands used pinned Cangjie/CJPM 1.1.3 via `<qualified-wrapper>`, with
`TMPDIR`, `TMP`, and `TEMP` set to `<task-tmp>` and `DISABLE_ZOXIDE=1`.

Focused regression:

```sh
<qualified-wrapper> --sdk-root <qualified-sdk> --cwd <repo> -- \
  cjpm test --no-progress --no-color \
  --filter=Http1LateReadDeadlineReviewTest.lateFinalResponseAfterContinueDeadlineIsReturnedWithoutRequestBody \
  src/internal/http1
```

Exit 0. `TOTAL 171`, `PASSED 1`, `SKIPPED 170`, `ERROR 0`, `FAILED 0`.

Current-source architecture guard, network capability contract, `cjpm check`,
and `cjpm build` each exited 0 on `18a2b9a79b0b8886db8bfae3fdd48184ff45d23c`.

Full HTTP package suite:

```sh
<qualified-wrapper> --sdk-root <qualified-sdk> --cwd <repo> -- \
  cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color \
  src/internal/http1 src/internal/http2 src/http
```

Exit 1. `TOTAL 538`, `PASSED 531`, `SKIPPED 6`, `ERROR 1`, `FAILED 0`.
`Http2ConnectionPoolTest.saturatedCrossOriginWaiterDrainsHttp2ConnectionBeforeSameKeyRefill`
raised `TimeoutException` at `src/internal/http1/http2_connection_pool_test.cj:456`.
This is a current full-suite blocker; its cause is not established.

The previous run at `97cac410c727b301e1f85a0b8e61595980292287` passed 532/538,
but its then-current finding-6 test asserted the incorrect timeout behavior;
that result does not validate the corrected late-response contract. An earlier
full-suite run at `935351da4880f2d4e1be963100ca19146ea8b6f5` separately failed at
`HttpClientExtensionsTest.closingClientWakesStalledConnectorConnectionAdmission`;
the isolated case passed, and the cause remains unexplained.

Documentation checks were run at `97cac410c727b301e1f85a0b8e61595980292287`:
`scripts/check-docs --json` exited 1 after all seven package checks passed,
because combined CJDoc could not allocate 9,186,376 bytes. The retry
`env cjHeapSize=1GB scripts/check-docs --json` exited 0; all seven package
layers passed with 1,873/1,873 API symbols and 950/950 parameters.

The task-gate preflight on `18a2b9a79b0b8886db8bfae3fdd48184ff45d23c` returned
`INVALID` (exit 2) before executing commands: M10-004 is not COMPLETE because
M10-003 is BLOCKED. This is a dependency blocker, not a passing task acceptance.

## Additional review regressions at source `3e65a74dfa1db865c78a3cce91c547eb02a110fb`

The review follow-up now checks three missing boundaries:

- `Http1PrefixedTransport.readSome` rejects buffered prefix bytes after the
  `StageStarted` event advances the stream-idle clock, and rejects an empty read
  when the delegate state check crosses the deadline.
- A literal-proxy dial that is cancelled while connecting retains the
  structured `Cancelled / TcpConnect` result even when abort cleanup throws.
- The request-write budget case completes its 5 ms head inside a 6 ms cap, then
  rejects a 2 ms body rather than restarting the cap.

The focused replay passed 13 cases across HTTP/1, HTTP/2 and HTTP:

```sh
TMPDIR=<task-tmp> TMP=<task-tmp> TEMP=<task-tmp> DISABLE_ZOXIDE=1 \
WIRESTACK_AWS_LC_SOURCE=<task-tmp>/aws-lc-5.5.0 \
  "${HOME}/.codex/scripts/codex_cangjie_env" --cwd <repo> -- \
  cjpm test src/internal/http1 src/internal/http2 src/http \
  --filter=Http1LateReadDeadlineReviewTest.responseHeadersReturnedAfterBudgetExpiryAreRejected,Http1LateReadDeadlineReviewTest.lateFinalResponseAfterContinueDeadlineIsReturnedWithoutRequestBody,Http1LateReadDeadlineReviewTest.responseBodyBytesReturnedAfterIdleExpiryAreRejected,Http1LateReadDeadlineReviewTest.upgradedBytesReturnedAfterIdleExpiryAreRejected,Http1UpgradedReadBudgetReviewTest.prefixBytesReturnedAfterStreamIdleExpiryAreRejected,Http1UpgradedReadBudgetReviewTest.emptyReadRechecksDeadlineAfterTransportStateCheck,Http1LiteralProxyLateSuccessReviewTest.lateLiteralProxyDialIsRejectedBeforeRequestAndSuccessEvent,Http1LiteralProxyLateSuccessReviewTest.cancellationWhileLiteralProxyDialingIsPreservedIfAbortFails,Http2WriteSchedulerTest.completedTicketWaitRejectsAnExpiredContext,WebSocketLateReadDeadlineReviewTest.successfulBytesAfterStreamIdleAreNotPublished,Http1RequestWriteBudgetReviewTest.expectContinueReusesOneRequestWriteBudgetForHeadAndBody,Http1RequestWriteBudgetReviewTest.completeRequestReusesOneRequestWriteBudgetForHeadAndBody,HttpFacadeTest.requestCancellationOutlivesCompletedParentWhileTransferredPushStalls \
  --no-color --no-progress
```

Exit 0. `TOTAL 558`, `PASSED 13`, `SKIPPED 545`, `ERROR 0`, `FAILED 0`.
Toolchain: Cangjie 1.3.0-alpha.20261020001052, CJPM 1.3.0-alpha.07.
The provider override was verified as AWS-LC 5.5.0 commit
`991e67ff4cf04df4dd89e407f8b920c6936cb56a`, tree
`ae54cd9455f9630451d505855afe808a9f028b25`.

The attempted pre-fix replay could not reach compilation because the default
ignored provider checkout was empty. After materializing the exact pinned
provider in task-owned temporary storage, the focused replay above passed on
the fixed source. No failing-before assertion is claimed. This replay does not
run the full HTTP suite, `scripts/check`, or the M10-001 task gate.

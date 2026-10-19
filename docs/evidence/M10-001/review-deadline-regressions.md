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

At candidate source revision `935351da4880f2d4e1be963100ca19146ea8b6f5`, the nine T1–T5 focused regressions passed: `TOTAL 537`, `PASSED 9`, `SKIPPED 528`, `ERROR 0`, `FAILED 0`.

The complete HTTP package run returned exit 1:

```sh
<qualified-wrapper> --sdk-root <qualified-sdk> --cwd <candidate> -- \
  cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color \
  src/internal/http1 src/internal/http2 src/http
```

Result: `TOTAL 537`, `PASSED 530`, `SKIPPED 6`, `ERROR 0`, `FAILED 1`. The failure was `HttpClientExtensionsTest.closingClientWakesStalledConnectorConnectionAdmission`; `secondRejected` was false at its assertion.

The isolated rerun of that case on the same candidate exited 0: `TOTAL 163`, `PASSED 1`, `SKIPPED 162`, `ERROR 0`, `FAILED 0`.

The M10-002 Stack #200 follow-up report records an earlier full `src/http` failure at this same case, an isolated pass, and a subsequent full-suite pass. Treat the current result as an observed intermittent failure, not a pass; its cause is not established. M10-001 does not change the resource-admission implementation or this test. The exact-head GitHub checks passed. This focused follow-up does not replace the historical full M10-001 acceptance or requalify other platforms.

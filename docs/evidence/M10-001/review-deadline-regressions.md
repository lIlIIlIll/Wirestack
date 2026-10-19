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

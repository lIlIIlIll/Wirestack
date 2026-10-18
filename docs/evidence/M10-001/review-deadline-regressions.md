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

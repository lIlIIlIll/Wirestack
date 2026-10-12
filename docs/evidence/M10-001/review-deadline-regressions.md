# M10-001 review regression tests

SDK: Cangjie STS 1.1.3. Target: `x86_64-unknown-linux-gnu`.

The test run sourced `"$HOME/cangjie_sdk/sts1.1.3/envsetup.sh"`; `TMPDIR`, `TMP`, and `TEMP` pointed to a disk-backed task-owned directory (normalized as `<task-tmp>`).

## HTTP/1

```sh
cjpm test src/internal/http1 --filter=Http1LiteralProxyDialDeadlineReviewTest.forwardProxyLiteralDialUsesTcpConnectBudget,Http1LiteralProxyDialDeadlineReviewTest.forwardProxyLiteralDialAppliesTcpConnectCapWithoutCallerDeadline,Http1LiteralProxyDialDeadlineReviewTest.httpsProxyLiteralDialAppliesTcpConnectCapWithoutCallerDeadline,Http1ResponseHeaderBudgetReviewTest.expectContinueRetainsOneResponseHeadersBudgetAcrossBodyWrite --no-color --no-progress
```

Exit: 0. `TOTAL: 154`; `PASSED: 4`; `SKIPPED: 150`; `ERROR: 0`; `FAILED: 0`.

## HTTP/2

```sh
cjpm test src/internal/http2 --filter=Http2ClientBodyUpdateReviewTest.bodyWindowUpdatesUseTotalBudgetInsteadOfInboundIdleBudget,Http2ClientBodyUpdateReviewTest.bodyWindowUpdateWriteFailuresAreRetained --no-color --no-progress
```

Exit: 0. `TOTAL: 198`; `PASSED: 2`; `SKIPPED: 196`; `ERROR: 0`; `FAILED: 0`.

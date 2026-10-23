# M10-005 follow-up: source-bound review fixes for issues #260-#265

Date: 2026-10-23
Platform: source review only on Linux x86_64; no native Cangjie toolchain in this
environment.

The historical owner PR #203 is merged and is not rewritten. Issues #260-#265 are
review findings that were still true against main
`d496a242fec98cc3271f8f71b5a79a3aba60feea`; this branch fixes them at current
source and adds deterministic regressions. No native compile, test run or gate
was executed here, so this receipt is **not** a PASS and it does not restore a
COMPLETE state.

## Changes

| Issue | Current-source defect | Repair |
|---|---|---|
| #260 | `serveHttp1Connection` wrapped `parsed.body` with the response-body observer, so `BodyStarted`/`BodyCompleted` described request consumption and a bodyless request could emit a discarded body event. | The request body is passed through unchanged. The write path emits `BodyStarted` before `writeHttp1Response` and one `BodyCompleted` (Succeeded / Failed with the mapped code) afterwards, matching the HTTP/2 server. Handoff responses are excluded, as on HTTP/2. |
| #261 | `emitHttpFailure` only unwrapped `NetworkException`/`HttpException`, so wrapped HTTP/1 write timeouts and HTTP/2 protocol/reset exceptions lost `phase`, `errorCode` and `timeoutReason`. HTTP/2 events mapped `RST_STREAM(CANCEL)` to `InvalidState`. | `httpObservationFailureCause` walks the typed cause chain through `Http1RequestWriteException`, `Http2ProtocolException` (stream vs connection scope) and `Http2GoAwayException`. `http2ObservationErrorCode` maps `Cancel` to `NetworkErrorCode.Cancelled` for `BodyCompleted`/`Http2StreamClosed`. |
| #262 | `sampleHttpResolvers` dropped every `isLive == false` row and counted it as an unavailable resolver, although a closed owner's final snapshot is real data. | Non-live snapshots are retained (deduplicated by `ownerId`); only owners without the `ResolverResourceOwner` seam increment `unavailableResolvers`. |
| #263 | The HTTP/1 pool cleared `poolStageOpen` before `factory.create`, so DNS/connect/TLS failures after admission emitted no `HttpConnectionAcquired(Failed)`; the HTTP/2 pool emitted only a failed stage. | Both pools track a separate acquisition-terminal flag. The stage completes once; post-admission factory, stream-admission, aggregate-admission and connection-creation failures now emit `HttpConnectionAcquired(Failed)` with a mapped code and reach `HttpConnectionPoolHook.acquired`. |
| #264 | `Http2ClientPushedExchange` built its body channel with the parent `OperationContext`, so pushed reads inherited the parent stream ID; claimed pushed bodies emitted no lifecycle events. | The channel context is derived from the promised stream ID (`http2StreamEventContext`). The ownership claim emits `BodyStarted` outside the source lock, and `finish()` emits `BodyCompleted` once: Succeeded on consumption, Discarded with `Closed` on abandonment, Failed with the typed cause on reset/reader failure. |
| #265 | The `Expect: 100-continue` probe used `observedHttp1ReadHead`, so its expected expiry emitted a failed `HttpHeaders` stage and `withEarlierDeadline` labeled it `TotalDeadline`. | `readHttp1ContinueWaitHead` defers emission; the expected continue-wait expiry emits nothing. Unexpected failures are reported against the caller's response-header budget, so a still-live total deadline is never mislabeled. |

## Regressions added

- `src/internal/http1/server_connection_test.cj`: bodyless response lifecycle, streaming response failure, and no request-body lifecycle for an unread body.
- `src/internal/http1/connection_pool_test.cj`: factory failure after aggregate admission reports `HttpConnectionAcquired(Failed)` once with no failed stage.
- `src/internal/http1/http2_connection_pool_test.cj`: connection-creation, stream-admission and aggregate-admission failures each report exactly one failed acquisition; a successful acquisition reports exactly one terminal event.
- `src/internal/http1/response_reader_deadline_test.cj`: expected continue-wait expiry emits no failed `HttpHeaders` stage and no `TotalDeadline` reason.
- `src/internal/http2/client_connection_test.cj`: peer `RST_STREAM(CANCEL)` reports `NetworkErrorCode.Cancelled` on `BodyCompleted` and `Http2StreamClosed`.
- `src/internal/http2/client_push_ownership_test.cj`: claimed pushed body emits `BodyStarted`/`BodyCompleted` on the promised stream; abandonment reports `Discarded`/`Closed`.
- `src/http/observability_test.cj`: wrapped HTTP/1 write timeout keeps phase/code/timeout owner; HTTP/2 stream, cancel and connection faults keep typed terminal codes; a closed resolver's final snapshot is retained with `unavailableResolvers == 0`.

## Verification still required

The parent integration must run, on a supported native SDK environment:

1. `cjpm check`
2. `cjpm build`
3. `cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color`
4. `python3 tools/repository/repository_tooling.py --root . check task M10-005 --json`

Until those pass against this candidate, M10-005 stays BLOCKED and these changes
are unqualified.

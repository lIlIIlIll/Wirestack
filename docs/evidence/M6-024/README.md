# M6-024 HTTP/2 sibling-fairness evidence

Date: 2026-08-27

## Status

COMPLETE on native glibc Linux. All declared dependencies are COMPLETE. The
frozen scenario matrix is in [`test-plan.md`](test-plan.md).

## Scope and affected platforms

- Task: eliminate HTTP/2 sibling starvation after one slow stream exhausts the
  connection window.
- Reproduced platform: native Arch Linux x86_64 with glibc, kernel
  `7.1.9-arch1-2`.
- Cangjie compiler: `1.1.0-alpha.20260817040003` with `cjnative`.
- cjpm: `1.1.3`.
- Windows, macOS, Android, iOS, and Harmony behavior is unverified.
- musl is outside the current SDK-supported Linux profile.

## Failed gate and reproduction

The M6-022 stability run repeated
`HttpFacadeTest.publicHttp2StreamAndConnectionHandlesRespectTheirScopes` with a
five-second request deadline. A pre-fix invocation failed while reading a
2-byte sibling response:

```text
NetworkException: HTTP/2 operation deadline exceeded
at wirestack.internal.http2.Http2ClientBodyChannel.read
at wirestack.http/test.readPublicBody
at wirestack.http/test.HttpFacadeTest.publicHttp2StreamAndConnectionHandlesRespectTheirScopes
```

The failing sequence was:

1. Open a 256-KiB response on one HTTP/2 stream.
2. Consume 4 KiB from that response.
3. Open a 2-byte sibling response on the same connection.
4. Read the sibling without cancelling or closing the first stream.

The repeated command exited 1 after one invocation reached the deadline. The
same run passed 100/100 only after M6-022 moved its sibling read after stream
cancellation. That change fixed the cancellation acceptance order. It did not
fix uncancelled sibling progress.

The retained command and exact result are in
[`docs/evidence/M6-022/README.md`](../M6-022/README.md#2026-08-27-stability-follow-up).

## Source diagnosis

- `Http2FlowController` starts with a 65,535-byte connection receive window.
- `consumeReceived` coalesces connection credit until half of the default
  window is consumed.
- The 4-KiB application read does not emit `WINDOW_UPDATE`.
- The large response can consume the remaining connection window before the
  sibling DATA frame becomes ready.
- The server then has no connection credit for the sibling body. The sibling
  waits until the first stream consumes enough data, closes, or is cancelled.

This is a flow-control liveness and DATA fairness defect. It is not a
cancellation-handle defect.

## Frozen implementation boundary

- Keep all changes inside Wirestack HTTP/2 internals and tests.
- Do not change public HTTP, cancellation, TLS, or transport declarations.
- Do not add a timeout owner or raise the five-second test deadline.
- Do not increase queue, window, stream, or body-buffer limits to hide the
  failure.
- Preserve coalesced `WINDOW_UPDATE` behavior for ordinary small reads. The fix
  must not create one control frame per application read.
- Keep control frames ahead of DATA and retain one bounded writer.

## Implemented correction

- A body read flushes pending connection receive credit only when the current
  connection receive window is zero. Ordinary small reads keep the existing
  half-window coalescing policy.
- Send reservations use a bounded least-recently-served stream order. A stream
  that consumed the previous grant cannot reacquire all newly available
  connection credit ahead of ready siblings.
- Reservation cancellation removes the waiter and wakes the next eligible
  stream. Closing a flow makes the liveness flush an empty operation so the
  existing cancellation terminal remains authoritative.
- No public declaration, timeout, window, queue, stream, or body-buffer limit
  changed.

## Raw Linux candidate output

Focused real TLS h2 and deterministic flow-control output:

```text
M6_024_RESULT protocol=h2 exhaustedBytes=65535 consumedBytes=4096 siblings=100 latency1Ns=15694694 latency10Ns=76764436 latency100Ns=626954112 siblingTimeouts=0 connectionAborts=0
M6_024_FLOW_RESULT siblings=100 connectionCredit=4096 flowControlStalls=101 pendingReservations=0 connectionWindowUpdateFrames=1
```

The pre-fix baseline reached the existing 5-second absolute request deadline
while reading the first 2-byte sibling. It therefore had sibling latency of at
least 5,000,000,000 ns and a FAIL decision. The pre-fix run did not emit a
flow-stall counter; its retained structured timeout is the baseline liveness
failure.

The post-fix 100-run race executed 100 independent real TLS h2 connections,
each with 100 sibling requests while the first response remained open:

```text
M6_024_RACE_RESULT decision=PASS passed=100 failed=0
```

Across those 100 runs, cumulative latency ranges were:

- first sibling: 13,314,623 to 160,042,368 ns;
- first ten siblings: 63,507,669 to 399,701,620 ns;
- all one hundred siblings: 767,387,781 to 1,979,696,184 ns.

This completed 10,000 sibling responses with zero sibling timeout and zero
connection abort. Candidate decision: **PASS**.

## Commands and exact results

1. Test-plan validator: exit 0; P=10, S=7, T=6; status `passed`.
2. Focused liveness, cancellation-race, and public facade command with
   `--show-all-output`: exit 0; 4 passed, 547 skipped, 0 error, 0 failed.
3. One hundred sequential focused `cjpm test --skip-build` invocations: exit
   0; 100 passed, 0 failed.
4. `env DISABLE_ZOXIDE=1 ./scripts/check`: exit 0.
   - architecture/tool tests: 57 passed;
   - gate-runner tests: 110 passed;
   - benchmark-tool tests: 11 passed;
   - architecture guard: PASS;
   - `cjpm check` and `cjpm build`: success;
   - Cangjie tests: 551 total, 535 passed, 16 tagged profile tests skipped,
     0 error, 0 failed.

## Acceptance decision

All task conditions pass on the recorded native Linux environment:

1. A real TLS h2 loopback test reproduces the 256-KiB slow stream and 4-KiB
   consumption without cancelling or closing that stream.
2. One, ten, and one hundred 2-byte sibling responses complete within their
   own monotonic absolute deadlines on the same connection.
3. Deterministic scheduler and flow-control tests prove bounded progress under
   initial-window exhaustion and repeated `WINDOW_UPDATE`.
4. The retained frame counters show bounded `WINDOW_UPDATE` traffic. The write
   queue, connection window, stream window, and body buffers stay within their
   configured limits.
5. A 100-run race profile has no sibling timeout, connection abort, leaked
   stream, or duplicate terminal completion.
6. Raw sibling latency and flow-control-stall output records the environment,
   baseline, candidate, and an explicit PASS or FAIL decision.
7. Existing cancellation, SSE sibling-isolation, HTTP/2 conformance, and full
   `scripts/check` gates pass.

Native Linux evidence closes only the Linux cell. Other platform claims still
require execution on a real device or a native VM.

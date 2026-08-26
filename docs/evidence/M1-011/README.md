# M1-011 Linux transport helper evidence

- Task: `M1-011`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27 (UTC+8)
- Compiler: Cangjie `1.1.0-alpha.20260817040003` (`cjnative`)
- Target: `x86_64-unknown-linux-gnu`

## Acceptance mapping

| Requirement | Paths and scenarios | Evidence |
|---|---|---|
| Partial writes | P001 `writeAll` advances only by the returned count until the source is empty | `writeAllHandlesPartialWritesAndEmptyInput` |
| Partial reads | P002 `readExact` advances only by `Data(count)` until the destination is full | `readExactHandlesPartialReads` |
| Empty spans | P003 empty source and destination return without invoking the transport | `emptyHelpersDoNotCallTransport` |
| Premature peer EOF | P004 EOF before the destination fills becomes `Read/TcpRead/UnexpectedEof/Never` | `readExactClassifiesPrematureEof` |
| Invalid progress | P005/P006 zero, negative and greater-than-remaining counts fail once as `System/TcpRead|TcpWrite/SystemFailure/Never` | `invalidProgressFailsOnceWithoutSpinning` |
| Cancellation after progress | P007/P008 one-byte read/write progress remains visible; the next attempt receives the same cancelled context and propagates `Cancelled` | `cancellationAfterPartialProgressPropagatesWithoutRestart` |
| Absolute deadline | P009/P010 a virtual monotonic clock expires after the first byte; the next read/write attempt observes the original expired Deadline instead of a new per-loop budget | `absoluteDeadlineExpiresAcrossPartialRetries` |

Both helpers pass the caller's `OperationContext` unchanged on every attempt.
They never derive a child context inside the loop. The zero-work path performs
no transport call. Invalid progress fails immediately, so a broken transport
cannot create a busy loop.

Transport-core errors now use `TcpRead` or `TcpWrite` instead of the unrelated
`HttpBody` phase. HTTP callers still retain their higher-level phase evidence
when their own code constructs an HTTP error.

## Commands and results

Focused test:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack \
  cjpm test --filter TransportHelperTest --no-color --no-progress
```

Result: exit `0`; `TransportHelperTest` passed `7/7`. Project summary:
`PASSED 7`, `SKIPPED 472`, `FAILED 0`, `ERROR 0`.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit `0`. Python suites passed `50/50`, `84/84` and `8/8`.
The architecture guard, `cjpm check`, `cjpm build` and all Cangjie tests
passed. The Cangjie summary was `PASSED 479`, `SKIPPED 0`, `FAILED 0`,
`ERROR 0`. The build retained one pre-existing unused-function warning for
`waitUntilWaiters` in `src/internal/http1/connection_pool.cj`.

## Compatibility classification

The production declarations and helper signatures are unchanged, so source,
ABI and inventory compatibility remain intact. The declaration diff classifier
reports test-only overrides and the renamed test case as incompatible because
it does not exclude private test types from public-member matching. Those are
parser false positives. Runtime semantics intentionally change only for errors
produced by helpers. Invalid progress and premature EOF now report the
transport phases `TcpRead` and `TcpWrite` instead of `HttpBody`.

## Scope boundary

This completes M1-011 for Linux. It does not claim six-platform release
completion. The task adds no retry policy, timeout owner, buffer, cache or
background worker. Higher-level protocol code still decides whether an
operation is replayable.

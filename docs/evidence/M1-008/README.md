# M1-008 Linux exactly-once completion evidence

- Task: `M1-008`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27 (UTC+8)
- Compiler: Cangjie `1.1.0-alpha.20260817040003` (`cjnative`)
- Target: `x86_64-unknown-linux-gnu`

## Acceptance mapping

| Requirement | Paths and scenarios | Evidence |
|---|---|---|
| One terminal winner and no late completion callback | P001 first terminal caller wins; P002 repeated, concurrent and reentrant completion loses | `completionCleansEveryResourceBeforeTheWinnerCallback`, `concurrentTerminalCallersHaveOneWinner`, `cleanupFailuresAndReentrancyCannotBlockTerminalProgress` |
| Cancellation, timer and waiter cleanup at terminal state | P003 winner claims and removes all registered resources before its callback | `completionCleansEveryResourceBeforeTheWinnerCallback` |
| Idempotent unregister and explicit late-registration behavior | P004 unregister removes an unclaimed cleanup once; P005 post-terminal registration cleans synchronously and is not retained | `unregisterAndLateRegistrationHaveExplicitTerminalSemantics` |
| Every registry is bounded | P006 zero capacity is invalid; P007 configured capacity rejects overflow without mutation | `cleanupCapacityIsPositiveAndHardBounded`, `cleanupCountPropertyHoldsAcrossEveryConfiguredOccupancy` |
| Cleanup failure and callback failure retain terminal state | P008 one cleanup exception does not block other cleanup or the winner; P009 winner exception propagates without reopening | `cleanupFailuresAndReentrancyCannotBlockTerminalProgress`, `winnerExceptionDoesNotReopenTheCompletion` |
| Registration/completion race cleans exactly once | S001 64 registrations race completion for 100 rounds | `registrationRacingCompletionIsAlwaysCleanedOnce` |
| Unregister/completion race cleans at most once | S002 unregister races completion for 100 rounds | `unregisterRacingCompletionRunsCleanupAtMostOnce` |

All claimed cleanup actions execute outside the registry lock. The terminal
state and empty registry are published before cleanup begins, so cleanup and
the winning callback may re-enter the primitive without deadlock. Cleanup
order is intentionally unspecified.

## Commands and results

Focused test:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack \
  cjpm test --filter OperationCompletionTest --no-color --no-progress
```

Result: exit `0`; `OperationCompletionTest` passed `9/9`. Project summary:
`PASSED 9`, `SKIPPED 456`, `FAILED 0`, `ERROR 0`. The first sandboxed
invocation exited `1` before test execution because the unittest runner could
not create its local control socket; the identical authorized run passed.

Complete serialized regression:

```text
cjpm test --parallel 1 --no-color --no-progress
```

Result: exit `0`; `PASSED 465`, `SKIPPED 0`, `FAILED 0`, `ERROR 0`.

Canonical repository gate:

```text
scripts/check
```

Result: exit `1`. Python suites passed `50/50`, `84/84` and `8/8`;
architecture guard, `cjpm check` and `cjpm build` passed. The parallel Cangjie
run finished `464/465` with the pre-existing five-second timeout in
`HttpFacadeTest.tlsHttp2StreamLimitIsAppliedAcrossConcurrentPublicRequests`.
That HTTP test passed in the complete serialized run. The build also retained
one pre-existing unused-function warning for `waitUntilWaiters` in
`src/internal/http1/connection_pool.cj`.

## Scope boundary

This task adds the shared bounded completion/cleanup primitive and its Linux
race matrix. It does not refactor later transport, TLS or HTTP lifecycle owners
to consume the primitive; those integrations remain owned by their dependent
backlog tasks, beginning with M1-009.

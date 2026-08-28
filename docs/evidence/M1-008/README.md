# M1-008 Linux exactly-once completion evidence

- Task: `M1-008`
- Profile: Linux x86_64 glibc
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**
- Date: 2026-08-28 (UTC+8)
- Compiler: Cangjie `1.1.0-alpha.20260817040003` (`cjnative`)
- Target: `x86_64-unknown-linux-gnu`

## Dependencies

M1-003 through M1-007 have retained Linux evidence. Together they provide the
monotonic Deadline, cancellation registration, immutable operation context,
trace context and structured error contracts required by this task.

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
/home/elliot/.codex/scripts/codex_cangjie_env \
  cjpm test --filter='OperationCompletionTest.*' --no-color --no-progress
```

Result: exit `0`. `OperationCompletionTest` passed `9/9`. The project summary
was `TOTAL 569`, `PASSED 9`, `SKIPPED 560`, `FAILED 0`, `ERROR 0`.

Canonical repository gate:

```text
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit `0`. The repository Python suites passed `57/57`, `114/114` and
`23/23`. The architecture guard, `cjpm check` and `cjpm build` passed. The
Cangjie project summary was `TOTAL 569`, `PASSED 549`, `SKIPPED 20`, `FAILED 0`,
`ERROR 0`. The build retained pre-existing unused-function warnings for
`metrics`, `waitUntilAcceptActive` and `waitUntilWaiters`.

## Scope boundary

The current source already contains the shared bounded completion/cleanup
primitive and its Linux race matrix. This qualification changes no production
declaration or behavior. Later transport, TLS and HTTP lifecycle integration
remains owned by the dependent backlog tasks, beginning with M1-009.

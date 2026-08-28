# M1-003 Linux deadline evidence

## Status

- Task: `M1-003`
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**

This task qualifies TR-CTX-002 and TR-CTX-003 for the Linux profile.

## Dependency

M1-001 is complete and has retained evidence for the Transport package and test
layout.

## Acceptance mapping

| Criterion | Evidence | Result |
|---|---|---|
| Deadline uses monotonic time only | `Deadline` stores `std.time.MonoTime`; its default source calls `MonoTime.now()`. The implementation does not import or read wall-clock time. | PASS |
| Remaining time is deterministic | `remainingUsesTheInjectedMonotonicClock` advances an injected clock and observes the exact remaining duration. | PASS |
| Expiry clamps at zero | `remainingClampsAtZeroAfterExpiry` proves that an overdue deadline reports zero remaining time and stays expired. | PASS |
| A child may shorten its parent | A shorter duration produces an earlier absolute expiry. A zero-duration child expires at its creation time. | PASS |
| A child cannot extend its parent | Longer, delayed, and already-expired child requests retain the parent's absolute expiry. | PASS |
| Invalid relative durations fail locally | `Deadline.after` and `Deadline.child` reject negative durations with `IllegalArgumentException`. | PASS |
| Tests control time | `FakeMonotonicClock` advances without sleeping or reading wall time. | PASS |

This task adds explicit zero-duration and expired-parent child tests. The
production implementation already met the contract and did not change.

## Commands and results

```bash
/home/elliot/.codex/scripts/codex_cangjie_env cjpm test \
  --filter='DeadlineTest.*' --no-color --no-progress
```

Result: all 5 `DeadlineTest` cases passed. Project totals were 5 passed, 561
skipped, 0 failed, and 0 errors. Exit status 0.

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit status 0. The command passed 57 repository tool tests, 114 gate
tool tests, 23 benchmark tool tests, the architecture guard, `cjpm check`, and
`cjpm build`. Non-performance Cangjie totals were 546 passed, 20 skipped, 0
failed, and 0 errors. The existing compiler warnings for `metrics`,
`waitUntilAcceptActive`, and `waitUntilWaiters` remain unrelated to M1-003.

## Scope limits

- No runtime, std, or SDK source was modified.
- No SDK component was built.
- Wirestack's Deadline contract uses the supported public SDK and has no future
  runtime or std change as a release dependency.
- Non-Linux platforms were not executed.

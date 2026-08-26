# M1-004 Linux cancellation primitive evidence

- Task: `M1-004`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27 (UTC+8)
- Compiler: Cangjie `1.1.0-alpha.20260817040003` (`cjnative`)
- Target: `x86_64-unknown-linux-gnu`

## Acceptance mapping

| Requirement | Paths and scenarios | Evidence |
|---|---|---|
| Register and unregister callbacks | P001 active registration, P002 idempotent removal; S001 pending callback removed before cancellation | `unregisterIsIdempotentAndPreventsPendingCallback` |
| Already-cancelled fast path | P003 synchronous late registration; S002 callback runs before `register` returns | `alreadyCancelledRegistrationRunsSynchronouslyOnce` |
| Repeated and racing cancellation is exactly once | P004 first cancel claims, P005 later cancel is a no-op; S003 16 cancellers race over 64 callbacks for 100 rounds | `concurrentCancelClaimsEveryCallbackExactlyOnce` |
| Registration racing cancellation is exactly once | P001/P003/P004; S004 64 registrations race 16 cancellers for 100 rounds | `registrationRacingCancellationStillRunsExactlyOnce` |
| Unregister racing cancellation is at most once | P002/P004; S005 removal wins with zero calls or cancellation claims with one call | `unregisterRacingCancellationIsAtMostOnce` |
| Callbacks execute outside the registry lock | P004; S006 callback re-enters `cancel` and late `register` without deadlock | `callbackMayReenterCancellationAndRegistrationWithoutDeadlock` |
| Callback failure isolation | P004 exception continuation; S007 one callback throws while another still runs | `oneFailingCallbackDoesNotBlockOtherWaiters` |
| Permanently active token | P006 no-op registration; S008 token remains active and never calls callbacks | `noneTokenRemainsUsableAndNotCancelled` |

The test matrix uses semantic assertions rather than execution-only checks:
callback totals are exact, the unregister race is constrained to `{0,1}`, the
cancelled state is asserted, and every spawned operation has a one-second
completion bound.

## Commands and results

Focused test:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack \
  cjpm test --filter CancellationTest --no-color
```

Result: exit `0`; `CancellationTest` passed `9/9`, including 100-round
register/cancel and unregister/cancel races. Project summary: `PASSED 9`,
`SKIPPED 447`, `FAILED 0`, `ERROR 0`.

The first sandboxed invocation exited `1` before test execution because the
Cangjie unittest runner could not create its local control socket
(`Operation not permitted`). The identical command above passed in the
authorized environment; no product code was changed to bypass the runner.

Full repository gate:

```text
scripts/check
```

Result: two executions reached `cjpm test` after Python `50/50`, `84/84` and
`8/8`, architecture guard PASS, `cjpm check` PASS and `cjpm build` PASS. Each
parallel Cangjie run finished `455/456` with one different pre-existing
five-second HTTP facade timeout:

- `publicHttp2StreamAndConnectionHandlesRespectTheirScopes`;
- `tlsHttp2StreamLimitIsAppliedAcrossConcurrentPublicRequests`.

The first failing case passed alone in 233 ms. A complete serialized regression
run then passed:

```text
cjpm test --parallel 1 --no-color --no-progress
```

Result: exit `0`; `PASSED 456`, `SKIPPED 0`, `FAILED 0`, `ERROR 0`.
Therefore the M1-004 behavior and complete test inventory pass, while the
canonical gate retains a separate parallel-load timeout-stability risk; this
evidence does not describe either failed `scripts/check` invocation as passed.

## Scope boundary

This closes the cancellation primitive's Linux-profile race matrix. It does not
promote the global six-platform M1 milestone, and it does not claim that every
operation has completed M1-008/M1-024 registration-cleanup validation.

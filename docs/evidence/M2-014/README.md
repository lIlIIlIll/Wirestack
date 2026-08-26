# M2-014 Linux scripted connector evidence

- Task: `M2-014`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

## Scope

M2-014 completes the deterministic resolver and Happy Eyeballs connector
matrix. `StaticResolver` supplies stable ordered candidates. The scripted
attempt factory models success, blackhole, simultaneous success and failure.
Synchronous event callbacks now place parent cancellation and Deadline expiry
exactly after an attempt returns a transport but before the connector publishes
the winner.

No test depends on scheduler luck for the success/cancel or Deadline boundary.
Both cases also prove that the connector joins the candidate and aborts the
newly created transport before returning the terminal error.

## Control-flow paths

| Path | Condition | Observable result |
|---|---|---|
| P001 | first IPv6 candidate succeeds | publish IPv6 winner and skip the delayed IPv4 candidate |
| P002 | first IPv6 candidate blackholes | start IPv4 fallback, publish IPv4 winner, cancel and join IPv6 |
| P003 | two candidates succeed together | exactly one wins and every losing transport is aborted |
| P004 | every candidate fails | join all candidates and retain both failure diagnostics |
| P005 | parent is cancelled before resolve | start neither DNS work nor attempts and return `Cancelled` |
| P006 | parent cancels after transport creation but before `tryWin` | reject the apparent success, abort it, join it and return `Cancelled` |
| P007 | parent Deadline expires after transport creation but before `tryWin` | reject the apparent success, abort it, join it and return `TimedOut` |

## Scenario and test matrix

| Scenario | Paths | Test | Required assertions |
|---|---|---|---|
| S001 IPv6 first success | P001 | `ipv6FirstSuccessSkipsLaterIpv4Attempt` | IPv6 wins; IPv4 factory call never starts; skipped diagnostic is `Cancelled` |
| S002 IPv6 blackhole and IPv4 fallback | P002 | `blackholedFirstCandidateIsCancelledAndJoinedBeforeReturn` | IPv4 wins; both attempts finish; active count returns to zero |
| S003 simultaneous success | P003 | `simultaneousSuccessKeepsOneWinnerAndAbortsEveryLoser` | one transport remains open and one is aborted |
| S004 all fail | P004 | `allFailuresAreJoinedAndRetainedAsDiagnostics` | two diagnostics, two completions and no active attempts |
| S005 pre-cancel | P005 | `preCancelledParentStartsNeitherDnsNorAttempts` | `Cancelled` and zero attempt starts |
| S006 success plus cancellation | P006 | `parentCancellationAfterSuccessPreventsWinnerPublication` | no winner, `Cancelled`, joined attempt and closed created transport |
| S007 Deadline boundary | P007 | `deadlineAtSuccessBoundaryPreventsWinnerPublication` | no winner, `TimedOut`, joined attempt and closed created transport |

The existing `emitsCompleteDnsAttemptAndConnectedLifecycle` case also checks
the ordered DNS, attempt and connected event sequence with trace propagation.

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| IPv6 first success | S001 | PASS |
| IPv6 blackhole and IPv4 fallback | S002 | PASS |
| simultaneous success | S003 | PASS |
| all candidates fail | S004 | PASS |
| success plus cancel | synchronous successful-attempt event trigger; S006 | PASS |
| Deadline boundary | injected monotonic clock advanced at the same event boundary; S007 | PASS |
| no background attempt or leaked loser | active/completed counts and transport terminal state in S002 through S007 | PASS |

## Commands and results

Baseline focused command before this task:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=HappyEyeballsConnectorTest.*' --no-color --no-progress
```

The first sandbox run exited 1 before executing tests because unittest could
not create its local control socket. The authorized Linux rerun exited 0. The
existing five selected cases passed; project summary was 498 total, 5 passed,
493 skipped, 0 failed and 0 errors.

Final focused result: exit 0. All eight selected connector cases passed;
project summary was 501 total, 8 passed, 493 skipped, 0 failed and 0 errors.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0. Python suites passed 50/50, 84/84 and 8/8. The
architecture guard, `cjpm check`, `cjpm build` and the complete Cangjie test
command passed. The only build warnings are the existing unused test hooks
`waitUntilAcceptActive` and `waitUntilWaiters`.

## Compatibility

Only `happy_eyeballs_test.cj` changes. Production declarations and behavior are
unchanged. The declaration parser reported `incompatible` because it treated
interface-required `public` methods inside new `private` test classes as new
published members and then keyword-matched unrelated override and frozen-body
scenarios. The enclosing classes are private and exist only in test source, so
that result is a parser scope false positive rather than a shipped API or ABI
change.

## Remaining boundary

This is deterministic Linux model evidence. M2-015 still owns native network
emulation, glibc and musl execution, RTT/loss profiles and leak checks. M2-016
still owns DNS-to-connected performance evidence.

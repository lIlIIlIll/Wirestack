# M1-009 Linux Transport lifecycle evidence

- Task: `M1-009`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27 (UTC+8)
- Compiler: Cangjie `1.1.0-alpha.20260817040003` (`cjnative`)
- Target: `x86_64-unknown-linux-gnu`

## Acceptance mapping

| Requirement | Paths and scenarios | Evidence |
|---|---|---|
| Controlled creation paths | P001 `Created -> Connecting -> Open`; P002 `Created -> Accepted -> Open` | `connectingAndAcceptedPathsReachOpenOnlyInOrder` |
| Typed half-close | P003 either direction closes independently; P004 the complementary shutdown enters `Closing -> Closed`; repeated same-direction shutdown is idempotent | `halfCloseIsDirectionalIdempotentAndConvergesOnClosing` |
| Graceful close | P005 only Open or half-closed transports enter Closing; Closing and every terminal state retain idempotent close behavior | `gracefulCloseIsIdempotentAndCompletesOnlyFromClosing` |
| Abort and failure | P006/P007 every nonterminal state reaches Aborted or Failed once; terminal evidence cannot be overwritten | `abortAndFailReachEveryNonTerminalStateWithoutOverwritingTerminalEvidence` |
| Stable illegal-operation errors | P008 readable/writable direction matrix; P009 pre-open operations return `InvalidState`; P010 closed directions and terminal states return `Closed`; rejected transitions do not mutate state | `illegalTransitionsHaveStableCodesAndDoNotMutateState`, `closingAndTerminalStatesRejectDataOperationsWithClosedCode` |
| Exactly-once terminal cleanup | P011 Closed, Aborted and Failed complete the bounded M1-008 registry; removed actions stay removed and late actions clean synchronously | `everyTerminalModeReleasesRegisteredResourcesExactlyOnce` |
| Terminal race | P012 24 Closed/Aborted/Failed callers race for 100 rounds; one transition wins and cleanup runs once | `racingTerminalTransitionsRetainOneWinnerAndOneCleanup` |
| Reentrancy and resource bound | P013 cleanup re-enters terminal transition and registration without a lifecycle lock; P014 configured registry capacity rejects overflow | `terminalCleanupMayReenterAndItsRegistryRemainsBounded` |

The lifecycle publishes state under one mutex and runs terminal cleanup after
releasing that mutex. Cleanup can inspect or re-enter the state machine without
deadlock. `Closed`, `Aborted` and `Failed` are mutually exclusive retained
terminal states.

## Commands and results

Focused test:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack \
  cjpm test --filter TransportLifecycleTest --no-color --no-progress
```

Result: exit `0`; `TransportLifecycleTest` passed `9/9`. Project summary:
`PASSED 9`, `SKIPPED 465`, `FAILED 0`, `ERROR 0`.

Complete serialized regression:

```text
cjpm test --parallel 1 --no-color --no-progress
```

Result: exit `0`; `PASSED 474`, `SKIPPED 0`, `FAILED 0`, `ERROR 0`.

Canonical repository gate:

```text
scripts/check
```

Result: exit `0`. Python suites passed `50/50`, `84/84` and `8/8`;
architecture guard, `cjpm check`, `cjpm build` and all Cangjie tests passed.
The Cangjie summary was `PASSED 474`, `SKIPPED 0`, `FAILED 0`, `ERROR 0`.
The build retained one pre-existing unused-function warning for
`waitUntilWaiters` in `src/internal/http1/connection_pool.cj`.

## Compatibility classification

`NetworkErrorCode.InvalidState` is a deliberate pre-release inventory change.
The compatibility diff parser reported the change as compatible but did not
list the new enum constructor or new source file. The normative enum rule
5.1.3.4.3.11 classifies a constructor added to an exhaustive public enum as
source and ABI incompatible. Wirestack is greenfield and has no frozen release
baseline, so M1-009 introduces the stable code now and appends it after all
existing constructors to avoid renumbering them. A later published version
must not repeat this kind of exhaustive-enum extension without a breaking
release decision.

## Scope boundary

This task implements the shared state machine and terminal cleanup contract.
MemoryTransport and StdNetTransport still carry their earlier local lifecycle
fields. Replacing those fields with this state machine belongs to the dependent
M1-010/M1-020 integration work and needs adapter race validation in the same
change.

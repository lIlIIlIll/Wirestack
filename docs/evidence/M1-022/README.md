# M1-022 Linux std.net error mapping evidence

- Task: `M1-022`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27 (UTC+8)
- Compiler: Cangjie `1.1.0-alpha.20260817040003` (`cjnative`)
- Target: `x86_64-unknown-linux-gnu`

## Acceptance mapping

| Requirement | Evidence |
|---|---|
| Stable cancellation | An active loopback read cancelled through its operation context returns Read/TcpRead/Cancelled/Never with cause and both endpoints. |
| Stable timeout | A blocked loopback read bounded by one absolute Deadline returns Read/TcpRead/TimedOut/Temporary with cause and both endpoints. The connection remains open. |
| Stable local close | Closing a transport with an active read returns Read/TcpRead/Closed/Never with cause and both endpoints, never peer EOF. |
| Unknown socket failure | Connecting to a just-closed loopback listener returns Connect/TcpConnect/SystemFailure/Unknown with the requested remote endpoint and original cause. |
| Optional native code | Every current public SDK path reports `nativeCode=None`; no value is invented. |
| Listener errors | Accept cancellation, timeout, and close retain Accept/ServerAccept coordinates and the listener endpoint. |
| No message control flow | Static inspection finds no `SocketException.message` or other exception-message matching in Transport source. |

The mapping first uses `OperationContext` and Wirestack-owned lifecycle state.
Only a socket failure that cannot be classified from those facts becomes
`SystemFailure/Unknown`. The original `SocketException` remains the cause, but
its text does not select a code.

## Commands and results

Focused native Linux qualification:

```text
/home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack \
  cjpm test --filter StdNetTransportTest,StdNetTransportListenerTest \
  --no-color --no-progress
```

Result: exit `0`. `StdNetTransportTest` passed `15/15` and
`StdNetTransportListenerTest` passed `5/5`. Project summary was `PASSED 20`,
`SKIPPED 541`, `FAILED 0`, `ERROR 0`.

Two earlier compile attempts used invalid multi-selector `match` syntax in the
new tests. No test case ran in either attempt. The final assertions use the
repository's tuple-pattern form, `match ((left, right))`, and the identical
focused command passed.

Canonical repository gate:

```text
scripts/check
```

Result: exit `0`. Tool tests passed `57/57`, gate tests passed `114/114`,
benchmark-tool tests passed `23/23`, and the architecture guard, `cjpm check`,
and `cjpm build` all passed. The native project test summary was `PASSED 541`,
`SKIPPED 20`, `FAILED 0`, `ERROR 0` out of `561` tests. Existing compiler
warnings in metrics and test wait helpers remain warnings and did not affect
the result.

## Compatibility

No public or internal declaration changed. Existing error codes and
retryability values are unchanged. The adapter now fills already-defined
endpoint fields on cancellation, timeout, and local-close errors when it knows
those endpoints. This is additive diagnostic evidence and needs no caller
migration or SDK/runtime change.

## Scope

This completes M1-022 for Linux glibc. The current SDK still exposes no stable
native socket code, so Wirestack does not distinguish errno-like failures that
the public API cannot identify. UP-005 remains an optional future enhancement.

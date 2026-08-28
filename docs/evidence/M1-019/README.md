# M1-019 Linux half-close capability evidence

- Task: `M1-019`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27 (UTC+8)
- Compiler: Cangjie `1.1.0-alpha.20260817040003` (`cjnative`)
- Target: `x86_64-unknown-linux-gnu`

## Acceptance mapping

| Requirement | Evidence |
|---|---|
| Capability is explicit | `StdNetTransport.info.supportsHalfClose` is `false` on the pinned public SDK. |
| Read shutdown fallback | `shutdown(Read)` returns `NetworkException` with category/code `Unsupported`, phase `TransportClose`, retryability `Never`, no native code, and retained endpoints. |
| Write shutdown fallback | `shutdown(Write)` returns the same stable typed evidence. |
| Connection state is unchanged | After each failed shutdown, the same native Linux loopback connection transfers one byte in both directions. |
| No private ABI | The adapter uses public `std.net` only. Static inspection finds no private socket handle or `CJ_MRT_Sock*` call in Transport source. |
| No upstream dependency | The error describes the adapter capability. It does not claim that UP-003 is required for release. |

The focused test is
`StdNetTransportTest.unsupportedHalfClosePreservesBothDirections`. It exercises
both directions on one real loopback connection and verifies the stable error
fields before checking bidirectional I/O. `MemoryTransport` remains the
supported half-close adapter and retains the M1-010 directional-shutdown
coverage.

## Commands and results

Focused Linux qualification:

```text
/home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack \
  cjpm test --filter StdNetTransportTest --no-color --no-progress
```

Result: exit `0`. `StdNetTransportTest` passed `13/13`; project summary was
`PASSED 13`, `SKIPPED 546`, `FAILED 0`, `ERROR 0`.

The first compilation attempt used direct equality assertions for Cangjie enum
values. Those enums do not implement `Equatable`, so the compiler rejected four
test assertions before running a case. The assertions now use explicit enum
pattern matching. The identical focused command then passed.

Canonical repository gate:

```text
scripts/check
```

Result: exit `0`. Repository tool tests passed `57/57`, gate tests passed
`114/114`, benchmark tool tests passed `23/23`, the architecture guard passed,
`cjpm check` and `cjpm build` succeeded, and the Cangjie suite finished with
`PASSED 539`, `SKIPPED 20`, `FAILED 0`, `ERROR 0`.

The build retained three existing unused-function warnings for `metrics`,
`waitUntilAcceptActive`, and `waitUntilWaiters`.

## Compatibility

The `DuplexTransport` and `TransportInfo` declarations are unchanged. The only
production behavior change removes an obsolete UP-003 dependency claim from an
exception message. Stable category, phase, code, retryability, endpoints and
capability reporting are unchanged. This task does not change the public
Wirestack API or require an SDK/runtime modification.

## Scope

This completes M1-019 for the Linux glibc profile. It does not claim native
directional TCP shutdown support. Future adapters may report
`supportsHalfClose=true`; UP-003 remains an optional upstream enhancement.

# M2-004 Windows SystemResolver evidence

Current STS qualification is determined by the current-desktop report and validation receipts.

Historical implementation status: COMPLETE based on the previous alpha-era
acceptance only. Current Windows STS acceptance requires the official native
gate on a frozen, published source revision; this source overview is not proof.

M2-004 implements the Windows x86_64 `SystemResolver` adapter over a fixed
Win32 worker pool. The native adapter uses Winsock `GetAddrInfoW`, returns
bounded IPv4/IPv6 candidates through the provider-neutral resolver ABI, maps
Winsock status codes without parsing exception text, and keeps blocking system
resolution off Cangjie scheduler carriers.

## Current STS requalification

The current gate pins the official Windows x64 Cangjie STS 1.2.0 archive in
[`docs/references/m2-004-sts-sdk.json`](../../references/m2-004-sts-sdk.json).
It verifies the archive checksum, compares the installed SDK files with archive
members, and records `cjc` and `cjpm` versions and native target. The selected
native suite must report the six named Windows resolver cases with no skips,
failures, errors, or timeout.

The test process executes the verified SDK-root CJPM path directly. Its child
environment retains the inherited Windows runtime search paths after the SDK
entries. The report uses the canonical `cjpm` command name and separately binds
the selected executable through the SDK identity.

The cancellation case waits for an actual running native job, catches the
expected resolver error inside the worker, and returns that error as a value.
It retains the separate 50 ms cancellation and Deadline limits, checks that
native work is still running, and joins the caller before closing the resolver.
Uncaught-worker diagnostics are not part of the resolver latency measurement.
The [first STS attempt and compilation-only repair receipt](maintenance/native-cancellation-regression.json)
retain the failed native case. They do not establish current Windows acceptance.

After source freeze and authorized publication, the workflow writes the
current report, validation, and six logs under
[`current-desktop/windows-x86_64/`](current-desktop/windows-x86_64/).
Those receipts determine current desktop qualification. The legacy reports
and generic schema-v1 evidence index remain historical and unchanged.

## Current native STS result

The [current report](current-desktop/windows-x86_64/report.json) and
[validation](current-desktop/windows-x86_64/validation.json) passed on
`windows-2025` at source `1631837216989f7eac6986b24b0b9a2c61d0bd20`.
[Run 41797937351](https://github.com/lIlIIlIll/Wirestack/actions/runs/41797937351),
job `126466416305`, was dispatched once on
`fix/M10-002-resource-owner-backpressure`.

All six selected cases passed, including both unchanged 50 ms limits. The 28
other filtered cases were skipped, not qualified. Native SDK identity matched
310 archive files, compiler/CJPM 1.2.0 and target `x86_64-w64-mingw32`.
Artifact `13306283731` retained the report, validation and six logs. Its raw
ZIP is 10,512 bytes, artifact-byte SHA-256
`9c0b1d17cc9d74924bf65e4e2626cf6d0c2bf9646c9d5a8a9a7df09bac2255de`.
The actual dispatch branch is not relabeled as the separate immutable source ref.
Earlier STS runs `41779351031` at `59e0fcf4`, `41698902389` at `6c5eb96e`
and `41773923034` at `e0cc7f4e` remain historical qualifications.

## Historical native Windows acceptance (legacy alpha evidence)

- GitHub Actions run: `33361148426`
- workflow: `M2-004 Windows SystemResolver`
- tested revision: `c80be395d67523efaed28b35d139a8e36aad5610`
- runner: `windows-2025` / `win25-vs2026` image
- Cangjie: `1.3.0-alpha.20260831010012`, target
  `x86_64-w64-mingw32`
- result: six selected cases passed, zero selected cases skipped, failed, or errored
- strict exact-revision validation: PASS for that historical revision

The historical machine reports remain at
[`windows-x86_64/report.json`](windows-x86_64/report.json) and
[`windows-x86_64/validation.json`](windows-x86_64/validation.json).

## Acceptance coverage

| Requirement | Evidence | Result |
|---|---|---|
| Native Windows integration | Historical GitHub `windows-2025` run `33361148426` | Historical PASS |
| All bounded candidates and family filtering | `fixtureReturnsAllCandidatesWithoutInventingTtl`, `fixtureAppliesFamilyAndResultBounds` | Historical PASS |
| No invented TTL | `ResolveResult.expiration.isNone()` on system and fixture paths | Historical PASS |
| Stable Winsock error mapping | six injected error paths including unknown native code | Historical PASS |
| Cancellation and Deadline | delayed native call; distinct Cancelled/Timeout results within the 50 ms target | Historical PASS |
| No carrier-thread blocking | bounded worker-pool design; this selected-case report did not measure carrier starvation | Design evidence only |
| Bounded lifecycle | source limits of 32 workers/1024 queue entries per pool and 8 pools/64 workers process-wide; selected cases did not assert reaper counters | Source invariant only |
| No private runtime ABI | historical resolver manifest `private_runtime_abi: false` | Historical PASS |
| Linux code/build regression | local focused test and `scripts/check-code` on the historical candidate | Historical PASS |

## Test-only link support

CJPM links the complete root `wirestack` package even for the internal resolver
test target. That root package retains three TLS certificate-helper foreign
references which M2-004 does not call. The Windows gate therefore builds
`tools/gates/native/m2_004_tls_link_stub.c` into a test-only archive. Every stub
entry fails closed, the gate report records its digest and purpose, and ordinary
Windows builds do not create it. It is not a TLS provider, is not a release
payload, and does not claim Windows TLS support.

## Limits

This task does not implement or qualify a Windows TLS provider, HTTP/TLS
facades, macOS/iOS/Android/Harmony resolvers, mobile network-change behavior,
the one-hour SSE profile, or the 86,400-second soak. Those remain separate
tasks. GitHub hosted Windows execution is native VM evidence for M2-004 only.

Repository-wide release evidence remains owned by its release tasks. This
task-level report proves the resolver behavior above and does not make a Linux
release-artifact or release-candidate claim.

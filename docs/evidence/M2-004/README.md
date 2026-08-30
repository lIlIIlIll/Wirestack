# M2-004 Windows SystemResolver evidence

Status: COMPLETE

M2-004 implements the Windows x86_64 `SystemResolver` adapter over a fixed
Win32 worker pool. The native adapter uses Winsock `GetAddrInfoW`, returns
bounded IPv4/IPv6 candidates through the provider-neutral resolver ABI, maps
Winsock status codes without parsing exception text, and keeps blocking system
resolution off Cangjie scheduler carriers.

## Native Windows acceptance

- GitHub Actions run: `33330412542`
- workflow: `M2-004 Windows SystemResolver`
- tested revision: `bc75e64aab2ae830a8e45a422616f0c935900dbe`
- runner: `windows-2025` / `win25-vs2026` image
- Cangjie: `1.3.0-alpha.20260831010012`, target
  `x86_64-w64-mingw32`
- result: 6 selected cases passed, 0 selected cases skipped, 0 failed, 0 error
- strict exact-revision validation: PASS

The retained machine reports are:

- [`windows_x86_64/report.json`](windows-x86_64/report.json)
- [`windows_x86_64/validation.json`](windows-x86_64/validation.json)

The 17 skipped cases in the raw unittest package summary are test cases outside
the selected `M2004WindowsSystemResolverTest` class. All six selected cases are
listed as `[ PASSED ] CASE`; the gate requires exactly six and rejects selected
SKIPPED, timeout, nonzero exit, stale SHA, wrong platform, unknown schema, or a
missing test fixture binding.

## Acceptance coverage

| Requirement | Evidence | Result |
|---|---|---|
| Native Windows integration | GitHub `windows-2025` run `33330412542` | PASS |
| All bounded candidates and family filtering | `fixtureReturnsAllCandidatesWithoutInventingTtl`, `fixtureAppliesFamilyAndResultBounds` | PASS |
| No invented TTL | `ResolveResult.expiration.isNone()` on system and fixture paths | PASS |
| Stable Winsock error mapping | six injected error paths including unknown native code | PASS |
| Cancellation and Deadline | delayed native call; distinct Cancelled/Timeout results within the 50 ms target | PASS |
| No carrier-thread blocking | Cangjie caller polls a fixed Win32 worker pool; delayed work stays native | PASS |
| Bounded lifecycle | 32-worker/1024-queue per-pool limits, 8-pool/64-worker process cap, asynchronous reaper | PASS |
| No private runtime ABI | resolver manifest `private_runtime_abi: false` | PASS |
| Linux code/build regression | local focused test and `scripts/check-code` | PASS |

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

The top-level `scripts/check` intentionally remains nonzero after this
production/build change because the retained M7-020 architecture audit,
M7-021 Linux release artifact qualification, and M7-031 release-candidate
report are digest-bound to the previous source tree. They must be regenerated
by their owning release tasks after the non-Linux implementation sequence is
finished; M2-004 does not rewrite historical release evidence.

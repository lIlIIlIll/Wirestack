# M0-023 current Linux libc scope evidence

- Task: `M0-023`
- Status: **COMPLETE**
- Decision: current Linux release supports glibc x86_64
- Deferred target: Linux musl

ADR-0004 records the project owner's 2026-08-27 decision. The active Cangjie
compiler reports `x86_64-unknown-linux-gnu`. Both retained compiler probes reject
`x86_64-unknown-linux-musl` because the environment is unsupported.

The decision changes product scope, not test results. Existing AWS-LC musl PoC
results remain valid provider portability evidence. They do not prove that
Wirestack Cangjie packages run on musl.

## Acceptance

| Requirement | Result | Evidence |
|---|---|---|
| Current Linux target is explicit | PASS | PRD §21.5 and ADR-0004 require native glibc x86_64 |
| musl is not reported as passed or failed | PASS | PRD marks musl deferred; M2-005 and M3-013 use `DEFERRED_TOOLCHAIN_UNSUPPORTED` |
| Future adoption has one owner | PASS | P1-011 defines the SDK trigger and full native evidence |
| Active task dependencies are updated | PASS | M2-005 and M3-013 are complete; M2-015 and M2-016 are ready for glibc execution |
| Global release matrix is consistent | PASS | M7-004 lists Windows, Linux glibc, macOS, Android, iOS, and Harmony |

## Verification

```text
cjc -v
Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)
Target: x86_64-unknown-linux-gnu

python3 -m unittest tools.tests.test_linux_profile_scope
Ran 4 tests in 0.001s
OK

scripts/check
Python tools: 57 passed
Gate tests: 110 passed
Benchmark tests: 11 passed
Architecture guard: PASS
cjpm check: PASS
cjpm build: PASS
Cangjie tests: 548 total, 531 passed, 16 skipped, 1 error

env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd /home/elliot/playground/Wirestack cjpm test \
  --filter='HttpFacadeTest.publicHttp2StreamAndConnectionHandlesRespectTheirScopes' \
  --no-color --no-progress
1 passed, 547 skipped, 0 errors
```

The canonical check did not pass in full. Its only error was
`HttpFacadeTest.publicHttp2StreamAndConnectionHandlesRespectTheirScopes`, an
HTTP/2 cancellation test introduced by M6-022. The isolated rerun passed in
0.32 seconds. M0-023 changes no Cangjie source, so this load-sensitive failure
is retained as a separate suite-stability risk rather than treated as evidence
for or against the Linux libc decision.

The retained musl compiler probe is
[`docs/evidence/M3-013/linux-musl-x86_64/toolchain-probe.data`](../M3-013/linux-musl-x86_64/toolchain-probe.data).

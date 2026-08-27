# M3-013 evidence: Linux system trust adapter

## Status

- Task: **COMPLETE**
- Native Linux glibc x86_64: **PASS**
- Native Linux musl: **DEFERRED_TOOLCHAIN_UNSUPPORTED**

The adapter freezes an ordered list of Linux CA bundles and hashed certificate
directories. Bundle candidates must be readable, non-empty regular files. A
directory candidate is now accepted only when it contains at least one readable,
non-empty OpenSSL-style hashed certificate entry (`HHHHHHHH.N`); a merely
readable or unrelated directory fails closed. Provider defaults and environment
variables are never consulted.

## Acceptance matrix

| Requirement | Result | Evidence |
|---|---|---|
| Freeze CA bundle/directory rules | PASS | `LinuxSystemTrustAdapter.bundleCandidates()` and `directoryCandidates()` plus focused tests |
| No silent provider fallback | PASS | Missing, empty and malformed candidates produce `NoUsableTrustSource` |
| Stable source identity and error | PASS | Selected bundle/directory identity and typed `LinuxSystemTrustErrorCode` |
| Native glibc platform execution | PASS | [`linux-glibc-x86_64/system-trust.data`](linux-glibc-x86_64/system-trust.data) |
| Native musl platform execution | DEFERRED | [`linux-musl-x86_64/toolchain-probe.data`](linux-musl-x86_64/toolchain-probe.data) |

ADR-0004 limits the current Linux profile to native glibc. Both locally
available Cangjie SDKs reject
`x86_64-unknown-linux-musl`. The official 1.1 installation guide describes the
Linux toolchain requirement in terms of glibc and publishes only the generic
Linux SDK archives; no musl-native SDK or supported musl target was available
for this run. The existing native Alpine evidence under M0-016 covers the C/C++
TLS provider PoC, not execution of Wirestack Cangjie code.

## Commands and results

```text
/home/elliot/.codex/scripts/codex_cangjie_env cjpm test --filter LinuxSystemTrustAdapterTest
PASS: 4 passed, 0 failed, 0 errors

scripts/check
Python repository tests: 50 passed
gate tests: 89 passed
benchmark tests: 11 passed
architecture guard: PASS
cjpm check: PASS
cjpm build: PASS
cjpm test: one unrelated HTTP/2 concurrent-stream deadline ERROR under full-suite load

/home/elliot/.codex/scripts/codex_cangjie_env cjpm test --filter HttpFacadeTest
PASS: 12 passed, including tlsHttp2StreamLimitIsAppliedAcrossConcurrentPublicRequests
```

The full-suite HTTP/2 timeout did not reproduce when its owning test class ran
alone. It is recorded as a separate existing stability risk and is not treated
as a M3-013 pass.

## Deferred musl adoption

P1-011 starts only after the Cangjie SDK provides a supported musl target,
standard library, runtime, and build instructions. Cross-compilation or running
the glibc artifact in Alpine does not establish musl support.

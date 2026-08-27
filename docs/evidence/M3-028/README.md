# M3-028 Linux TLS qualification evidence

- Task: `M3-028`
- Profile: native Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27, UTC+8
- Provider: pinned AWS-LC 5.5.0 Wirestack artifact
- Baseline: Cangjie stdx 1.1.3.1 TLS/OpenSSL archive

## Scope

This result closes M3-028 for the current Linux glibc delivery profile only.
ADR-0002 excludes the other native platforms from this result, and ADR-0004
defers Linux musl until the Cangjie SDK supports it.

The gate builds an isolated `-O2` Wirestack snapshot, verifies the pinned stdx
archive and modules by SHA-256, and alternates Wirestack/stdx order for one
warmup plus 11 measured rounds. The same generated certificate, key, loopback
TCP shape, TLS version, payload and process topology are used by both sides.

## Acceptance decision

| Requirement | Result | Decision |
|---|---:|---|
| Bulk TLS throughput versus stdx | 1.2125 ratio; minimum 0.90 | PASS |
| Full handshake P50 versus stdx | 0.0920 ratio; maximum 1.10 | PASS |
| Full handshake P95 versus stdx | 0.1056 ratio; maximum 1.20 | PASS |
| TLS 1.3 resumed handshake | 11/11 measured rounds reported `resumed=true` | PASS |
| Body-size memory | 1 to 100 MiB peak RSS growth 3,616 KiB; payload-growth ratio 0.0357 | PASS |
| Idle TLS library memory | OLS slope 47.848 KiB/connection; maximum 48 KiB | PASS |
| External interoperability | Wirestack client/server with OpenSSL, TLS 1.2 and 1.3, application bytes both directions | PASS |
| Dynamic dependencies | no `libssl`, `libcrypto`, stdx TLS FFI or OpenSSL dynamic loader; manifest false | PASS |
| Deterministic TLS/trust tests | 70/70 pass, zero skipped | PASS |
| Bounded deterministic fuzz | record/handshake 1,024; certificate 512; hostname 2,048; no crash/hang | PASS |

The idle result uses the slope across 2, 16, 64 and 128 established TLS
connections. The regression intercept removes process startup and shared
provider/context ownership. Kernel socket buffers are outside process RSS.
The body profile streams 1, 16, 64 and 100 MiB without constructing a payload-
sized Cangjie array.

The complete commands, raw round outputs, RSS samples, dependency output,
environment, provider manifest and stdx reference are retained in
[`linux_glibc_x86_64/tls-qualification.json`](linux_glibc_x86_64/tls-qualification.json).
The frozen contract is in [`test-plan.md`](test-plan.md).

## Implementation change selected by the gate

The first formal run measured only 60.1% of the stdx bulk baseline. The TLS
pump allocated two 16 KiB scratch arrays on every plaintext call. M6-025 later
showed that retaining an active mutable array in a connection field was unsafe
under HTTP/2 full-duplex traffic. The current implementation leases each
scratch pair exclusively to one active read or write call, returns it to a
bounded per-direction cache after the call, drops idle caches, and uses bounded
2 KiB incremental handshake scratch. M6-025 requalified the gate at a 1.4494
bulk ratio and 45.597 KiB per idle connection.

## Commands and exact results

```text
cangjie_env; cjpm test src/internal/tls_engine src/internal/trust -j 1 --parallel 1 --show-all-output --no-progress --no-color
```

Result: exit 0; 70/70 passed, zero skipped, including all four deterministic
fuzz targets.

```text
cangjie_env; python3 tools/benchmarks/m3_028_tls.py \
  --stdx-archive /tmp/cangjie-stdx-linux-x64-1.1.3.1.zip \
  --stdx-root /tmp/wirestack-stdx-1.1.3.1.sAN2Jp \
  --output /tmp/m3-028-sixth-run.json
```

Result: exit 0; report decision `PASS`; the report was copied without changes to
`linux_glibc_x86_64/tls-qualification.json`. No soak or 24-hour profile ran.

```text
cangjie_env; timeout 600s cjpm test src/internal/tls_engine src/internal/trust src/internal/transport_stdnet -j 1 --parallel 1 --exclude-tags=Performance
```

Result: exit 0; 94 passed, 15 Performance-tagged tests skipped, zero failed.

```text
cangjie_env; timeout 600s cjpm test src/internal/http1 src/tls -j 1 --parallel 1 --exclude-tags=Performance
```

Result: exit 0; 112 passed, 3 Performance-tagged tests skipped, zero failed.

## Boundary and remaining work

The public stdx 1.1.3.1 implementation did not return a reusable session in
this host's OpenSSL 3.6.3 environment, so no stdx resumed value is invented.
PRD section 19.2 requires resumed handshake to be benchmarked separately, not
to meet a stdx ratio; Wirestack's own runtime `resumed=true` evidence is used.

This evidence does not complete the six-platform M3 milestone, M7-003's global
artifact scan, M7-006 continuous fuzzing, or M7-007 continuous performance CI.

The repository-wide hang discovered during this task is closed by M6-025.
Its final `scripts/check` run exited 0 with 538 passed non-Performance Cangjie
tests and 20 explicitly tagged Performance tests skipped. The requalification
report is retained under `docs/evidence/M6-025/` rather than rewriting this
task's original terminal artifact.

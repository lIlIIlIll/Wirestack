# M7-020 Linux architecture audit

Status: **COMPLETE**

Decision: **PASS**

The final source audit passes all M7-020 checks for the Linux x86_64 glibc
profile. The result covers 188 repository Cangjie files, 11 build or native
files, and 24 files in public API packages.

## Result

| Check | Result |
|---|---|
| Only `wirestack.internal.transport_stdnet` references `std.net` | PASS |
| Public packages expose no low-level socket or native provider type | PASS |
| Production source contains no `CJ_MRT_Sock*` private ABI call | PASS |
| New HTTP and TLS code contains no old stdx or `CJ_TLS_DYN_*` bridge | PASS |
| New TLS code contains no legacy global provider API | PASS |
| Build and native files contain no system OpenSSL link or loader | PASS |
| Linux release does not depend on runtime/std source changes | PASS |

The machine-readable record is
[`linux_x86_64/audit.data`](linux_x86_64/audit.data). The validator binds the
result to the PRD, backlog, `cjpm.toml`, and architecture guard hashes. It also
reruns the guard and checks the scanned-file inventory.

Run the audit with:

```shell
scripts/audit-m7-020-linux-architecture
```

The guard strips Cangjie comments and string literals before it scans source.
This avoids false failures from documentation text. It scans build files and C
provider code separately, where a system `libssl` or `libcrypto` link or loader
is forbidden.

## Upstream boundary

The audit found no runtime/std dependency. Typed TCP half-close, native socket
codes, and runtime-native DNS remain possible upstream improvements. Wirestack
uses stable capability fallback and its bounded resolver implementation today.
M7-020 did not modify or build the Cangjie SDK.

## Evidence boundary

M7-020 proves source and build-configuration architecture. M7-021 must still
build and inspect the installed Linux release artifact. This result does not
claim that the artifact dependency scan, global M7, or a non-Linux profile has
passed.

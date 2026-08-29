# M7-026 Linux public API freeze

Status: **COMPLETE**

Decision: **PASS**

M7-026 records the current Linux x86_64 glibc public API in a deterministic JSON
baseline and adds a fail-closed inventory gate. The baseline covers the
`wirestack`, `wirestack.http`, and `wirestack.tls` packages, including public
members and the declaration behind every public type alias. Under ADR-0006 it
is the current pre-1.0 candidate inventory, not a compatibility target for the
earlier experimental API.

## Frozen identity and inventory

| Field | Result |
|---|---|
| Package | `wirestack` |
| Version recorded by the baseline | `0.1.0` |
| Frozen major | `0` |
| Public packages | `wirestack`, `wirestack.http`, `wirestack.tls` |
| Public declarations | 243 |
| Resolved public alias targets | 103 |
| Inventory SHA-256 | `474014b6ca7eeec65b454f45cf7d882e41562926864f571610afb937fb802e1f` |
| Baseline SHA-256 | `aa01d2d70903abf2ad5d09e3f5d6e8b1d22de8837a9a37e86c8cabe44cf347a4` |

The versioned baseline is
[`docs/api/baselines/wirestack-linux-v0.json`](../../api/baselines/wirestack-linux-v0.json).
The machine-readable decision is
[`linux_x86_64/api-compatibility.json`](linux_x86_64/api-compatibility.json).

## Frozen cancellation handles

The gate requires these public handle classes and their typed scope,
`isCancellationRequested`, and idempotent `cancel(): Bool` members:

- `HttpRequestCancellationHandle`;
- `HttpConnectionCancellationHandle`;
- `HttpStreamCancellationHandle`.

Removing a handle, renaming a member, changing a member signature, or changing
the resolved declaration behind a public alias makes the gate fail. Function
body-only changes do not change the declaration inventory.

## Forbidden public surface

The gate rejects public declarations containing the legacy global TLS kit,
`TrustAll`, an OpenSSL cipher-string configuration surface,
`StreamingSocket`, `TlsSocket`, `TcpSocket`, or `SocketException`. The
OpenSSL-string check intentionally permits boolean release metadata such as
`externalOpenSslDependency`; it rejects a public signature that combines an
OpenSSL name with `String`.

## Compatibility evidence boundary

| Dimension | Result |
|---|---|
| Source declaration inventory | PASS: exact match with the committed baseline |
| Package name and major | PASS: dedicated manifest gate |
| Binary/ABI compatibility | BASELINE ONLY: Wirestack has no previous frozen binary release for comparison |
| Runtime semantic compatibility | Not proved by static comparison; project tests validate current behavior |
| Forward compatibility | Not established until a future library/consumer matrix exists |

The general Cangjie compatibility corpus does not cover package-version policy,
so this task supplies a dedicated package-name and major-version gate. It does
not label ABI, semantic, or forward compatibility as passed without an old/new
release matrix.

An intentional public API change must be reviewed as its own task. During the
current pre-1.0 phase it may deliberately replace the candidate inventory
without a compatibility shim or verdict, but it must rerun this gate and the
relevant public-consumer tests. Do not regenerate the baseline merely to make
an unexplained diff pass.

## Repeat the gate

Validate the committed baseline and report:

```shell
scripts/check-m7-026-linux-api
```

After an approved API change, regenerate both versioned artifacts before
reviewing their diff:

```shell
scripts/check-m7-026-linux-api --write-baseline --write-report
```

## Verification results

| Command | Result |
|---|---|
| `python3 -m py_compile tools/m7_026_linux_api_freeze.py tools/tests/test_m7_026_linux_api_freeze.py` | PASS |
| `python3 tools/m7_026_linux_api_freeze.py --write-baseline --write-report` | PASS; 243 declarations and 103 aliases |
| `python3 -m unittest tools.tests.test_m7_026_linux_api_freeze` | 6 passed |
| `scripts/check-m7-026-linux-api` | PASS; exact baseline and report match |
| Python repository tests invoked by `scripts/check` | 99 passed |
| Gate-runner tests invoked by `scripts/check` | 118 passed |
| Benchmark-tool tests invoked by `scripts/check` | 23 passed |
| Architecture guard, `cjpm check`, and `cjpm build` invoked by `scripts/check` | PASS |
| `cjpm test --exclude-tags=Performance` | 552 passed, 22 skipped, 0 failed |

The first `scripts/check` attempt found one stale task-graph assertion that
still required `M7-026` to be `READY`. The assertion was updated to require
`M7-026 COMPLETE` and `M7-027 READY`; the complete gate then passed. A separate
test attempt in the restricted sandbox could not create the unittest runner's
loopback socket and failed with `Operation not permitted`. The same command
passed in the authorized environment; no product code changed during that
environmental rerun.

## Upstream boundary

Wirestack builds and freezes this API against the existing public Cangjie SDK.
No runtime, `std`, `std.net`, stdx, or SDK source change is required. Possible
runtime or standard-library improvements remain optional long-term upstream
requirements and cannot block Wirestack build, test, packaging, API freeze, or
release.

## Evidence boundary

This evidence applies only to Linux x86_64 glibc and the post-M7-032 pre-1.0
candidate inventory. It does not claim backward, ABI, semantic, or forward
compatibility, compatibility for a non-Linux artifact, or completion of the
remaining release tasks.

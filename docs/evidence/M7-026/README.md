# M7-026 Linux public API freeze

Status: **COMPLETE**

Decision: **PASS**

M7-026 freezes the Linux x86_64 glibc public API in a deterministic JSON
baseline and adds a fail-closed compatibility gate. The baseline covers the
`wirestack`, `wirestack.http`, and `wirestack.tls` packages, including public
members and the internal declaration behind every public type alias.

## Frozen identity and inventory

| Field | Result |
|---|---|
| Package | `wirestack` |
| Version recorded by the baseline | `0.1.0` |
| Frozen major | `0` |
| Public packages | `wirestack`, `wirestack.http`, `wirestack.tls` |
| Public declarations | 82 |
| Resolved public alias targets | 50 |
| Inventory SHA-256 | `99dcdb3866ea70b07bb5c228364e8aae7c170b3fb81cd48be12e2d8464f713e6` |
| Baseline SHA-256 | `9fc60b9fc62ad20a97c3d4db860a2d1d4eed45f27bd7e143f8b29e9a92c412c0` |

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

An intentional public API change must be reviewed as its own task. The change
must state whether it is compatible within major 0 or requires a new major,
update the baseline deliberately, and rerun this gate plus the relevant public
consumer tests. Do not regenerate the baseline merely to make an unexplained
diff pass.

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
| `python3 tools/m7_026_linux_api_freeze.py --write-baseline --write-report` | PASS; 82 declarations and 50 aliases |
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

This evidence applies only to Linux x86_64 glibc and to the first Wirestack API
baseline. It does not claim a previous-release ABI comparison, compatibility
for a non-Linux artifact, or completion of M7-022 through M7-024 and M7-027
through M7-031.

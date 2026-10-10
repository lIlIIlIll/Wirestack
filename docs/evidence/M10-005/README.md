# M10-005 — correlated events and real resource snapshots

**COMPLETE — native Linux x86_64 glibc candidate acceptance.** Issue [#177](https://github.com/lIlIIlIll/Wirestack/issues/177). The candidate is uncommitted and **NOT_QUALIFIED** for release.

## Scope

- Request, retry/redirect attempt, physical connection and actual H2 stream correlation. Logical request completion is separate from response-body lifetime. Existing pool hooks work without a caller event sink.
- Actual DNS/TCP/proxy/TLS/header/body stages, local H2 backpressure and effective deadline-owner attribution. Unexpired native timeout errors do not acquire invented total/stage reasons.
- Current resource leases, pool ownership, retained configuration generations, resolver workers/queues/cache and actual cancellation reclamation. Unknown resolvers stay unknown; closed resolver snapshots retain their historical sample time.
- Optional `wirestack.observability` adapter: fixed queue, deterministic sampling, bounded batches, honest drop accounting and finite flush/close. No global service or identifier-keyed metric map. Callbacks run outside owner locks.
- Fresh installed consumers, default-off/on raw measurement, secret-safe output and native FD/task rollback. No parser, timeout owner or upstream change.

## Acceptance

| Command / scenario | Actual result |
|---|---|
| `scripts/check-task M10-005 --json --output docs/evidence/M10-005/task-gate.json` | Exit0; all five commands exit0 |
| `cjpm check` / `cjpm build` | Exit0 each |
| `cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color` | Exit0;919 passed,26 skipped,0 errors,0 failures |
| Real500ms native `getaddrinfo` fixture, both SDKs | Exit0;5 selected cases pass per SDK |
| Fresh installed consumer, SDK1.3.0-alpha.06 and1.1.3 | Exit0;13 checks pass per SDK; each installation matches all153 current production source digests |
| SDK1.1.3 current adapter / facade suites | Exit0;9 /5 behavior cases pass |
| Architecture guard / capability contract | Exit0;86 capability rows; contract check is not native qualification |
| Strict API documentation | Exit0;5 packages,1717 symbols and861 parameters documented100% |

The26 skips are23 Performance-tag cases plus3 cases requiring the delayed resolver fixture. The latter execute separately with the real fixture; none is silently returned as a passing test. The M10 measurement is an actual warmed30-request workload with three samples per mode, not a substitute for other milestone performance profiles.

The final installed runs return FD10→10 and task15→15 on both SDKs. RSS and disabled/root-buffer/async-export timings are recorded in [performance.json](performance.json). Negative short-sample overhead is variance, not an optimization claim. No overhead SLA was specified or inferred.

## Evidence

- [Verification, commands, source bindings and changed files](verification.json)
- [Acceptance matrix](scenario-matrix.json)
- [Canonical task gate](task-gate.json) and [strict documentation](docs-report.json)
- [Installed consumer](installed/report.json) and [SDK1.1.3 installed consumer](sdk113/installed.json)
- [SDK1.1.3 source suites and explicit deltas](sdk113/report.json)
- [Real resolver fixture and explicit missing-fixture skips](native-resolver-fixture.json)
- [Raw workload and resource samples](performance.json)
- [Workspace safety](workspace.json)

Raw canonical and diagnostic outputs are retained under `logs/`. SDK1.1.3 historical progress-collector failure and corrected `--no-progress` run remain recorded; failed commands are not relabeled as passes. The original all-inclusive run exposed missing Performance profile inputs and an effectful rotation assertion; the corrected native80-rotation probe and all8 stable-SDK rotation cases are linked in verification. The final native regression passes without weakening production rotation behavior.

The repository-wide `scripts/check` was not rerun merely to reconfirm its unrelated historical M7/provider-artifact failures. [M10-004's observed repository log](../M10-004/repository-check.log) remains the prior evidence. This task claims its own canonical, dependency, capability and documentation gates, not a current repository-wide PASS.

## Limits

Cross-owner snapshots are not globally atomic. A blocked exporter or cancellation callback may survive a finite close; the API reports false and retained ownership rather than faking termination. Only real Linux x86_64 glibc execution is claimed. No commit, push, PR, issue write, signing, release qualification or next-task implementation occurred.

Next READY tasks: **M11-001** (preferred), M11-002 and M11-003.

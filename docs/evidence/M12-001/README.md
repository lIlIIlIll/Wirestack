# M12-001 — native end-to-end performance evidence
Current status: BLOCKED. The source-bound verify command exits 1. Stack #200 findings #291-#294 are
repaired in the runner and probes ([review-fix record](stack200-review-fixes.json)): the retained-corpus
verifier now requires measured TLS provider identity, environment metadata commands, per-sample binary
digests, declared per-scenario work contracts, complete warmup rounds and recomputed process peaks. The
retained report below predates that bound-evidence schema, so `verify` rejects it with `retained report does
not carry the bound-evidence schema` instead of silently trusting asserted fields. All measurement results
below remain historical; rerun the baseline on exact current sources with STS 1.1.3 before marking COMPLETE.
The added regressions carry no committed execution receipt in this repair revision ([record](stack200-review-fixes.json));
the task gate executes them at integration, and they do not clear the source-binding failure. The earlier 28/28 run
([log](review-unit-tests.log)) describes the pre-repair suite. Clean-checkout archive reproduction is still unproved: reconstruction needs generated native inputs, while the exact historical archive remains withheld because its provider debug data embeds private machine paths.

**Historical measurement: development measurement and candidate evaluation.** Not release qualification or proof of a performance gain.

## Artifact and environment

Native Linux x86_64 glibc, Intel Core i7-8700, SDK 1.1.3 and build-selected static AWS-LC 5.5.0. [Workspace safety](workspace.json) records the branch, HEAD, merge base, 232 preexisting dirty paths and authorization limits. [Dependencies](dependencies.json) bind completed prerequisite evidence.

[Artifact reconstruction](artifact.json) reproduced the historical M11-004 SDK 1.1.3 development archive, SHA-256 `e430f08ff8596b1c43c1d1090b5c42d721abac3c03505656b2aea107ee7a079f`, and all 164 production inputs. The [raw report](native-final/report.json) and original artifact hashes are retained unchanged. The archive `native-final/wirestack-baseline.tar.gz` is preserved locally but withheld from public source PRs because its provider debug data embeds private machine paths. It is not replaced by a differently hashed artifact or newly qualified by publication. Installed consumers compiled with `-O2 -g`. The earlier P1-015 archive remains [unavailable](historical-reconstruction.json); it is not a measured before-version. Formal release qualification remains NOT_QUALIFIED.

## Executed work

The [measurement contract](../../performance/end-to-end-baselines.md) defines timing, workload, ownership and admission boundaries. Three installed native consumers cover 33 TCP, UDP, TLS, H1, H2, SSE, WebSocket, observation and overload scenarios.

Two process warmup rounds precede 14 measured rounds: **462 measured native executions; 82,236 operation latencies; 81,494 successes; 742 expected rejections; zero unexpected failures.** All terminal public ownership ledgers are zero. Normal, slow, overload, failure and cleanup outcomes remain separate. [Baseline table](baselines.md) links to raw per-operation latency, command exit status, checksums and resource samples.

## Attribution and decisions

[Attribution](attribution.json) contains 2,800 correlated native RequestStarted-to-BodyCompleted spans. The header stage is the largest observed warmed H1 stage, but includes peer/network waiting and is not parser CPU cost. Overlapping partial write/body stages are not summed into a fabricated E2E total. Enabled observation includes benchmark drain/correlation work.

The paired 4 KiB-to-32 KiB body-read-buffer candidate is **REJECTED**: 14 of 14 rounds are slower and tail latency worsens despite fewer actual read calls. Bytes, checksum, response contract, provider and limits are identical. No production optimization or API was introduced. Allocation/copy/lock costs remain explicitly unavailable; P1-001 vectored/borrowed buffers stay deferred.

The [seven-round versus seven-round comparison](comparison.json) returns **NOISY**, exit 2: three cases PASS, thirty NOISY. Full-corpus frozen references have three STABLE and thirty NOISY cases; noise never loosens a threshold into a pass. [Reusing the same executions](self-comparison-rejected.json) returns INCONCLUSIVE, exit 3. This is same-artifact repeatability, not a before/after source gain.

The original `cjprof` record file contains no sampling data; its failed report remains in the raw corpus. The alternate [native perf profile](native-perf.json) decodes 34 CPU-clock samples. Twenty land in the consumer read/inlined-callee region, which also includes checksum work. This small mixed sample supports inspection only, not quantitative bottleneck, allocation or copy claims. Private raw profiler data is retained outside the repository; normalized [record](native-perf-record.log) and [report](native-perf-report.log) logs are published.

## Failure evidence and verification limits

The [slow-reader failure](failures/interpretation.json) is retained. A capacity-one 65,535-byte whole-frame reservation rejected a sibling even after a verified prefix read returned protocol credit. The corrected capacity-two receive reservation remains bounded at 131,070 bytes while per-route/per-origin limits and the actual physical connection count stay one. This is a scenario configuration correction, not an identical-work gain or production fix.

[Final command results](final-command-results.json) record the historical architecture, public API and task checks. The task-gate receipt records PASS for 23 behavioral contracts on the original source snapshot; it does not verify current review changes. [Current source-bound verification](verification.json) exits 1 ([log](current-source-verification.log)). All digests and acceptance values under historical_* fields describe the measured snapshot, not current working-tree source or acceptance. No committed-source seal is claimed.

The publication privacy gate found an unredacted SDK loader path in capture metadata. [Privacy correction](privacy-correction.json) records the metadata-only redaction and capture-time fix; [live SDK metadata smoke](metadata-smoke/report.json) proves the corrected path with the qualified SDK. Native measurements and command-log digests are unchanged.

The original [dependency-closure fast gate](fast-gate.json) fails. Its two M12 digest-guard defects were fixed and the direct architecture check now passes. `cjdoc` independently exhausts its 256 MiB heap on unchanged public sources. A tool-only `CJ_HEAP_SIZE=1GB` attempt still reports a 256 MiB heap and fails the combined strict check; [tool-limit evidence](documentation-tool-limit.json) retains both failures. No SDK, documentation generator, production API or resource budget was changed to mask this limit. Full regression, other native platforms and formal release qualification were not executed by M12-001.

No commit, push, pull request, issue mutation or sibling repository modification was authorized or performed. Next READY tasks: M12-002, M12-003 and M12-004; none is started here.

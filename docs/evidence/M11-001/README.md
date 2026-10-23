# M11-001: bounded SSE codec and explicit reconnect sessions

**BLOCKED — no receipt under this directory binds the current sources.
Source-bound evidence must be regenerated before this task can return to COMPLETE.**
Issue [#178](https://github.com/lIlIIlIll/Wirestack/issues/178).
[Current source status](verification.json), [task inventory](../../../tools/tasks/M11-001.json),
and [historical receipts](historical/README.md).

The task inventory is authoritative for what this task owns. After Stack #200 the
owner PR was found to have changed `src/http/server.cj`,
`src/internal/http2/server_connection.cj` and `src/internal/http_resource_budget.cj`
without listing them, so `tools/tasks/M11-001.json` now binds those production
files and their tests in both `allowed_paths` and `source_paths`. A sealed record
therefore hashes every production file the task claims.

Two review rounds changed the SSE sources after the 2026-10-08 measurement, and
this branch then changed them again:

- `id:` values stay pending until the blank delimiter, so a block truncated at
  EOF cannot advance the reconnect cursor (#266);
- a drained `complete()` keeps normal EOF even when cancellation or expiry lands
  before the sender's next read (#267);
- the task inventory and this evidence layout bind every changed production file
  (#268).

Every previous receipt — native, installed consumer, one-hour H1/H2 profile, fuzz
corpus, strict documentation, task gate, workspace and the old verification index —
was moved byte-for-byte to [historical/](historical/README.md). It records the
working tree measured on 2026-10-08 and is **not** current validation. Nothing in
that directory may be cited for this revision.

No build, test, installed-consumer, documentation or one-hour profile command has
been executed for this branch. The regressions described below exist in source;
their outcomes are not claimed here, and no commit, push, PR, merge or issue
mutation was performed by this task.

## Current regressions

| Finding | Source change | Permanent regressions |
|---|---|---|
| #266 cursor only at dispatch | `src/sse/decoder.cj` | `SseDecoderTests.idLineStaysPendingUntilTheBlockBlankLineDispatches`, `pendingIdSurvivesTruncationAtEveryByteAndOnlyBlankLineAdvancesCursor`, `cursorAdvancesExactlyAtEachBlankDelimiterBytewise`; `SseNativeSessionTest.idLineTruncatedBeforeTheBlankDelimiterIsNotUsedOnReconnect`, `idOnlyBlockCommittedAtItsDelimiterReachesTheReconnectRequest` |
| #267 completed EOF precedence | `src/sse/writer.cj` | `SseWriterTest.completedRingKeepsEofWhenCancellationOrExpiryFollowsDrain`, `SseWriterTest.incompleteDrainStillReportsCancellationAndExpiry` |
| #268 evidence binding | `tools/tasks/M11-001.json` | `tools/tests/test_m11_001_evidence_inventory.py` |

## Historical scope and acceptance (2026-10-08, superseded)

The table below describes what the historical receipts measured. It is retained
as context for the design, not as evidence for the current candidate.

### Scope and acceptance

| Criterion | Executed evidence |
|---|---|
| Incremental UTF-8/BOM/CR/LF/CRLF, multiline and empty data, event/id/retry/comments/unknown fields, incomplete EOF | `SseDecoderTests`; 594 normative cut schedules; [reproducible corpus](historical/fuzz/corpus.json) |
| Malformed UTF-8 replacement, bounded line/block/fields/cursor/retry/no-progress state | Negative decoder cases and 1,536 deterministic mutations in `SseDeterministicFuzzTests` |
| Bounded event/comment encoding and server publication | `SseEncoderTest`, `SseWriterTest`; ring backpressure, flush, completion, partial-publication abort, close, cancellation and deadline |
| Explicit GET recovery, cursor versus acknowledgement, no POST replay or redirect | `SseNativeSessionTest`, `SseNativeFramingTest`; installed duplicate cursor/truncated GET and explicitly-safe POST cases |
| Canonical M10 time/resource/pool/event semantics | Absolute parent deadline/backoff and active-read idle tests; real managed-buffer reservation/cancelled admission waiter; native H1 discard/H2 sibling checks and request/attempt correlations |
| Impossible reservations fail without waiting or submitting | `unadmittableBufferFailsWithoutWaiterOrRequest`; zero and oversized DATA reservations |
| Distinct graceful EOF, local close, cancellation and truncation; fatal malformed framing/MIME | Native framing peers verify structured exceptions and original causes; owned bodies/leases return to zero |
| One hour and at least one million ordered events per protocol, steady resources, prompt cancellation | Production-session H1/H2 profile below; no substituted M6 parser |
| Installation independent of checkout paths | Eight checks in the extracted consumer; [compiled example](../../../../examples/linux/m11_001/sse.cj), 14 native server requests |
| Public API documentation and architecture | Six packages at 100% symbol/parameter coverage; generated HTML navigated through SSE to `SseSession`; architecture guard PASS; [current pre-1.0 inventory](../../../api/baselines/wirestack-linux-pre1-m11-001.json) |

The session holds an actual client DATA lease, not a facade counter. Parsed
Last-Event-ID is not application acknowledgement; duplicates remain possible.
GET recovery is disabled by default and finite when enabled. `oneShot` never
replays POST, even for a replayable, explicitly-safe request. `flush` means
consumption by the local HTTP body reader, not delivery to a peer.
See the [SSE guide](../../../guides/sse-linux.md) for defaults, hard ceilings,
ownership and [normative input](../../../references/whatwg-server-sent-events-2026-10-08.md).

### Exact native results

These results belong to the superseded 2026-10-08 measurement and are not
current validation.

| Command/scenario | Result |
|---|---|
| `scripts/check-task M11-001 --json --output docs/evidence/M11-001/task-gate.json` (historical) | Exit 0; all five selected task commands PASS |
| `cjpm check` | Exit 0 |
| `cjpm build --target-dir <scratch>/check-build-target` | Exit 0 |
| `cjpm test --target-dir target/m11-001-native --exclude-tags=Performance --parallel 1 --no-progress --no-color --timeout-each 60s` | Exit 0; 990 total, 962 passed, 28 explicitly skipped, zero failures/errors |
| SDK 1.1.3: `cjpm test src/sse --target-dir <scratch>/sdk-1.1.3-target --exclude-tags=Performance --parallel 1 --no-progress --no-color --timeout-each 60s` | Exit 0; 43 passed; two Performance cases explicitly skipped |
| `python3 -m unittest tools.tests.test_m7_026_linux_api_freeze tools.tests.test_m7_032_public_api_contract` | Exit 0; eight behavioral validator tests |
| `python3 tools/m11_001_native_sse.py` | Exit 0; eight extracted-install checks, no checkout path dependency |
| `env cjHeapSize=1GB scripts/check-docs --html --json --output docs/evidence/M11-001/docs-report.json` | Exit 0; cjdoc 0.7.2, six complete 100% coverage layers and generated HTML |
| `scripts/check-m7-032-public-api --json` | Exit 0; 356 declarations, 114 resolved aliases, zero internal aliases |
| `python3 tools/architecture_guard.py --root . --format text` | Exit 0; PASS |

Default native compiler/manager: Cangjie 1.3.0-alpha.06, target
`x86_64-unknown-linux-gnu`. SDK 1.1.3 was already qualified and was not rebuilt
or modified. Performance cases skipped in correctness commands are not counted
as passes; the one-hour profiles were executed separately with SDK 1.3.
Raw normalized outputs are under [native/](historical/native/) and [streaming/](historical/streaming/).

### Formal production-session profile

Executed both protocols concurrently for 3600 seconds, each requiring at least
1,000,000 numbered events. The real `SseSession`/`SseDecoder` consumes the stream;
the production encoder publishes numbered events. A slow-consumer phase tests
backpressure before steady streaming. Cancellation closes the owned stream;
H2 sibling requests are checked before and after it.

| Metric | HTTP/1.1 | TLS HTTP/2 |
|---|---:|---:|
| Elapsed milliseconds | 3,600,004 | 3,600,026 |
| Consumed events | 125,956,817 | 111,021,569 |
| Sequence errors | 0 | 0 |
| Cancellation nanoseconds | 227,662 | 4,028,917 |
| Heavy-GC heap growth bytes | 124,928 | 4,872,192 |
| RSS median growth KiB | 8,716 | 11,172 |
| FD/socket/thread growth | 0 / 0 / 0 | 0 / 0 / 0 |
| Managed bytes after session | 0 | 0 |
| Maximum producer lead events | 81,514 | 2,067 |

Fixed limits were not weakened: cancellation ≤50 ms, heavy-GC heap growth
≤32 MiB, RSS median growth ≤32,768 KiB, FD/socket/thread growth ≤2 each, and
producer lead ≤524,288 events. The application pending-event count is zero;
HTTP body staging remains 65,536 bytes. Both profiles retain their real session
reservation during active samples and release it at termination. H2 sibling
survival passed. This is a bounded-lifetime acceptance profile, not a throughput
improvement claim or benchmark comparison.

[Start receipt](historical/streaming/start.json) and final report seal the production sources
measured at that time and four compiled test artifacts. Start/end hashes are
identical within the recorded run, but the recorded inventory predates the
post-review `src/sse/decoder.cj` and `src/sse/session.cj` changes, so it no longer
matches the current sources and the profile was not rerun. The receipts are
retained as historical measurements only, not as source-bound evidence for the
current candidate.

Reproduction, inside the qualified SDK environment:

```sh
python3 tools/gates/m11_001_sse_streaming_profile.py \
  --env-runner <qualified-env-runner> \
  --target-dir <disk-backed-task-dir>/profile-target \
  --output <disk-backed-task-dir>/profile.json \
  --duration-seconds 3600 --minimum-events 1000000
```

The environment runner follows the repository's existing SDK gate convention.
Set `TMPDIR`, `TMP` and `TEMP` to that private disk-backed task directory.

### Integration corrections and limits

A prematurely terminated H1 chunk previously escaped the public body boundary
as an internal chunk exception. The boundary now preserves it as typed
`NetworkException(UnexpectedEof)` with the original cause, enabling explicit GET
recovery without retrying malformed framing. Empty MIME metadata no longer
indexes an empty split result. Reservations larger than possible DATA capacity
fail before queue admission. Permanent native negative cases cover each path.

An initial full run imposed a 10-second per-case limit: two existing TLS fuzz
cases timed out, and the new close-only fixture exposed a serve-start race.
The fixture now performs a real response exchange before use; the final full
suite uses a finite 60-second cap and passes. Strict docs initially rejected an
undocumented exception method and could not document the new derived enum;
explicit equality follows existing public enum conventions, and every SSE
symbol now appears in the complete generated surface.

Existing M10 and unrelated dirty work was preserved. Historical API snapshots
were not rewritten. The current inventory/checker includes all six public
packages and retains the pre-1.0 no-compatibility-verdict policy. No gzip,
WebSocket lifecycle expansion, browser/CORS or application acknowledgement
feature was added. Next READY task: **M11-002**; M11-003 remains READY separately.

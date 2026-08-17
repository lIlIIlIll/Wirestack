# Performance methodology

Performance claims are backend- and representation-specific. Typed codecs,
`JsonValue`, Pure Compact, Custom Native DOM, yyjson Direct Native DOM, serde
Value, raw yyjson, and simdjson DOM are not interchangeable results.

The retained Round-18 architecture was measured on an Intel Xeon Gold 6248R,
CPU 8 affinity, Cangjie SDK 20260803, Cangjie `-O2`, and native C
`-std=c11 -O3 -fPIC -DNDEBUG` without `-march=native` or LTO. Representative
yyjson semantic-adapter release-smoke ranges were:

| Workload | Approximate retained range |
|---|---:|
| Flat64 | 0.59–0.62 s |
| ObjectArray64 | 0.34 s |
| numeric64 | 0.42 s |
| Canada | 3.5 ms |
| Twitter | 0.89 ms |
| CITM | 1.55 ms |

These figures are regression references, not universal promises. They include
YJson-required duplicate, number, Unicode, and lifetime semantics. Raw yyjson
kernel numbers are a ceiling reference and must not be presented as adapter API
performance.

Memory also depends on shape. yyjson is often speed-for-memory relative to
Custom Native on huge objects, while numeric-heavy inputs may improve both time
and memory. Native heap reduction is not automatically total RSS reduction.

The grouped/control-byte semantic-index experiment was rejected and is not in
production: scalar candidates regressed about 47–48%, AVX2 candidates about
93–112%. Production retains the packed 8-byte semantic/runtime index. Native
DOM performance architecture is frozen for this release candidate; release
hardening reopens performance work only after a stable >10% regression or new
evidence of at least 15% realistic end-to-end upside.

## Generated ordered-object fast path (2026-08-17)

Generated typed codecs now probe their canonical compact field sequence before
entering the general object-name dispatcher. A failed probe does not advance the
reader, so reordered fields, aliases, escaped names, unknown fields, whitespace,
and duplicate-field handling retain the existing fallback semantics.

The retained change was measured against the pre-change snapshot on the same
Xeon Gold 6248R host, pinned to CPU 8, Cangjie SDK 20260803, and a 128 MB heap.
Eleven alternating fixed-workload pairs produced these medians:

| Typed decode workload | Baseline | Ordered path | Improvement |
|---|---:|---:|---:|
| ProfileRecord string | 825.629 ns/op | 720.801 ns/op | 12.68% |
| ProfileRecord bytes | 863.206 ns/op | 759.710 ns/op | 12.09% |
| Person string | 2974.754 ns/op | 2191.537 ns/op | 26.56% |
| Person bytes | 3015.710 ns/op | 2558.319 ns/op | 17.15% |

The ProfileRecord samples had 0.39-1.44% per-side CV. Paired framework medians
also showed an 18.44% improvement across the six large/deep generic object
decode guards. Individual framework samples were GC-noisy, so their positive
unknown-field, reordered-field, and pretty-input results are retained as
directional regression guards rather than primary performance claims.

On the fixed ProfileRecord string probe, five-run hardware counters decreased
from 753.4M to 675.1M cycles and from 1.823B to 1.572B instructions. Five paired
RSS observations had medians of 91,712 KiB before and 91,636 KiB after. An empty
generic-collection shortcut was evaluated separately and rejected after its
stable fixed probe regressed string decode by 1.00% and bytes decode by 0.89%.

## Reusable generated fast decoder (2026-08-17)

`YJson.fastDecoder(codec)` resolves the generated fast-decoder contract once.
The returned `JsonFastDecoder<T>` exposes non-generic `decodeString` and
`decodeBytes` methods implemented directly by each supported generated,
non-generic object codec. Existing `FooJson` declarations and `decodeStringWith` / `decodeBytesWith`
signatures are unchanged. Explicit read configurations use the regular direct
reader so unknown-field, duplicate-key, number, location, and depth policies
retain their existing semantics.

The final fixed probe used the same Xeon Gold 6248R host, CPU 8, SDK 20260803,
`-O2`, `cjHeapSize=128MB`, 100,000 decodes per process, and eleven alternating
baseline/candidate pairs:

| ProfileRecord workload | Existing generic API | Reusable decoder | Improvement | Baseline CV | Candidate CV |
|---|---:|---:|---:|---:|---:|
| String | 2,136.718 ns/op | 1,781.112 ns/op | 16.64% | 3.32% | 2.38% |
| Bytes | 2,272.406 ns/op | 1,890.617 ns/op | 16.80% | 2.94% | 2.81% |

The string baseline missed the 3% per-side CV target by 0.32 percentage points;
independent retries were more GC-noisy under the 128 MB heap. The string result
is therefore supported by the paired effect, counters, and profile rather than
presented as an all-sides low-variance latency result. The bytes comparison met
the per-side CV target directly.

Seven paired `perf stat` runs reduced median cycles from 528.4M to 484.2M
(-8.38%) and instructions from 1.050B to 981.6M (-6.48%). In the final sampled
profile, the previous generic TypeInfo descriptor lookup was absent above the
0.1% reporting threshold; the two remaining TypeInfo method-table symbols
totalled 1.41%. Five paired maximum-RSS observations had medians of 75,044 KiB
and 75,540 KiB (+0.66%), within the 1% no-regression gate.

## Rejected reusable fast-decode session experiment (2026-08-17)

A caller-owned session that reused `JsonFastReader`, `JsonDecodeContext`, and
path-buffer capacity was implemented and tested, then removed because it did
not pass the frozen all-workload acceptance gate. The experiment used commit
`5822c09` as baseline on the same Xeon Gold 6248R host, CPU 8, SDK 20260803,
`-O2`, and `cjHeapSize=128MB`. Two independent rounds each collected eleven
alternating process samples for baseline decoder, candidate decoder, and
candidate session.

The second round's diagnostic medians were:

| Workload | Baseline decoder | Candidate decoder | Session | Session delta |
|---|---:|---:|---:|---:|
| ProfileRecord string | 1,365.512 ns | 1,356.914 ns | 508.047 ns | +62.79% |
| ProfileRecord bytes | 1,549.674 ns | 1,508.829 ns | 566.107 ns | +63.47% |
| Address string | 1,520.324 ns | 1,532.868 ns | 532.577 ns | +64.97% |
| Address bytes | 1,550.821 ns | 1,526.123 ns | 608.093 ns | +60.79% |
| Person string | 4,285.274 ns | 4,345.353 ns | 4,466.658 ns | -4.23% |
| Person bytes | 4,845.357 ns | 5,020.067 ns | 5,000.557 ns | -3.20% |

These are rejection diagnostics, not retained latency claims: several per-side
CV values remained above 3% after the mandatory retest, Person regressed in
both input forms, and candidate decoder Person bytes was 3.61% slower than the
baseline. The session therefore failed the requirements that every workload
must avoid regression and that the ordinary decoder stay within 2%.

The rejected candidate did reduce aggregate median GC count by 42.86% and
GC-freed bytes by 45.11%. Five ProfileRecord-string `perf stat` pairs reduced
median cycles from 495.9M to 266.3M and instructions from 999.0M to 355.6M.
Median process maximum RSS was 80,754 KiB for baseline and 58,310 KiB for the
single-session path. After decoding and releasing a 4 MiB unknown field, a
forced-GC probe reported 1,216,512 heap bytes versus 811,008 before, rather than
retaining the input size. These positive signals did not override the required
Person and variance gates, so no session API remains in the library.

The reusable analyzer is `scripts/json_fast_session_summary.py`; raw evidence
is preserved in the Server experiment directory
`<home>/yjson-session-20260817-Codex` and local ignored `target/`
evidence directories.

## Rejected adaptive session follow-up (2026-08-17)

The follow-up tested a generated shape gate: flat scalar/String objects reused
session state, while container/nested objects such as `Person` fell back to the
stateless decoder. The analyzer was corrected to use per-round paired medians
instead of ratios of independently aggregated medians.

Variant A reused only `JsonDecodeContext` and kept `JsonFastReader` immutable.
Its five-pair Server screen rejected the design immediately: the six paired
results ranged from -6.68% to +1.83%, with no retained flat-object gain.

Variant B reused reader and context only for flat codecs. Its final wrapper-free
screen restored the desired flat effects but still failed the frozen gates:

| Workload | Five-pair session delta | Candidate decoder delta |
|---|---:|---:|
| ProfileRecord string | +67.48% | -0.23% |
| ProfileRecord bytes | +65.44% | +1.41% |
| Address string | +69.73% | +4.55% |
| Address bytes | +57.24% | +4.58% |
| Person string | -1.27% | +1.82% |
| Person bytes | -0.44% | +2.12% |

This was a screening result, not a publishable latency conclusion: several CVs
were above 3%, both `Person` cases remained negative, and ordinary decoder
regressions exceeded 2%. The planned eleven-pair formal run was therefore not
started, and the session API and implementation were removed again. Raw screens
remain under `<home>/yjson-adaptive-session-20260817` and ignored local
`target/perf-adaptive-session-screen-*` directories.

## Rejected Person internal hot-path experiments (2026-08-17)

A fresh Server profile of the frozen `5822c09` Person string decoder measured
4,378.228 ns/op, two GCs, and 84,410,368 GC-freed bytes per 100,000 decodes.
GC phase work accounted for 20.92% of sampled cycles; compact ordered-name
probing accounted for 6.87%, string parsing/materialization for about 7.8%, and
HashMap/array initialization was also visible. The existing String-list and
Int64-map fast helpers were already active.

Three semantic-preserving changes were screened independently with five
alternating Server pairs. None passed the frozen requirement that both Person
inputs be nonnegative, at least one improve by 2%, and guards stay within 1%:

| Experiment | Person string | Person bytes | Rejection evidence |
|---|---:|---:|---|
| Fixed-length ordered-name comparisons | +0.80% | -0.90% | ProfileRecord/Address guards regressed about 2–4% |
| Inline first decode-path component | -5.79% | +8.20% | Direction split by input; guards regressed; GC-freed bytes fell 11.48% |
| Generated String-list/Int64-map loop fusion | +0.85% | +1.39% | Below 2%; ProfileRecord string regressed 3.71% |

Because no individual change passed screening, the changes were not combined
and the eleven-pair formal run was not started. All production code was
restored. The fixed probe and paired analyzer remain in
`packages/person_hotpath_probe` and `scripts/json_person_hotpath_summary.py`;
raw evidence is preserved under
`<home>/yjson-person-hotpath-20260817` and ignored local
`target/perf-person-hotpath-phase*` directories.

## Rejected generated Borrowed View experiment (2026-08-17)

A source-backed `TypeJsonViewSession` protocol was implemented for every
`@JsonCodec` model. It reused caller-owned reader/context/scratch state, avoided
owned String/container/model results on specialized fields, invalidated old
views by generation, required custom `@JsonUsing` codecs to provide a
non-constructing validator, and released input references on reset, error, or
the next bind. The public API and implementation were removed after the frozen
release gates failed.

The source-verified baseline was the production snapshot underlying common-base
commit `a9c962d`. Measurements used the Xeon Gold 6248R Server, CPU 8, SDK
20260803, `-O2`, and `cjHeapSize=128MB`. The first eleven-round, three-way
alternating run compared the frozen decoder, the candidate's ordinary decoder,
and the candidate View with complete result traversal:

| Workload | Borrowed paired gain | Positive pairs | Baseline/View CV |
|---|---:|---:|---:|
| ProfileRecord string | +52.19% | 11/11 | 3.65% / 8.29% |
| ProfileRecord bytes | +56.56% | 11/11 | 5.55% / 5.90% |
| Address string | +54.81% | 11/11 | 3.72% / 5.52% |
| Address bytes | +56.53% | 11/11 | 5.86% / 5.89% |
| Person string | +31.99% | 11/11 | 2.87% / 3.52% |
| Person bytes | +42.29% | 11/11 | 3.78% / 11.68% |

All six effect and positive-pair gates passed, and aggregate measured GC count
and GC-freed bytes fell by 100%. They are rejection diagnostics rather than
publishable latency claims: the mandatory 3% per-side CV gate failed, while the
candidate ordinary decoder showed -4.87% on ProfileRecord bytes and -2.49% on
Person string in that View-linked process, beyond the 2% limit.

Several follow-ups separated the owned-only consumer binary, removed eager
View-session/codec objects, restored the original generated codec interface,
and eliminated redundant next-bind cleanup. The optimized isolated
ProfileRecord-string sample reached +54.92%, and an owned-only run reached the
ordinary non-regression range, but repeated eleven-sample runs still exceeded
3% CV because another Server workload repeatedly changed socket/core frequency.
A 500,000-iteration diagnostic stabilized Person but changed the frozen flat
GC workload and therefore was not substituted for the 100,000-iteration gate.
No delayed latency or hardware-counter claim is published.

Non-latency safeguards passed before rollback. A clean build grew from 156.51s
to 172.63s (+10.30%, within 15%), and the probe binary grew from 16,021,376 to
16,613,256 bytes (+3.69%, within 10%). After twelve distinct 4 MiB inputs, forced
GC reported 569,352 allocated bytes after the first input, a 608,920-byte peak,
and 570,080 bytes at the end, demonstrating no cumulative input retention.
These signals did not override the latency/CV/ordinary-decoder gates.

Production contains no Borrowed View/session API from this experiment. The
owned full-traversal probe, baseline harness, three-way sampler, counter sampler,
and strict analyzer remain in `packages/person_hotpath_probe`,
`benchmarks/borrowed_view_baseline_main.cj`,
`scripts/json_borrowed_probe_run.py`, `scripts/json_borrowed_perf_stat.py`, and
`scripts/json_person_hotpath_summary.py`. Raw append-only evidence is retained
under `<home>/yjson-borrowed-formal-20260817/evidence` on the Server.

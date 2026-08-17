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

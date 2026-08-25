# Testing yjson

This guide defines stable test layers and release expectations. One-off execution
details belong in release evidence rather than this document.

## Test layers

| Layer | Scope | Primary entry point |
|---|---|---|
| Core unit and contract tests | parser, writer, codecs, AST, Compact, streams, Schema, limits | `cjpm test` |
| External codec consumer | caller-package `@JsonCodec`, enum, polymorphism, fast decoder | `packages/codec_integration` |
| JSON literal consumer | `@Json`, `@JsonValue`, interpolation order, dynamic LastWins | `packages/json_literal_integration` |
| Standards conformance | pinned JSON Schema, JSONPath and JSON Patch suites through public API | `scripts/run_standards_conformance.py` |
| Compile-fail macro tests | invalid literal grammar and duplicate static keys | `scripts/check_json_literal_compile_fail.sh` |
| Custom Native package | DOM lifecycle, policies, resource limits | `packages/yjson_native` |
| yyjson package | Direct DOM lifecycle, semantics, resource limits | `packages/yjson_yyjson` |
| Native C checks | warnings, scanner/DOM tests, sanitizers, differential fuzz | `scripts/release_native_checks.sh` |
| External release consumers | staged core, macro, Custom Native, yyjson packages | `scripts/release_consumer_checks.py` |
| Package/release boundaries | manifests, source staging, symbols, licenses | release scripts |

## CI mapping

`scripts/ci_job.sh` is the reusable job dispatcher:

| Job | Evidence |
|---|---|
| `api-inventory` | declaration, C ABI, and package-pairing inventory |
| `core` | core test suite without a C build hook |
| `standards-conformance` | pinned JSON Schema required, JSONPath CTS, and JSON Patch suites |
| `examples` | documented Pure Cangjie example |
| `macro-consumer` | literal consumer, compile-fail cases, staged macro consumer |
| `custom-native` | optional package tests, external consumer, no yyjson symbols |
| `yyjson-native` | offline vendored package tests and external consumer |
| `native-clang` / `native-gcc` | warning-clean targeted C checks |
| `sanitizer` | ASan, UBSan, and leak detection |
| `fuzz-short` / `fuzz-extended` | deterministic backend differential semantics |
| `yyjson-colink` | vendored symbol isolation with the pinned second version |

Fresh-source and hosted executions are separate evidence and must never share one status.

## Feature × backend coverage

| Public behavior | Pure core | Custom Native | yyjson Direct | External consumer |
|---|---:|---:|---:|---:|
| RFC parser and serializer behavior | yes | differential | differential | examples |
| Generated class/struct/enum codec | yes | n/a | n/a | codec integration |
| Polymorphic generated codec | yes | n/a | n/a | codec integration |
| JSON literals and dynamic keys | yes | n/a | n/a | literal integration |
| Stream ownership and limits | yes | n/a | n/a | core tests |
| Mutable AST | yes | materialization only | serialization materialization | examples |
| Compact read-only query | Pure Compact | native view | coarse root query | release consumers |
| Duplicate/number/resource policies | yes | yes | yes | release consumers |
| Deterministic close and use-after-close | n/a | yes | yes | release consumers |
| Schema | yes | n/a | n/a | core tests |
| JSON Pointer/Patch/Path | yes | n/a | n/a | official conformance consumer |

“Differential” means the Native C harness compares semantic results against the
portable contract; it does not make the Native DOM API identical to `JsonNode`.

## Test policy

- Test public results, errors, lifecycle, package boundaries, and compatibility.
- Keep white-box tests only where a public contract cannot expose the scanner or
  generated-code regression safely.
- Specify one expected outcome. Phrases such as “accept or reject” are not test
  cases until the product contract chooses one behavior.
- Treat performance measurements as benchmark evidence, not correctness tests.
- Record fixed JSONTestSuite or other external corpus revisions when imported;
  do not rely on an unpinned upstream checkout.
- Release-blocking policy belongs in the stable release procedure. Actual
  command results, commit IDs, SDK identity, timestamps, logs, and checksums
  belong in release-specific evidence.

## Standards conformance gate

The standards gate fixes upstream revisions and validates expected cardinalities through an
independent public-API consumer. The release-blocking default is:

| Suite | Required result |
| --- | ---: |
| JSON Schema draft 2020-12 required | 1299/1299 |
| JSONPath CTS | 703/703 |
| JSON Patch tests | 108/108 |

Installing the optional `yjson_schema_formats` provider adds 964 applicable optional tests. The
current result is 964/964 for that layer and 3074/3074 overall. The default 2110-case gate does not
install the provider.

## Executable exit-status gate

Executable gates must propagate unhandled application exceptions as failures; shell success alone
is not sufficient. The external codec consumer covers generated polymorphic decode with the default
unlimited budget and a positive-budget overflow case.

## Historical plan

The former root `TEST_PLAN.md` is archived as
[`docs/archive/initial-parser-test-plan.md`](../archive/initial-parser-test-plan.md).
Its gap counts, ambiguous outcomes, and future-work statements are historical.

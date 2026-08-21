# Testing yjson

This guide defines the stable test layers and commands. Test counts and one-off
release results are intentionally not copied here; command output and immutable
release evidence are the source of truth for those values.

## Test layers

| Layer | Scope | Primary entry point |
|---|---|---|
| Core unit and contract tests | parser, writer, codecs, AST, Compact, streams, Schema, limits | `cjpm test` |
| External codec consumer | caller-package `@JsonCodec`, enum, polymorphism, fast decoder | `packages/codec_integration` |
| JSON literal consumer | `@Json`, `@JsonValue`, interpolation order, dynamic LastWins | `packages/json_literal_integration` |
| Compile-fail macro tests | invalid literal grammar and duplicate static keys | `scripts/check_json_literal_compile_fail.sh` |
| Custom Native package | DOM lifecycle, policies, resource limits | `packages/yjson_native` |
| yyjson package | Direct DOM lifecycle, semantics, resource limits | `packages/yjson_yyjson` |
| Native C checks | warnings, scanner/DOM tests, sanitizers, differential fuzz | `scripts/release_native_checks.sh` |
| External release consumers | staged core, macro, Custom Native, yyjson packages | `scripts/release_consumer_checks.py` |
| Package/release boundaries | manifests, source staging, symbols, licenses | release scripts |

## Local commands

Prepare the configured Cangjie environment before running `cjpm` commands.

```bash
cjpm test --no-color
scripts/run_cjpm_executable.sh packages/examples
scripts/run_cjpm_executable.sh packages/codec_integration
scripts/run_cjpm_executable.sh packages/json_literal_integration
scripts/check_json_literal_compile_fail.sh
(cd packages/yjson_native && cjpm test --no-color)
(cd packages/yjson_yyjson && cjpm test --no-color)
```

Native validation is split by purpose:

```bash
YJSON_NATIVE_CHECK_MODE=targeted scripts/release_native_checks.sh
YJSON_NATIVE_CHECK_MODE=sanitizer scripts/release_native_checks.sh
YJSON_NATIVE_CHECK_MODE=fuzz YJSON_FUZZ_CASES=5000 scripts/release_native_checks.sh
```

Use the extended fuzz count only for a release/nightly gate. Do not replace a
semantic test with a higher fuzz count.

## CI mapping

`scripts/ci_job.sh` is the reusable job dispatcher:

| Job | Evidence |
|---|---|
| `api-inventory` | declaration, C ABI, and package-pairing inventory |
| `core` | core test suite without a C build hook |
| `examples` | documented Pure Cangjie example |
| `macro-consumer` | literal consumer, compile-fail cases, staged macro consumer |
| `custom-native` | optional package tests, external consumer, no yyjson symbols |
| `yyjson-native` | offline vendored package tests and external consumer |
| `native-clang` / `native-gcc` | warning-clean targeted C checks |
| `sanitizer` | ASan, UBSan, and leak detection |
| `fuzz-short` / `fuzz-extended` | deterministic backend differential semantics |
| `yyjson-colink` | vendored symbol isolation with the pinned second version |

`scripts/ci_fresh_checkout.sh` runs the configured job set from a fresh source
tree. A local simulation and a hosted CI execution are separate evidence and
must never share one status.

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

## Executable exit-status gate

`cjpm run` in the currently qualified toolchain can return exit code 0 after an
unhandled application exception. Release and CI consumer gates therefore use
`scripts/run_cjpm_executable.sh`: it builds with `cjpm`, then executes
`target/release/bin/main` directly so runtime failures propagate as non-zero.
The external codec consumer covers generated polymorphic decode with the
default `maxPolymorphicObjectBytes = 0` and a positive-budget overflow case.

## Historical plan

The former root `TEST_PLAN.md` is archived as
[`docs/archive/initial-parser-test-plan.md`](../archive/initial-parser-test-plan.md).
Its gap counts, ambiguous outcomes, and future-work statements are historical.

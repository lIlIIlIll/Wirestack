# Release checklist

Statuses are filled by the release gate and final release review. A release is
blocked by correctness or memory-safety failure, a missing package input,
mandatory optional dependency, missing license, broken documented example,
ambiguous native lifetime, or a source package that cannot build independently.

| Gate | Required status |
|---|---|
| Public API inventory and freeze decision | PASS |
| Pure Cangjie core build and tests | PASS |
| Runtime+macros downstream consumer | PASS |
| Custom Native build with yyjson absent/disabled | PASS |
| yyjson Direct offline build and package tests | PASS |
| C scanner/custom/yyjson tests with warning gates | PASS |
| ASan, UBSan, and LSan | PASS |
| Short deterministic differential fuzz | PASS |
| 50k extended differential fuzz | PASS before release |
| Linux x86_64 compiler/libc qualification | PASS |
| Optional package and archive boundaries | PASS |
| Root Apache-2.0 and vendored yyjson MIT text | PASS |
| README examples and backend/lifetime docs | PASS |
| Source-only manifest and clean temp-tree build | PASS |
| Distribution core excludes test/example support API | PASS |
| External core/macro/native/yyjson consumers | PASS |
| Binary dependency and yyjson symbol-isolation audit | PASS |
| GitCode CI workflow and fresh-checkout simulation | PASS; hosted run pending authorized push |
| Registry-style package rehearsal and four consumers | PASS |
| Performance regression smoke | no stable >10% regression |
| Version and release notes | PASS |
| Commit, tag, and publish | NOT RUN during RC hardening |

Suggested CI jobs:

1. `core`: `cjpm test` with no C build hook.
2. `examples`: build and run the public core example.
3. `macro-consumer`: build/run the external-style `@JsonCodec` fixture.
4. `custom-native`: package tests plus external consumer, with yyjson disabled.
5. `yyjson-native`: package tests plus external consumer; vendored source, offline.
6. `native-clang` and `native-gcc`: project-owned C warning and targeted tests.
7. `sanitizer`: ASan+UBSan with leak detection.
8. `fuzz-short`: deterministic 5k cases on pull requests.
9. `yyjson-symbol-isolation`: pinned dual-version co-link fixture.
10. `fuzz-extended`: deterministic 50k+ cases nightly/manual.

Linux x86_64 is qualified. AArch64 is source-portable but unqualified; musl is
not tested. Do not advertise either as supported until an actual SDK, build,
tests, sanitizers, and consumer fixture pass there.

## Current RC evidence

- The source-only release manifest contains 103 files and excludes `target/`,
  object files, archives, shared libraries, performance corpora, and results.
- A clean temporary source tree passed the 485-test core suite, examples,
  Custom Native's 7 tests, yyjson Direct's 5 tests, and external core, macro,
  Custom Native, and yyjson consumer fixtures.
- The C release gate passed Clang and GCC warning builds, targeted scanner,
  Custom Native, and yyjson tests, ASan, UBSan, LSan, and 50,000 deterministic
  differential cases.
- yyjson is built offline from the unmodified vendored 0.12.0 source and its MIT
  license is included in the staged package.
- Registry staging uses exact `1.0.0` central dependencies and no path
  dependencies. Native packages are source-built from their staged package
  inputs. An isolated registry-style rehearsal inspected all five artifacts and
  built and ran core, macro, Custom Native, and yyjson consumers. `cjpm` 1.1.3
  has no local-registry or publish dry-run mode, so no real registry publish was
  performed.
- Release checks reject a mixed Cangjie SDK environment before compiling. The
  selected `cjc`, `CANGJIE_HOME`, `CANGJIE_SDK_ROOT`, and `CJ_SDK_LIBPATH` must
  describe one SDK installation.
- GitCode CI workflows now call the same reusable release scripts from isolated
  jobs on a self-hosted Linux x86_64 runner labelled `cangjie-1.1`. A complete
  fresh source-tree simulation passed locally. Hosted execution is **NOT RUN**
  because this hardening round did not authorize a push; the runner must provide
  one coherent SDK via the documented Cangjie environment variables.
- The yyjson backend localizes upstream `yyjson_*` symbols at build time. Its
  final shared library exports zero such symbols. A pinned 0.11.1 dual-version
  fixture passes both load orders while the adapter reports vendored 0.12.0;
  vendored source remains unmodified.

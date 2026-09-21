# M8-008 HTTP consumer contracts

Status: COMPLETE. All seven contracts and the isolated native gate passed.

## A. Workspace safety

Repository: `<repo-root>`. The starting branch was
`docs/m7-033-cjdoc-072-comments`, HEAD
`8ac21ebbe13052aa669d170da4faff1c37a70413`; merge base with `main` was
`d3cc9e4a4bedf9091285ed7e26d86fdc2def013c`.
The task branch is `task/M8-008-http-consumer-contracts`.
The initial status contained 7 staged, 169 unstaged and 80 untracked paths;
[workspace-safety.txt](workspace-safety.txt) preserves the safety record.
The ordinary branch creation preserved the index and working files.
No commit, push, PR, issue update, reset, clean, stash or destructive checkout was performed.

M8-005, M8-006 and M6-022 were verified COMPLETE before implementation.
Their evidence and accepted ADR-0001 through ADR-0008 were reviewed.
No language server was configured; bounded textual reference searches were used.

## B. Task status

M8-008 is COMPLETE; [evidence.json](evidence.json) binds the final source and reports.
This task does not change the historical M8-007 release, signing or soak conclusions.

## C. Seven contracts and acceptance evidence

| Contract | Implemented and exercised behavior | Evidence |
|---|---|---|
| P001: lossless no-follow | `HttpRedirectPolicy.noFollow()` preserves all five redirect statuses, Location and unread body; the target receives no request. Missing/malformed Location is not parsed. Existing `maximumRedirects: 0` semantics remain unchanged. | [HTTP 101/101](http-tests.json); installed public example in the native gate |
| P002: cancellation and total deadline | One absolute deadline reaches DNS, TCP, TLS, headers, retries, redirects and body reads. Cancellation is idempotent; real stalled TLS/header/body I/O wakes after admission. Parent/builder precedence and non-positive timeouts are covered. | [HTTP](http-tests.json), [internal suites](internal-tests.json) |
| P003: TLS defaults | Default trust rejects the self-signed peer; custom trust still rejects the wrong identity. Required mTLS succeeds with client identity and rejects its absence. A discovered test-owned system PEM completes a verified handshake. | [HTTP](http-tests.json), [TLS/internal](internal-tests.json) |
| P004: ResponseBody ownership | Stable EOF, premature EOF, concurrent-reader exclusion, primary-error precedence and exactly-once close/observer notification. H2 request bodies still wait for protocol EOF and trailers. | [Failure-first evidence](regression-evidence.json), [HTTP](http-tests.json), [internal](internal-tests.json) |
| P005: retry and safe errors | `maximumAttempts: 1` prevents another HTTP execution; retry budgets remain per redirect hop. CONNECT rejection preserves structured fields without proxy reason/body secrets. | [HTTP](http-tests.json), [internal](internal-tests.json) |
| P006: server lifecycle | H1/H2 response ownership includes pre-commit and after-hook failures. H2 waits retain the serve context; connection termination wakes body readers. Drain/admission is atomic; bounded shutdown and cooperative task joins converge. | [Failure-first evidence](regression-evidence.json), [HTTP](http-tests.json), [internal](internal-tests.json) |
| P007: native closure | Two fresh isolated builds produced identical raw provider, resolver and release archives. Installed examples, ELF/runtime closure and snapshot-only canonical checking passed. | [Native gate](native-contracts.json), [canonical check](canonical-check.json), [runner 6/6](runner-tests.json), [negative gates](negative-gates.json) |

The [P/S/T matrix](test-plan.md) distinguishes loopback execution, injected stages,
paired in-memory TLS and functional bounds. All 124 bound Cangjie source files
matched the working bytes used by the affected-suite runs:
[test-source-identity.json](test-source-identity.json).

## D. Changed areas

- HTTP policy, client injection seam, response ownership, server dispatch and their regressions:
  `src/http/`, `src/http_message.cj`, `src/http_contract.cj`.
- H1 writer/proxy ownership; H2 state, connection and exchange lifecycle:
  `src/internal/http1/`, `src/internal/http2/`.
- StdNet admission diagnostics and TLS trust/mTLS fixtures:
  `src/internal/transport_stdnet/`, `src/internal/tls_engine/`.
- Public executable example: `examples/linux/m7_027/http_examples.cj`.
- Guides: `docs/guides/http1-linux.md`, `docs/guides/migrate-to-wirestack-linux.md`.
- Task runner and regressions: `tools/m8_008_http_contracts.py`,
  `tools/tests/test_m8_008_http_contracts.py`.
- Canonical-check repairs: root-relative exclusions in `tools/evidence_digest.py`
  and its regression; hermetic M7-030 signing fixtures reusing the M7-025 fixture;
  removal of obsolete literal-count and whole-historical-snapshot assertions in
  the task-graph, candidate and performance tests.
- Task contract, backlog/status and this evidence directory. The exact permitted
  files and bound inputs are listed in `tools/tasks/M8-008.json`.

No Axyndra or other repository was modified. Repository dependency/packaging
manifests, lockfiles, CI and the original generated API documentation were not regenerated.
The [preservation report](workspace-preservation.json) confirms 229 protected
files still match their frozen working bytes.

## E. Native and historical boundaries

Execution platform: Linux x86_64 glibc 2.44, kernel `7.2.3-arch1-3`.
Cangjie: `1.1.0-alpha.20260829040003 (cjnative)`; CJPM: `1.1.3`.
Documentation tool: actual `cjdoc 0.7.2`, usable with an isolated HOME.

AWS-LC 5.5.0 is read-only input, pinned to commit
`991e67ff4cf04df4dd89e407f8b920c6936cb56a`, tree
`ae54cd9455f9630451d505855afe808a9f028b25`, content SHA-256
`0058686c2ce423c9c416c0597ae84bb30d07ee71271acf58e110f69f802f6478`.
A/B have separate repositories, native outputs, caches, HOME and release roots.
Each snapshot has its own Git index and discovery boundary; canonical checks do
not inherit forced native compiler overrides.


The final [native report](native-contracts.json) is PASS, exit 0, from run
`20260909T191258.619736Z-2128850-2824ceb0`. All command logs are retained in
[`native-logs/`](native-logs/). The raw release archive SHA-256 is
`7a034e5ec0288c7c9fb94e3142203fa4f027b2c86588d529243e221be8477715`.
The installed consumer ran all nine existing public example markers, including
HTTPS, mTLS, H2 and the HTTP1 marker after the no-follow assertions.
Its direct ELF dependencies are `libboundscheck.so`, `libcangjie-runtime.so`,
`libm.so.6` and `libc.so.6`; transitive C++/loader dependencies are recorded.
No unresolved libraries, OpenSSL dependency or forbidden runtime loader strings
were found. Runtime metadata reports AWS-LC 5.5.0 and
`externalOpenSslDependency=false`.

The [canonical check](canonical-check.json) passed 425 repository, 177 gate and
24 benchmark-harness Python tests. Cangjie check/build passed; its complete
non-Performance run passed 657 of 680 tests, with 23 explicit Performance
exclusions and no errors/failures. These are not benchmark execution claims.
Cjdoc 0.7.2 documented 1316/1316 symbols and 580/580 parameters.
The new generated output is retained in [generated-api.tar.gz](generated-api.tar.gz);
the original checkout's generated documents were preserved.

The failed integration attempts are retained as
[native-first-run.json](native-first-run.json),
[native-second-run.json](native-second-run.json) and
[native-third-run.json](native-third-run.json), with corresponding canonical logs.
They passed native stages 1–6 but are not overall acceptance PASS reports.
Their failures exposed historical-artifact coupling and a digest scanner that
incorrectly excluded a checkout merely because an ancestor was named `build`.
The scanner now excludes generated children relative to the checkout root;
its negative regression failed before the fix and passed afterward.

Historical signing tests now create temporary artifacts and supply documents,
perform real signatures and retain tamper rejection. They do not rewrite the
historical M7-025 bundle. The historical performance gate still rejects current
HTTP/2 source drift: [read-only observation](historical-performance-observation.json).
Its source-binding and threshold guards remain covered by
[8 passing tests](performance-boundary-tests.json). No performance baseline was repinned.

## F. Commands and exact results

Cangjie commands used `<home>/.codex/scripts/codex_cangjie_env` as the
outer SDK launcher. Reports retain expanded argv, cwd, exit status and raw logs.

| Command | Result |
|---|---|
| `cjpm test src/http -j 1 --parallel 1 --show-all-output --no-progress --no-color` | Exit 0; 101 passed, 0 skipped/errors/failures |
| `cjpm test src/internal/transport_stdnet src/internal/http1 src/internal/http2 src/internal/tls_engine src/internal/platform/linux -j 1 --parallel 1 --exclude-tags=Performance --show-all-output --no-progress --no-color` | Exit 0; 404 total, 384 passed, 20 Performance exclusions, 0 errors/failures |
| `python3 -m unittest discover -s tools/tests -p test_m8_008_http_contracts.py -v` | Exit 0; 6/6 passed |
| `python3 -m unittest tools.tests.test_p1_014_evidence_digest_types tools.tests.test_m8_008_http_contracts -v` | Exit 0; [46/46 passed](inventory-runner-tests.json) |
| `python3 -m unittest tools.tests.test_m7_025_linux_supply_chain tools.tests.test_m7_030_linux_release -v` | Exit 0; [21/21 passed](canonical-fixture-tests.json) |
| Missing configured cjdoc / missing configured AWS-LC source | Exit 1 with `TOOL_MISSING` / `PINNED_SOURCE_MISSING`; no native build entered |
| Real C consumer after removal of its required shared library | Consumer first ran with exit 0; actual readelf/ldd then caused `ELF_LIBRARY_MISSING`: [proof](elf-negative.json) |

The native command is `python3 tools/m8_008_http_contracts.py --root . --json`,
with the outer SDK launcher and these inputs:

```text
CJDOC_BIN=<workspace>/cjdoc/target/release/bin/main
LDD=/usr/bin/ldd
WIRESTACK_AWS_LC_SOURCE=<repo-root>/.local/tls-provider/source/aws-lc-5.5.0
```

## G. Remaining boundaries

- No non-Linux execution, cross-build ABI guarantee, registry installation,
  production signing, public release or new 24-hour soak is claimed.
- Functional one-second joins are not a P99/50 ms performance measurement.
- TCP gate injection verifies phase propagation, not a real blackhole connect.
- Handlers and custom streams must cooperate with cancellation or close;
  force-stop does not forcibly terminate arbitrary application code.
- Consumers must rebuild with the compatible SDK. Static AWS-LC does not remove
  Cangjie runtime, libc or transitive C++ runtime dependencies.
- No functional or native-closure blocker remains. Historical performance and
  release evidence is not requalified by this task.

## H. Suggested next READY tasks

The current status index lists no next READY task ID. No subsequent task is started.

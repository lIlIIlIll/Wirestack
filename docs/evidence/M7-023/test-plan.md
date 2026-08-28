# M7-023 Linux continuous fuzz gate test plan

- Task: `M7-023`
- Profile: native Linux x86_64 glibc only
- Build mode: isolated release snapshot with `-O2`
- Scope: the ten parser targets required by PRD section 21.4
- Excluded: other platforms, Linux musl, runtime/std source changes, and
  coverage-guided compiler instrumentation not supplied by the pinned SDK

This task turns the existing bounded deterministic mutation tests into one
release gate. Every campaign consumes a committed corpus, declares a stable
seed and minimum iteration count, saves a replayable failure artifact, and can
be rerun from that artifact. A Linux PASS does not imply global M7 completion.

## Paths and requirement traceability

| ID | Requirement | Proof | Pass rule |
|---|---|---|---|
| P001 | All ten PRD fuzz targets are represented | Versioned campaign manifest and corpus inventory | Exactly the ten names from PRD section 21.4 occur once; unknown, duplicate, or missing targets fail closed |
| P002 | Corpus and seed are versioned | Committed corpus files, SHA-256 values, deterministic seed, and source fingerprint | Every referenced file exists inside the repository, matches its digest, is non-empty, and is consumed by its target |
| P003 | Every target reaches a release threshold | Per-target stable marker and gate report | Each isolated `-O2` target run reports at least its manifest iteration threshold with exit code zero and no timeout |
| P004 | Crashes are retained | Failure fixture and gate failure-path tests | Nonzero exit, signal, timeout, missing marker, malformed marker, digest mismatch, or threshold miss writes a bounded crash artifact |
| P005 | A retained crash is replayable | `--replay-crash` command recorded in each artifact | Replay validates artifact schema and target identity, then reruns the same corpus, seed, build mode, filter, and threshold |
| P006 | Release decision fails closed | Aggregate JSON report and unit tests | PASS requires ten target PASS decisions and zero unresolved crash artifacts from the current run |
| P007 | Native Linux evidence is durable | Evidence README, raw report, environment metadata, and digests | Report identifies kernel, glibc, architecture, compiler, CJPM, source/corpus digests, commands, exit codes, durations, and final decision |

## Target path matrix

| ID | Path IDs | PRD target | Parser boundary | Corpus class | Assertions / expected terminals |
|---|---|---|---|---|---|
| S001 | P001-P003 | TLS record parser | TLS provider record ingestion | Valid and malformed record bytes, truncation, length and bit mutations | Assert bounded acceptance or typed TLS rejection |
| S002 | P001-P003 | TLS handshake parser | ClientHello handshake ingestion | Valid and malformed handshake bytes, truncation, length and bit mutations | Assert bounded handshake step or typed TLS rejection |
| S003 | P001-P003 | Hostname verifier | SAN/reference identity matching | DNS, wildcard, A-label and malformed hostname seeds | Assert deterministic match or typed identity/input rejection |
| S004 | P001-P003 | Certificate input adapter | DER certificate construction and provider adapter | DER seed with truncation, length and bit mutations | Assert accepted adapter input or typed certificate/provider rejection |
| S005 | P001-P003 | HTTP/1.1 request/response parser | Strict head parser and canonical serializer | Request/response head bytes, delimiter and single-byte mutations | Assert canonical reparse or bounded rejection |
| S006 | P001-P003 | Chunked decoder | Chunk size, extensions, data, trailer and EOF states | Assert complete bounded body or typed rejection |
| S007 | P001-P003 | HTTP/2 frame parser | Incremental nine-byte frame header and payload parser | SETTINGS/PING/RST/WINDOW/GOAWAY frames and mutations | Assert at most bounded frames or typed protocol rejection |
| S008 | P001-P003 | HPACK decoder | Integer, string, static/dynamic table and list limits | RFC-style header blocks and mutations | Assert bounded header list or typed HPACK rejection |
| S009 | P001-P003 | URL authority parser | Scheme, authority, host, port and request-target parser | IPv4, IPv6 and DNS URL seeds with delimiter mutations | Assert canonical identity or bounded rejection |
| S010 | P001-P003 | Proxy parser | no-proxy rule and proxy authorization validation | DNS/wildcard/IPv6 rules and invalid authorization bytes | Assert deterministic match or rejection before DNS/connect |

## Gate and failure scenario matrix

| ID | Preconditions | Stimulus | Assertions / expected result | Traces |
|---|---|---|---|---|
| T001 | Valid manifest and all ten corpus files | Run the default gate in an isolated native `-O2` snapshot | Assert ten campaigns execute once, meet thresholds, and aggregate to PASS | P001, P002, P003, P006, P007; S001-S010 |
| T002 | One manifest target is absent, duplicated, or renamed | Validate manifest | Assert the gate exits nonzero before compiling or running targets | P001, P006; S001-S010 |
| T003 | Corpus path escapes the repository, is missing, empty, or has the wrong digest | Validate corpus inventory | Assert the gate exits nonzero and identifies the affected target | P002, P006; S001-S010 |
| T004 | Target exits nonzero or by signal | Execute campaign through a stubbed process result | Assert the gate writes one bounded crash JSON containing target, seed, corpus digest, command and captured output | P004, P006; S001 |
| T005 | Target exceeds its timeout | Execute campaign through a stubbed timed-out result | Assert the process group is terminated and a replayable timeout artifact is saved | P004, P006; S002 |
| T006 | Target exits zero but omits, duplicates, or corrupts its marker | Classify campaign output | Assert the gate fails closed and saves a crash artifact | P003, P004, P006; S003 |
| T007 | Marker iteration count is below threshold or names another target/seed | Classify campaign output | Assert the gate fails closed and saves a crash artifact | P003, P004, P006; S004 |
| T008 | Valid retained failure artifact | Invoke the emitted `--replay-crash` command | Assert the gate validates immutable campaign coordinates and reruns only that target with the same release settings | P005; S005 |
| T009 | Corrupt, path-escaping, unknown-target, or stale-digest replay artifact | Invoke replay | Assert the gate exits nonzero before executing untrusted coordinates | P005, P006; S006 |
| T010 | A prior crash exists outside the current run directory | Run a clean campaign | Assert prior files cannot masquerade as current-run failures and the current decision uses only current target results | P004, P006, P007; S007 |
| T011 | Normal project test run has no M7-023 environment | Run affected Cangjie test classes normally | Assert committed fallback seeds run deterministically and existing regression semantics remain intact | P002, P003; S001-S010 |
| T012 | Current supported SDK and native provider are present | Inspect report metadata and optimized test binaries | Assert the target triple is Linux GNU, build is `-O2`, and no runtime/std source build or modification occurs | P003, P007; S001-S010 |

## Assertions and boundaries

- Each Cangjie target reports one stable `M7023_FUZZ` marker containing target,
  seed, executed iterations, and `decision=PASS` only after all assertions run.
- The Python gate validates exact target and seed equality, integer syntax,
  threshold, process exit, timeout, and marker cardinality independently.
- Corpus paths are resolved below a fixed repository directory. Replay never
  executes a command read from JSON; it reconstructs the command from the
  checked-in manifest.
- Captured stdout and stderr are capped. Crash filenames use gate-owned target
  names and timestamps, never input-derived paths.
- Every parser remains bounded by its production limits. Acceptance and typed
  rejection are both valid; signals, hangs, uncaught failures, inconsistent
  classifications, and unbounded output are failures.

## Coverage gaps and deferred work

- This gate proves only native Linux x86_64 glibc release behavior. Other
  operating systems and Linux musl remain outside M7-023.
- The pinned compiler does not expose a repository-supported coverage-guided
  fuzz driver, so the release threshold is deterministic iteration count, as
  allowed by the backlog. This does not claim compiler-guided coverage.
- A PASS proves the committed corpus and deterministic mutation space. New
  externally discovered crashes must be added to the corpus before closure.

## Evidence contract

The formal report is written under
`docs/evidence/M7-023/linux_glibc_x86_64/`. It retains the manifest digest,
per-corpus digest, source fingerprint, environment metadata, exact commands,
per-target process result, marker, duration, crash artifact paths, replay
commands, and aggregate PASS/FAIL decision. The task README links the report
and distinguishes native Linux qualification from global platform status.

# M7-023 Linux continuous fuzz gate test plan

- Task: `M7-023`
- Profile: native Linux x86_64 glibc only
- Build mode: isolated release snapshot with `-O2`
- Scope: the ten parser targets required by PRD section 21.4
- Excluded: other platforms, Linux musl, runtime/std source changes, and
  coverage-guided compiler instrumentation not supplied by the pinned SDK

## Semantics

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

| Scenario ID | Triggered path IDs | PRD target | Parser boundary | Corpus class | Assertions / expected terminals |
|---|---|---|---|---|---|
| S001 | P001,P002,P003 | TLS record parser | TLS provider record ingestion | Valid and malformed record bytes, truncation, length and bit mutations | Assert bounded acceptance or typed TLS rejection |
| S002 | P001,P002,P003 | TLS handshake parser | ClientHello handshake ingestion | Valid and malformed handshake bytes, truncation, length and bit mutations | Assert bounded handshake step or typed TLS rejection |
| S003 | P001,P002,P003 | Hostname verifier | SAN/reference identity matching | DNS, wildcard, A-label and malformed hostname seeds | Assert deterministic match or typed identity/input rejection |
| S004 | P001,P002,P003 | Certificate input adapter | DER certificate construction and provider adapter | DER seed with truncation, length and bit mutations | Assert accepted adapter input or typed certificate/provider rejection |
| S005 | P001,P002,P003 | HTTP/1.1 request/response parser | Strict head parser and canonical serializer | Request/response head bytes, delimiter and single-byte mutations | Assert canonical reparse or bounded rejection |
| S006 | P001,P002,P003 | Chunked decoder | Chunk size, extensions, data, trailer and EOF states | Assert complete bounded body or typed rejection |
| S007 | P001,P002,P003 | HTTP/2 frame parser | Incremental nine-byte frame header and payload parser | SETTINGS/PING/RST/WINDOW/GOAWAY frames and mutations | Assert at most bounded frames or typed protocol rejection |
| S008 | P001,P002,P003 | HPACK decoder | Integer, string, static/dynamic table and list limits | RFC-style header blocks and mutations | Assert bounded header list or typed HPACK rejection |
| S009 | P001,P002,P003 | URL authority parser | Scheme, authority, host, port and request-target parser | IPv4, IPv6 and DNS URL seeds with delimiter mutations | Assert canonical identity or bounded rejection |
| S010 | P001,P002,P003 | Proxy parser | no-proxy rule and proxy authorization validation | DNS/wildcard/IPv6 rules and invalid authorization bytes | Assert deterministic match or rejection before DNS/connect |
| S011 | P004,P006 | Campaign failure terminal | Target process and marker classifier | Exit, signal, timeout, missing marker and threshold miss | Retain one bounded replayable artifact and fail the aggregate decision |
| S012 | P005,P006 | Crash replay | Checked-in manifest coordinates | Valid, corrupt, escaping, unknown-target and stale-digest artifacts | Reconstruct only trusted commands; reject invalid coordinates before execution |
| S013 | P006,P007 | Native release decision | Aggregate report and environment | Ten passing campaigns, current-run crash inventory and Linux metadata | PASS only for all targets with zero current crash and complete native evidence |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002,S003,S004,S005,S006,S007,S008,S009,S010,S013 | P001,P002,P003,P006,P007 | Valid manifest and all ten corpus files in an isolated native `-O2` snapshot | Ten campaigns execute once, meet thresholds and aggregate to PASS | Target inventory, corpus digests, markers, thresholds, zero crash and environment metadata | integration,platform |
| T002 | S001,S002,S003,S004,S005,S006,S007,S008,S009,S010,S013 | P001,P006 | One manifest target absent, duplicated or renamed | Gate exits nonzero before build or target execution | Exact ten-target inventory and fail-closed decision | unit,error |
| T003 | S001,S002,S003,S004,S005,S006,S007,S008,S009,S010,S013 | P002,P006 | Escaping, missing, empty or digest-mismatched corpus | Gate exits nonzero and identifies the affected target | Resolved path, non-empty bytes and SHA-256 | unit,security |
| T004 | S001,S011 | P004,P006 | Target exits nonzero or by signal | One bounded replayable crash artifact is retained | Target, seed, corpus digest, process terminal and bounded output | unit,error |
| T005 | S002,S011 | P004,P006 | Target exceeds its timeout | Process group terminates and a timeout artifact is retained | Timeout terminal, cleanup and replay coordinates | unit,lifecycle |
| T006 | S003,S011 | P003,P004,P006 | Zero exit with missing, duplicate or malformed marker | Gate fails closed and retains a crash artifact | Marker cardinality and strict field parser | unit,error |
| T007 | S004,S011 | P003,P004,P006 | Marker below threshold or naming another target or seed | Gate fails closed and retains a crash artifact | Target, seed and minimum iteration equality | unit,boundary |
| T008 | S005,S012 | P005 | Valid retained failure artifact | Only its checked-in campaign is replayed with identical release settings | Immutable coordinates and reconstructed command | integration,regression |
| T009 | S006,S012 | P005,P006 | Corrupt, path-escaping, unknown-target or stale-digest artifact | Gate exits nonzero before executing artifact-supplied coordinates | Schema, target, path and digest rejection | unit,security |
| T010 | S007,S011,S013 | P004,P006,P007 | Prior crash outside the current run directory | Clean current campaigns may PASS without treating old files as current failures | Run-scoped crash inventory and report provenance | unit,regression |
| T011 | S001,S002,S003,S004,S005,S006,S007,S008,S009,S010 | P002,P003 | Normal test run without M7-023 environment variables | Committed fallback seeds execute deterministically | Existing package tests retain their normal semantics | integration,regression |
| T012 | S001,S002,S003,S004,S005,S006,S007,S008,S009,S010,S013 | P003,P007 | Current supported SDK and native provider | Report records Linux GNU, `-O2` and toolchain metadata | No runtime, std, stdx or SDK source build or modification | platform,boundary |

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

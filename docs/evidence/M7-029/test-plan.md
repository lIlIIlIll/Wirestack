# M7-029 test plan

## Semantics

M7-029 accepts an independent Linux security review only when the reviewer
binds the report to the exact M7-028 package, records scope and methods, and
gives every finding a severity, reproduction, disposition, and evidence. The
repository cannot turn a missing review, an independence assertion written by
the implementation agent, or an unresolved High or Critical finding into
PASS.

Wirestack does not promise pre-1.0 source, API, ABI, or semantic compatibility.
The review covers current security behavior and release safety, not compatibility
with M7-026.

## Control-flow path matrix

| Path ID | Conditions and values | Check | Reachability | Required result |
|---|---|---|---|---|
| P001 | Review target matches the M7-028 package digest | Target binding | Reachable | PASS |
| P002 | Review target digest is absent or stale | Target binding | Reachable error | FAIL |
| P003 | External or process-isolated reviewer records identity, review mode, independence statement, conflicts, ordered UTC dates, unique scope and unique methods | Strict schema | Reachable | PASS |
| P004 | Reviewer metadata is missing, malformed or internally inconsistent, or required scope is missing | Strict schema | Reachable error | FAIL |
| P005 | Finding has severity, location, reproduction, evidence and disposition | Finding validation | Reachable | PASS |
| P006 | Finding uses unknown severity/status or duplicate ID | Finding validation | Reachable error | FAIL |
| P007 | High/Critical finding is unresolved | Release-blocker policy | Reachable error | FAIL |
| P008 | Resolved finding lacks fix evidence or regression command | Closure validation | Reachable error | FAIL |
| P009 | Regression command is skipped, timed out, or nonzero | Result validation | Reachable error | FAIL |
| P010 | Review report contains sensitive values | Content scan | Reachable error | FAIL |
| P011 | No independent report exists | Missing-review handling | Reachable | BLOCKED, never PASS |
| P012 | Compatibility comparison is claimed as a required method | Policy validation | Reachable error | FAIL |
| P013 | Report output succeeds or replacement fails | Atomic report writer | Reachable | Complete replacement or preserved prior file |
| P014 | Canonical AWS-LC provider manifest is a repository-visible pinned input | Clean-build input | Reachable | PASS |
| P015 | Server DATA event transfers its reserved flow permit to the writer | HTTP/2 flow ownership | Reachable | Credit changes only when the writer claims the queued frame |
| P016 | Cancellation wrapper decorates an HTTP/2 body | HTTP body completion | Reachable | Delegate completion policy is preserved |
| P017 | HTTPS CONNECT uses dynamic authorization without a stable credential identity | Proxy pool partition | Reachable | Authenticated tunnel is discarded after one lease and cannot serve rotated credentials |
| P018 | std.net write times out after entering the physical write | Retry classification | Reachable error | Unknown commit state is Never retryable |
| P019 | Connection starts before peer SETTINGS and local limits differ from RFC defaults | HTTP/2 settings state | Reachable | Peer defaults use RFC values while every finite local receive limit is advertised |
| P020 | Server sends ENABLE_PUSH or client receives it from a server | HTTP/2 role validation | Reachable error | Local send is rejected and peer frame fails with PROTOCOL_ERROR |
| P021 | Release qualification source or native/build input changes | Evidence freshness | Reachable | Qualification validation detects every bound native manifest, C/H source and build-control drift |
| P022 | Linux CA bundle or hashed certificate content changes without a size change | TLS session partition | Reachable | Trust source identity changes because it binds bounded SHA-256 content |
| P023 | One active std.net accept is cancelled | Listener lifecycle | Reachable | Only that wait is cancelled; the listener remains open for the next accept |
| P024 | Resolver close races a blocking libc/NSS lookup | Resolver lifecycle | Reachable | Close stops admission and returns within 50 ms; quarantined native state is reclaimed only after workers and callers release it |
| P025 | A pull request changes Cangjie, native, build or evidence inputs | Clean CI coverage | Reachable | One canonical clean-checkout job runs repository readiness, full check, installed consumer, evidence freshness and mutation checks without permissive failure paths |
| P026 | Native resolver returns IPv4, IPv6 or an unknown family enum | Resolver FFI validation | Reachable/error | Only explicit IPv4/IPv6 values publish addresses; every other value fails closed with SystemFailure |
| P027 | Native resolver job remains pending | Resolver polling | Reachable | Poll delay backs off from 1 ms to a 16 ms cap while the canonical deadline still bounds each sleep |
| P028 | Project license and bundled TLS provider notices enter the release payload | License inventory | Reachable/error | Apache-2.0 project identity and exact AWS-LC license/notice digests are packaged and SBOM-bound, or validation fails closed |
| P029 | GitHub-hosted clean build installs Cangjie | CI toolchain bootstrap | Reachable | The workflow uses `ubuntu-latest`, immutable action revisions and one exact Cangjie version |
| P030 | CJPM enters any build lifecycle phase in a clean checkout | Native dependency build | Reachable | The provider-neutral hook builds both the pinned TLS provider and Linux resolver bridge before compilation |
| P031 | Reviewer uses `ProcessIsolatedAgent` mode | Independence policy | Reachable/error | The agent inherits no implementation context, has no implementation role, reviews a clean detached snapshot and discloses its orchestration conflict |
| P032 | libc/NSS calls remain blocked after several public resolver pools close | Process-wide resolver capacity | Reachable/error | At most eight live pools and 64 workers remain quarantined; another pool fails closed until a reaper releases capacity |

## Input and state domains

| Domain | Partitions | Required behavior |
|---|---|---|
| Review target | exact package digest; stale digest; missing digest | Only the exact current M7-028 package is accepted. |
| Reviewer | external; process-isolated agent; implementation agent; conflicts disclosed or omitted; malformed dates | External and process-isolated modes may attest independence; the implementation agent and undisclosed process relationships fail closed. |
| Severity | Critical; High; Medium; Low; Informational; unknown | Only declared severities are accepted. |
| Disposition | Open; Fixed; NotApplicable; RiskAccepted | Open High/Critical blocks; fixed findings need regression evidence. |
| Command result | PASS; FAIL; SKIPPED; timeout; missing | Only executed exit-zero PASS can close a fix. |
| Sensitive data | ordinary findings; private key; credential value; cookie; request body | Sensitive values fail without echoing the value. |
| Compatibility | not assessed; historical context; required gate | Compatibility cannot become a pre-1.0 gate. |
| License | Apache-2.0; missing file; wrong expression; notice drift | Only Apache-2.0 with the complete digest-bound notice inventory passes. |

## State and side effects

- Preparation and validation do not modify runtime, std, stdx, or the SDK.
- The reviewer works from the digest-bound M7-028 package and records results in
  one machine-readable report plus a readable summary.
- Validation emits bounded diagnostics and writes its report atomically.
- The one-hour SSE profile and 86,400-second release soak remain outside this
  task.

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Complete independent report with no findings | Current M7-028 package | P001,P003 | PASS | Target, reviewer, scope and methods are complete | normal | P0 |
| S002 | Stale or missing target digest | Otherwise valid report | P002 | FAIL | Stable target mismatch code | evidence | P0 |
| S003 | Missing reviewer field or scope domain, malformed/reversed date, duplicate conflict/scope/method | Otherwise valid report | P004 | FAIL | Stable schema or reviewer-date error reported | negative | P0 |
| S004 | Duplicate or malformed finding | Otherwise valid report | P005,P006 | FAIL | Stable finding validation code | negative | P0 |
| S005 | Open High/Critical finding | Reproducible finding | P007 | FAIL | Release blocker remains visible | security | P0 |
| S006 | Fixed finding without successful regression | Finding marked Fixed | P008,P009 | FAIL | No paper closure | security,evidence | P0 |
| S007 | Fixed finding with executed regression | Fix and result exist | P005,P008,P009 | PASS | Location, fix and command evidence are complete | regression | P0 |
| S008 | Private key or credential value in report | Otherwise valid report | P010 | FAIL | Category reported; value not printed | security | P0 |
| S009 | Review report absent | Review request prepared | P011 | BLOCKED | Exit state cannot be PASS | workflow | P0 |
| S010 | Compatibility required as review method | Otherwise valid report | P012 | FAIL | Pre-1.0 non-compatibility policy enforced | policy | P0 |
| S011 | Atomic replacement failure | Prior validation report exists | P013 | Prior file preserved | No partial final JSON remains | fault-injection | P1 |
| S012 | Provider manifest exists but is ignored, absent or has a different pin | Clean checkout input | P014 | FAIL | Fixed provider input remains repository-visible and exact | supply-chain | P0 |
| S013 | Server DATA frame is reserved but not yet claimed by the writer | Open stream and queued frame | P015 | PASS | Send window is unchanged until the writer claims the permit | concurrency,regression | P0 |
| S014 | Wrapped body reaches declared length before protocol EOF | Completion-at-length disabled | P016 | PASS | Wrapper remains incomplete until delegate EOF | protocol,regression | P0 |
| S015 | Two CONNECT requests use rotated dynamic credentials | First authenticated response completed | P017 | PASS | A second proxy connection and TLS handshake are created | security,regression | P0 |
| S016 | Physical write timeout has no zero-byte commit proof | Write entered std.net | P018 | FAIL closed | Structured timeout retains Write/TcpWrite and uses Never retryability | safety,regression | P0 |
| S017 | Custom local header/window/frame/stream limits before peer SETTINGS | Fresh client/server state | P019 | PASS | RFC peer defaults and explicit local SETTINGS are distinct | protocol,regression | P0 |
| S018 | ENABLE_PUSH originates from a server | Client or server settings state | P020 | FAIL | Role-invalid setting never reaches effective state | protocol,negative | P0 |
| S019 | Provider/resolver manifest, native source, build script, lockfile or build hook drifts | Prior release qualification exists | P021 | STALE | Old qualification cannot remain PASS | evidence,regression | P0 |
| S020 | Same-size replacement of selected bundle or hashed CA file | Prior trust source identity exists | P022 | PASS | New identity differs and old TLS session partition cannot match | security,regression | P0 |
| S021 | Cancel active accept, then connect and accept again | Bound listener | P023 | PASS | First result is Cancelled and second accept succeeds | lifecycle,regression | P0 |
| S022 | Cancel a delayed native lookup and close its resolver before `getaddrinfo` returns | One native worker remains inside the injected delay | P024 | PASS | Public close returns within 50 ms and the detached reaper cannot free worker-reachable state | lifecycle,availability,regression | P0 |
| S023 | Any pull request reaches the canonical clean Cangjie workflow | Clean GitHub-hosted Linux checkout | P025 | PASS only after every critical gate exits zero | No cache hides missing inputs; no step uses continue-on-error or `|| true` | CI,supply-chain,regression | P0 |
| S024 | Native result family is 4, 6 or an unknown value | Completed native job | P026 | IPv4/IPv6 or FAIL closed | Unknown ABI value never becomes an IPv6 address | FFI,negative,regression | P1 |
| S025 | Delayed native lookup remains pending through repeated polls | Open operation context | P027 | PASS | Wait sequence is 1,2,4,8,16 ms and stays capped without adding a timeout owner | efficiency,regression | P1 |
| S026 | Build release metadata with the selected project license and pinned AWS-LC notices | Clean release payload | P028 | PASS | Archive, release manifest, fingerprint and SPDX agree on every license digest | license,supply-chain,regression | P0 |
| S027 | Hosted workflow action or Cangjie version drifts | Pull request workflow | P029 | FAIL static contract | No rolling toolchain or mutable action tag can enter the release-critical job | CI,supply-chain,negative | P0 |
| S028 | Clean `cjpm check`, build, test, bench, run, install or publish starts without native artifacts | Empty native target | P030 | PASS | One fail-closed hook builds TLS and resolver inputs before CJPM links either archive | build,regression | P0 |
| S029 | No-history reviewer agent examines a clean detached candidate without implementation participation | Same owner and orchestrator disclosed | P003,P031 | PASS | `ProcessIsolatedAgent` plus nonempty conflicts is accepted; missing disclosure or implementation participation is rejected | review,policy | P0 |
| S030 | Eight resolver pools each quarantine a worker inside an indefinitely blocked lookup | All public pool handles have been closed | P024,P032 | FAIL closed, then recover | The ninth pool returns OVERLOADED without starting threads; releasing blocked calls lets reapers return capacity | native,lifecycle,availability,regression | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P003 | Synthetic independent no-finding report | PASS | Exact target and complete reviewer record | unit |
| T002 | S002 | P002 | Missing and stale digest | FAIL | Stable mismatch code | fault-injection |
| T003 | S003 | P004 | Missing identity/scope, malformed dates and duplicate set-valued fields | FAIL | Strict schema, ordered UTC dates and coverage | fault-injection |
| T004 | S004 | P005,P006 | Duplicate ID and unknown severity | FAIL | Finding rejected | fault-injection |
| T005 | S005 | P007 | Open High and Critical | FAIL | Release blocked | fault-injection,security |
| T006 | S006,S007 | P008,P009 | Fixed finding with missing, skipped and passing regressions | FAIL/PASS | Only executed PASS closes finding | fault-injection,regression |
| T007 | S008 | P010 | Synthetic secret patterns | FAIL | Value omitted from diagnostic | fault-injection,security |
| T008 | S009 | P011 | Missing independent report | BLOCKED | Nonzero exit; no PASS report | workflow |
| T009 | S010 | P012 | Compatibility gate injection | FAIL | Policy rejected | fault-injection,policy |
| T010 | S011 | P013 | Injected replace failure | FAIL | Previous bytes preserved | fault-injection,persistence |
| T011 | S012 | P014 | Current provider manifest and ignore rules | PASS | Schema, provider/version/commit and repository visibility | regression,supply-chain |
| T012 | S013 | P015 | Server DATA event with reserved permit | PASS | Queue transfer retains reserved credit until writer claim | regression,concurrency |
| T013 | S014 | P016 | Cancellation wrapper around length-delimited protocol body | PASS | Exact length does not become a synthetic EOF | regression,protocol |
| T014 | S015 | P017 | Authenticated CONNECT requests with different hook values | PASS | No authenticated tunnel reuse; both CONNECT exchanges execute | regression,security |
| T015 | S016 | P018 | Scripted write-timeout mapper | PASS | TimedOut, Write, TcpWrite and Never are retained | regression,safety |
| T016 | S017 | P019 | Client/server initial SETTINGS with custom limits | PASS | Defaults, caps and advertised entries match their separate roles | regression,protocol |
| T017 | S018 | P020 | Server local send and client peer receive | FAIL closed | Illegal local send and peer PROTOCOL_ERROR | negative,protocol |
| T018 | S019 | P021 | M7-021 qualification input inventory | PASS | All required native and build controls are digest-bound | regression,evidence |
| T019 | S020 | P022 | Temporary bundle and hashed directory with same-size replacement | PASS | Both source identities change | regression,security |
| T020 | S021 | P023 | Cancellation source plus loopback reconnect | PASS | Listener stays open and accepts the next connection | regression,lifecycle |
| T021 | S022 | P024 | LD_PRELOAD delayed `getaddrinfo`, cancellation and immediate close | PASS | Cancel and close are each bounded; native worker completion remains memory-safe | regression,lifecycle,availability |
| T022 | S023 | P025 | Static workflow contract plus eventual GitHub-hosted execution | PASS/BLOCKED | Required commands and fail-closed syntax are present; remote execution remains blocked until the workflow is pushed and a ruleset requires it | CI,supply-chain |
| T023 | S024,S025 | P026,P027 | Native family decoder and wait-backoff unit sequence | PASS | Explicit enum matching and 16 ms backoff cap | unit,FFI,efficiency |
| T024 | S026 | P028 | Release metadata and synthetic artifact fixture | PASS/FAIL | Apache-2.0 and all notice hashes are required; Wirestack artifact and resolver SPDX packages declare Apache-2.0 | unit,license,supply-chain |
| T025 | S027 | P029 | Static hosted-workflow contract | PASS | `ubuntu-latest`, checkout SHA, setup action SHA and exact Cangjie version are present | unit,CI,supply-chain |
| T026 | S028 | P030 | Static build-hook contract plus clean `cjpm check` | PASS | Every CJPM lifecycle phase calls the combined native dependency builder and clean check links both archives | regression,build |
| T027 | S029 | P003,P031 | Synthetic process-isolated reviewer with and without conflict disclosure | PASS/FAIL | Declared isolated mode with disclosure passes; missing disclosure and unknown modes fail closed | unit,policy |
| T028 | S030 | P024,P032 | Wrapped native `getaddrinfo` blocks eight pools until the probe releases it | PASS | Fixed global pool limit rejects the ninth pool, keeps its handle zero and later admits a pool after reaping | fault-injection,native,lifecycle |

## Coverage and gap review

This plan validates review provenance and finding closure. It does not make the
implementation agent independent. An external reviewer or a no-history,
process-isolated reviewer agent may submit the report. The latter must review a
clean detached snapshot, have no implementation role and disclose the common
owner and orchestrator relationship. M7-029 can pass only after the accepted
reviewer submits the report and every High or Critical finding is fixed with
regression evidence.

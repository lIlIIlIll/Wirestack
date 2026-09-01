# P1-014 typed evidence digest boundary test plan

## Scope and acceptance boundary

P1-014 separates normalized text evidence digests from raw artifact byte
digests. Repository JSON, Markdown and log evidence is decoded as strict UTF-8,
normalized to LF and hashed in the text domain. Binary artifacts are hashed only
through the byte domain. The two digest types and their serialized domains are
not interchangeable.

This task does not refresh product release evidence, build an SDK or run any
long-duration qualification. Existing schema-v1 evidence is rejected rather
than rewritten or silently promoted.

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | Valid UTF-8 text uses LF, CRLF or bare CR line endings | All variants produce the same `text-utf8-lf-v1` digest |
| P002 | Text evidence contains invalid UTF-8 | Digest creation fails closed with a stable text-encoding error |
| P003 | A binary artifact is hashed explicitly | The result has the `artifact-bytes-v1` domain and preserves exact bytes |
| P004 | A text digest is parsed as a byte digest, or conversely | Parsing fails closed with a stable digest-domain error |
| P005 | Evidence uses schema v1, a bare digest string or an unknown domain | Validation rejects the document without migration or fallback |
| P006 | A sealed text source or report changes semantically | Verification returns stale/fail and does not retain the old PASS |
| P007 | A sealed text source changes only line-ending encoding | Verification remains current because its normalized text is unchanged |
| P008 | Python, shell, PowerShell, workflow or composite-action code hashes evidence through an untyped/raw-byte helper, folded command, manifest-declared partial command, adjacent action helper, unresolved shell operand, direct SHA-256 import, assigned digest-field comparison, text-suffix byte digest or UTF-8 fallback | Architecture guard reports a stable violation |
| P009 | The digest-callsite inventory finds a new unclassified Python or non-Python SHA-256 implementation, unreadable helper, PowerShell/.NET SHA-256 API, incomplete logical operand classification or direct/assigned digest-bearing field comparison | Inventory and architecture validation fail closed |
| P010 | Linux fault injection exercises LF, CRLF, bare CR, invalid UTF-8 and a tracked checkout fixture | The bounded Linux report records exact OS, architecture and libc identity and PASS |
| P011 | GitHub Windows fault injection exercises the same inputs | The bounded Windows report records actual Windows platform and PASS |
| P012 | A report is written atomically and replacement fails before commit | The previous report remains intact and no temporary file is retained |
| P013 | A fast, full or canonical repository gate runs | No long profile is selected or recorded as PASS |

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Path IDs | Expected behavior | Required assertions | Type |
|---|---|---|---|---|---|
| S001 | Equivalent UTF-8 text encoded with LF, CRLF and bare CR | P001,P007 | One canonical text digest | Domain is explicit; byte digests remain distinct | unit,cross-platform |
| S002 | Invalid UTF-8 and a simulated fallback implementation | P002,P008 | Strict rejection | No raw-byte recovery path executes | fault-injection,safety |
| S003 | Text and binary digest objects plus serialized values | P003,P004,P005 | Only matching explicit domains parse | Types compare unequal and old/untyped input is invalid | unit,schema |
| S004 | Sealed evidence followed by semantic and line-ending-only source changes | P006,P007 | Semantic drift is stale; encoding-only drift is current | Old PASS is neither rewritten nor silently reused | regression,freshness |
| S005 | Repository digest implementation and Python, shell, PowerShell, workflow and composite-action callsite inventory | P008,P009 | Every implementation and complete command operand is classified; evidence tooling is text-only | Direct imports, assigned digest fields, manifest-declared folded commands, text-suffix byte digests and raw PowerShell APIs fail the guard | architecture,inventory |
| S006 | Native Linux and hosted Windows CRLF probes over a tracked checkout fixture | P010,P011 | Both platforms prove identical canonical behavior | Reports derive complete platform identity from the runner and reject `-text` dependence | platform,integration |
| S007 | Atomic JSON report replacement and repository gates | P012,P013 | Failure preserves prior file; short gates remain bounded | No partial report and no long gate | reliability,integration |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P007 | LF, CRLF and bare-CR fixtures | PASS | Equal text digests, distinct byte digests, explicit domains | unit |
| T002 | S002 | P002 | Invalid UTF-8 bytes | PASS by rejecting input | Stable `TEXT_UTF8` failure and no fallback | unit,fault-injection |
| T003 | S003 | P003,P004 | Typed digest objects and opposite-domain parser | PASS by rejecting mismatch | Non-interchangeable types and `DIGEST_DOMAIN` failure | unit |
| T004 | S003 | P005 | Schema v1, bare string, unknown domain and malformed digest | PASS by rejecting every input | Stable schema/type/domain/format failures | unit,fault-injection |
| T005 | S004 | P006,P007 | Sealed report and source mutations | PASS | Semantic drift is stale; CRLF-only drift remains current | unit,regression |
| T006 | S005 | P008 | Injected raw-byte `.log` helper, direct and assigned digest-field comparison, invalid UTF-8 helper and UnicodeDecodeError fallback | PASS by detecting violations | Stable architecture rule IDs, assignment provenance and fail-closed unreadable input | architecture,fault-injection |
| T007 | S005 | P009 | Injected direct SHA-256 import plus unmarked, variable-operand, manifest-declared folded-YAML, PowerShell/.NET SHA-256 and adjacent composite-action helper commands | PASS by detecting violations | Inventory cannot omit Python, non-Python, PowerShell or action helper implementations and always classifies the complete executed operand | architecture,inventory |
| T008 | S006 | P010 | Native Linux CRLF probe and tracked fixture | PASS | Exact Linux architecture/libc identity, checkout bytes and no `-text` dependency | integration,platform |
| T009 | S006 | P011 | GitHub Windows CRLF workflow | PASS on hosted runner | Actual Windows identity and uploaded report | integration,platform |
| T010 | S007 | P012 | Failure before atomic replace | PASS | Original bytes preserved and temporary file removed | unit,fault-injection |
| T011 | S004,S007 | P005,P006,P013 | P1-014 task gate, fast gate and `scripts/check` | PASS | Schema v2 enforced, short tests pass, no long command starts | integration |

## Evidence boundary

Linux results may be generated locally. Windows evidence is valid only when the
GitHub Windows runner produces it from the exact candidate revision. A locally
fabricated or skipped Windows result cannot satisfy T009. Until that report is
available, P1-014 remains incomplete even if every Linux gate passes.

## Unrun gates

The one-hour SSE profile, 86,400-second soak, release rebuild, performance,
fuzz, security-review, signing and non-Windows hosted platform gates are not
run by P1-014.

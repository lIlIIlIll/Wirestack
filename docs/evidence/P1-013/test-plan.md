# P1-013 development and release gate separation test plan

## Scope and acceptance boundary

This task keeps ordinary repository regression checks useful while release
evidence is intentionally stale after product development. Structural and
fault-injection unit tests may validate frozen evidence without comparing it to
the current source tree. Every production release CLI keeps current-source
validation enabled by default and must reject the same frozen evidence.

The task does not rebuild a release artifact or refresh soak, fuzz, performance,
security-review, SBOM, signature or candidate-release evidence.

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | A unit test validates the schema and semantics of frozen M7-019 or M7-020 evidence | Structural validation runs without an unrelated source-digest failure |
| P002 | The strict M7-019 or M7-020 CLI validates evidence against changed source | Validation fails closed with source drift |
| P003 | A unit test validates the contents of the frozen M7-021 qualification | Artifact, installation and dependency semantics are checked without claiming currentness |
| P004 | The strict M7-021 validator receives an outdated source fingerprint | Validation fails closed before release promotion |
| P005 | M7-031 unit tests exercise candidate logic from one internally consistent frozen evidence set | Candidate logic and fault injection execute deterministically |
| P006 | The production M7-031 CLI evaluates frozen inputs after source drift | Candidate generation fails closed |
| P007 | Darwin native dependency planning is requested | The implemented Apple resolver is selected and no Linux TLS build is inferred |
| P008 | An unknown operating system is requested | Native dependency selection returns stable unsupported-platform failure |
| P009 | `scripts/check` runs in a development workspace with stale point-in-time release evidence | Current code, structural contracts and fault injection pass without refreshing release evidence |
| P010 | A long or release qualification is considered during P1-013 | It is not run and cannot be recorded as PASS |

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Path IDs | Expected behavior | Required assertions | Type |
|---|---|---|---|---|---|
| S001 | Frozen M7-019 and M7-020 documents plus changed backlog | P001,P002 | Structural mode reaches semantic checks; strict mode rejects source drift | Default remains strict, opt-out is explicit and test-only | regression,safety |
| S002 | Frozen M7-021 qualification plus changed production source fingerprint | P003,P004 | Structural mode checks artifact contract; strict mode rejects stale source | No digest is rewritten and no old PASS becomes current | regression,release |
| S003 | Frozen cross-report M7-031 document set plus current changed tree | P005,P006 | Unit logic runs from the frozen set; production generation rejects drift | Artifact identity and security fault injection still execute | regression,security |
| S004 | Linux, Windows, Darwin and unknown platform selection | P007,P008 | Implemented adapters are selected exactly; unknown platform fails | Darwin maps only to resolver, with no fallback | platform,boundary |
| S005 | Full repository development check | P009,P010 | All short code and test gates pass; no long release gate starts | Zero failed/error tests and no evidence refresh | integration,safety |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P002 | Canonical and mutated M7-019 audit | Structural PASS; strict STALE failure | Semantic mutations reach their intended stable errors | unit,fault-injection |
| T002 | S001 | P001,P002 | Canonical and mutated M7-020 audit | Structural PASS; strict STALE failure | Inventory and guard mutations remain detectable | unit,fault-injection |
| T003 | S002 | P003,P004 | Committed M7-021 qualification | Structural PASS; strict source drift rejection | Artifact and dependency checks remain active in both modes | unit,release |
| T004 | S003 | P005,P006 | Committed M7-019 through M7-032 evidence set | Frozen candidate logic PASS; strict generation FAIL | Cross-report identity and security blockers remain fail-closed | unit,security |
| T005 | S004 | P007,P008 | Native dependency plan inputs | Exact adapter plan or stable failure | Darwin never triggers Linux TLS and unknown never falls back | unit,platform |
| T006 | S001,S002,S003 | P001,P002,P003,P004,P005,P006 | Public validator signatures and CLI defaults | Strict by default | Only explicit unit-test call sites disable currentness | architecture,safety |
| T007 | S005 | P009,P010 | `scripts/check` | PASS | No long gate or release evidence rewrite occurs | integration |

## Evidence boundary

P1-013 may prove that development regression checks pass and that release CLIs
reject stale evidence. It cannot claim that the current source has a qualified
artifact or a current Linux release candidate. Those claims require a later
release-candidate requalification, including a new final 86,400-second soak.

## Unrun gates

The one-hour SSE profile, 86,400-second soak, release artifact rebuild, fuzz,
performance, security review, SBOM generation and signing rehearsal are not run.

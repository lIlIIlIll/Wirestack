# P1-013 maintained documentation rewrite test plan

## Scope and acceptance boundary

This plan covers the maintained reader-facing documentation set: the repository
README, documentation index, installation and usage guides, API orientation,
architecture and maintainer guides, security and performance navigation,
contribution guidance, and release/security policy entry points. It also checks
the task's backlog and status records.

Accepted ADR decisions, the PRD's product requirements, machine-readable API
baselines, historical evidence, raw benchmark data, and generated gate reports
are authoritative records. P1-013 may improve their navigation but must not
rewrite their meaning or recast old evidence as current execution.

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | A reader starts at the repository root | README states current Linux scope and links to the correct next document |
| P002 | A reader starts at `docs/` | The documentation index routes by task without duplicating source-of-truth content |
| P003 | A user follows installation and first-use instructions | Commands and public names match the current manifest, source and checked-in examples |
| P004 | A maintainer follows contribution or validation instructions | The guide uses repository scripts, task contracts and explicit long-gate entry points |
| P005 | A claim concerns platform, protocol, performance or release status | The claim links evidence and distinguishes Linux completion from global completion |
| P006 | A maintained Markdown link or local anchor is checked | The target exists and the anchor resolves |
| P007 | A Markdown code fence is opened | A matching closing fence exists |
| P008 | Historical evidence, accepted decisions or generated data are encountered | Their contents remain outside the rewrite set |
| P009 | A long-duration gate is described | It is opt-in and is not presented as part of fast/full validation |
| P010 | Documentation validation writes a report | The JSON report is bounded and atomically replaced |

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|
| S001 | Root README and documentation index | P001,P002,P005 | Reader can identify product, current Linux support, limitations and next action | Assert required sections, canonical links and no stale current-task text | normal | P0 |
| S002 | Installation, quickstart and API pages | P003,P005 | Instructions match `cjpm.toml`, public packages and runnable M7-027 examples | Assert package/version/toolchain and public-symbol tokens | normal,regression | P0 |
| S003 | Contributor, architecture and validation pages | P004,P008,P009 | Maintainers see source hierarchy, one-task discipline and validation layers | Assert no SDK build instruction and explicit long-gate isolation | safety | P0 |
| S004 | Every maintained local Markdown link and anchor | P006 | All links resolve within the repository | Assert no missing target, path escape or unresolved explicit anchor | boundary | P0 |
| S005 | Every maintained Markdown file | P007 | Fences are balanced | Assert even fence transitions and bounded diagnostics | boundary | P0 |
| S006 | Performance/security/status statements | P005,P008 | Claims are scoped to retained evidence and current status | Assert evidence links and Linux/global distinction | regression | P0 |
| S007 | Documentation report target exists and replacement fails | P010 | Existing report remains intact | Assert byte preservation, then valid replacement | fault-injection | P0 |
| S008 | Link escapes repository, missing file, stale token or long gate in default path | P004,P006,P009 | Validator fails closed with a stable issue code | Assert nonzero result and bounded machine report | security,regression | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002 | P001,P002,P003,P005 | Maintained entry and user guides | PASS | Required sections, facts and navigation resolve | unit,integration |
| T002 | S003,S008 | P004,P008,P009 | Maintainer and validation guides plus injected long-gate misuse | PASS then FAIL | Default gates stay bounded; long gates are explicit | unit,safety |
| T003 | S004,S008 | P006 | Repository docs plus missing/escaping link fixtures | PASS then FAIL | Stable missing-target/path-escape issue codes | unit,boundary |
| T004 | S005 | P007 | Repository docs plus unclosed-fence fixture | PASS then FAIL | Stable unclosed-fence issue code | unit,boundary |
| T005 | S006 | P005,P008 | Status, performance and security landing pages | PASS | Linux/global and historical/current evidence remain distinct | integration,regression |
| T006 | S007 | P010 | Existing report with injected replace failure | PASS | No partial report and later valid JSON | unit,fault-injection |
| T007 | S001..S006 | P001..P009 | `scripts/check-docs --json` | PASS | One bounded schema-v1 report and exit zero | integration |
| T008 | S001..S008 | P001..P010 | `scripts/check-task P1-013 --json` | PASS | Task contract and all non-long acceptance commands pass | acceptance |

## Evidence boundary

P1-013 validates documentation on native Linux x86_64 glibc. It does not rerun
the one-hour SSE profile, the 24-hour soak, fuzz campaigns, performance
qualification, independent security review, signing, or non-Linux platform
gates. It does not modify or build the Cangjie SDK, runtime, std or stdx.

## Coverage gaps

The validator checks repository-local structure and selected source-bound facts.
It does not prove every prose sentence semantically, render every Markdown
viewer, test external websites, or replace an independent editorial review.

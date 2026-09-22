# P1-015 current development baseline test plan

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | Historical review package has stale member digests | Strict release validator rejects it; development package tests use isolated fresh inputs |
| P002 | Current production inputs differ from the selected commit | Baseline capture or verify fails |
| P003 | SDK installation or archive differs from the qualified pin | Baseline fails before claiming current execution |
| P004 | Current check, installed consumer, fuzz and resource preflight succeed | Development PASS only |
| P005 | A required command fails, times out or is missing | No development PASS |
| P006 | Short preflight or developer report claims formal qualification | Rejected |
| P007 | Execution input, artifact or retained log changes after capture | Verify rejects drift |
| P008 | Commands print local working, SDK or scratch paths | Normalize before retaining logs and computing text digests |

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Path IDs | Expected behavior | Required assertions | Type |
|---|---|---|---|---|---|
| S001 | Fresh isolated package, then tampered member | P001 | Accept fresh fixture; reject digest mismatch | Existing validator remains strict | regression |
| S002 | Real production commit, SDK archive and installed SDK | P002,P003 | Require matching current inputs | Missing commit, source drift or SDK mismatch fails | native,identity |
| S003 | Current SDK runs all four development stages | P004 | Capture command results and installed artifact | All stages executed successfully | integration |
| S004 | Missing stage, timeout, nonzero exit or skipped result | P005 | Reject apparent PASS | No omitted stage can qualify | negative |
| S005 | Partial fuzz, shortened preflight or promoted release field | P006 | Reject invalid scope | No formal release claim | negative |
| S006 | Mutated source inventory, artifact or retained log | P007 | Reject stale baseline | No stale report accepted | negative,identity |
| S007 | Local paths in command output | P008 | Retain normalized output | No personal or scratch paths published | privacy |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001 | M7-028 fixture and tamper regressions; P1-013 strict regressions | PASS | Fresh package accepted, strict failures retained | regression |
| T002 | S002,S003 | P002,P003,P004 | capture with qualified SDK and selected production commit | Development PASS | Current check, install, ten fuzz targets, 600-second preflight | native |
| T003 | S004,S005 | P005,P006 | DevelopmentBaselineTests | PASS | Missing, timeout, nonzero, partial and release promotion all rejected | negative |
| T004 | S006 | P007 | Isolated mutations of captured baseline inputs and logs | FAIL for each mutation, clean verification PASS | Identity is checked rather than trusting status | smoke |
| T005 | S007 | P008 | Redaction regression and retained log scan | PASS | Path normalization precedes digest generation | privacy |

## Excluded claims

No formal 86,400-second soak, independent security approval, performance qualification,
production signature, non-Linux support, historical re-seal or feature implementation.

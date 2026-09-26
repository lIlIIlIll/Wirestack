# P1-016 test plan

## Scope

Validate the retired M7 Linux release-attestation workflow as GitHub Actions configuration without executing its historical signing steps. M8-007 remains the active signer; this task creates no release or attestation.

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | P1-016 manifest and its completed P1-015 dependency are registered. | Task-contract validation passes. |
| P002 | The test plan contains linked path, scenario, and test IDs. | Plan validation passes. |
| P003 | A source or evidence commit is pushed to GitHub. | All runs for the exact SHA finish successfully; the retired workflow is not triggered by push. |
| P004 | GitHub accepts the workflow configuration. | Manual dispatch has no signing effect because both retained jobs are guarded; historical artifact identity, permissions, steps, and pinned actions remain unchanged. |

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Path IDs | Expected behavior | Required assertions | Type |
|---|---|---|---|---|---|
| S001 | Registered P1-016 manifest; P1-015 is COMPLETE. | P001 | Manifest validation succeeds. | No missing task or dependency. | contract |
| S002 | P1-016 plan with referenced IDs. | P002 | Plan validation succeeds. | All path, scenario, and test IDs are recognized. | contract |
| S003 | Exact source and sealed-evidence commit SHAs on the task branch. | P003 | Hosted workflows complete successfully. | No failed run; no push-triggered Linux Release Attestation run; PR checks pass. | hosted |
| S004 | GitHub accepts the manual-only workflow configuration. | P004 | Historical signing jobs remain inert. | No signing execution or new attestation is produced by this task. | safety |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001 | Run the manifest acceptance command. | PASS | P1-016 and its dependency are recognized. | contract |
| T002 | S002 | P002 | Run the test-plan acceptance command. | PASS | The plan graph is complete and valid. | contract |
| T003 | S003 | P003 | Enumerate Actions runs and PR checks for each exact pushed SHA. | PASS | Every existing run succeeds; the retired workflow has no push run. | hosted |
| T004 | S004 | P004 | Review the host-accepted event and job outcomes; do not manually dispatch. | PASS | Signing jobs are guarded and no attestation is produced. | safety |

## Excluded claims

No M7/M8 historical PASS, formal release qualification, signature, new platform-support claim, or long-duration release gate is established.

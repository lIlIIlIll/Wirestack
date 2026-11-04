# M9-001 native network capability baseline

## Current qualification boundary

M9-001 remains BLOCKED until its current prerequisite closure, both native gates,
capability correspondence, canonical check, HTML/browser proof and source seal
pass. Historical receipts below do not qualify a changed source candidate.
Publication does not authorize release, signing, merge or a ready transition.

## Current capability correspondence

The integrated capability description belongs to M9-003 and requires eighteen
native scenarios. The original M9-001 runner produces seven foundational
scenarios. A [real current CLI preflight](current-map-contract-preflight.json) rejected the retained seven-scenario
receipt with `native receipt is missing, failed or belongs to another task`.
Changing its task identity or accepting seven cases as eighteen would weaken the
current contract.

The authorized manifest correction keeps both proofs independent:

- The existing M9-001 runner records all seven foundational scenarios in
  [native-capabilities.json](native-capabilities.json).
- The existing M9-003 runner executes all eighteen current-map scenarios as a
  separate M9-001 long gate, with its original 1,800-second deadline. It keeps
  `source_task: M9-003` and its existing output-path guard. Auxiliary output is
  isolated under `../M9-003/m9-001-current-map/`; the report is
  [m9-001-current-map.json](../M9-003/m9-001-current-map.json). Neither canonical
  M9-003 evidence nor its status is overwritten or promoted.
- The unchanged strict capability validator consumes that eighteen-scenario
  auxiliary receipt. Source, installed source, SDK archive/installation,
  capability conditions, every scenario, native commands, archive bytes and
  nested log bytes must still validate.

No new socket operation or fallback is implemented. Constructor defaults and
factory-specific observed flags are checked separately against the single
[current capability description](../../references/linux-network-capabilities.json).
The original seven scenarios remain required even though the auxiliary runner
also exercises them.

## Exercised current-map command, not task acceptance

The exact authorized manifest command was smoked at integrated code source
`1631837216989f7eac6986b24b0b9a2c61d0bd20` with qualified official STS 1.1.3.
The [complete command receipt](maintenance/current-map-command-smoke.json)
keeps the native receipt's M9-003 identity and the task's BLOCKED boundary.

| Execution | Actual result | Evidence boundary |
|---|---|---|
| First complete attempt | 17 scenarios PASS, 1 FAIL; 92.311 seconds | Unix abstract fixture construction reached 109 UTF-8 bytes against its existing 107-byte bound; [original report and logs](maintenance/abstract-temp-failure/original-report.json) remain failures. |
| After deterministic environment correction | All 18 scenarios PASS; 97.909 seconds | Only a shorter private disk-backed temporary root changed; runner, SDK, 64 resource cycles, 107-byte abstract padding and long deadline stayed unchanged. |
| Unchanged strict correspondence | PASS, native PASS, all 86 rows | Actual current auxiliary receipt validates against the current description; no seven-case substitution or task-identity rewrite. |

The actual [selected long gate](current-map-task-check.json) still exits
2/INVALID with no commands because P1-015 is not COMPLETE. Direct native
success does not satisfy that prerequisite, the independent seven-scenario
gate, HTML/browser proof or the final task seal.

The [current API comparison](api-compatibility.json) records 39 added
declarations, no declaration removals and 20 changed declaration records
against the M8-007 inventory. It includes changed WebSocket parameter types,
resolver interface conformances, fields and enum cases, not just capability
defaults. Old-consumer source execution, old binaries and cross-SDK behavior
remain NOT_RUN; no universal source or ABI compatibility is claimed.

## Execution order

Use the qualified STS archive and trusted native cjdoc recorded by the current
qualification environment. Verify the current development baseline first, then
execute the long gate before the task gate's correspondence command:

Use a short, unique mode-0700 temporary directory under
`$HOME/.cache/agent-tmp` on the checked disk-backed filesystem. Size the longest
Unix fixture suffix before running; SDK wrappers that reset `TMPDIR`, `TMP`
and `TEMP` need the task-specific override applied afterward. This changes
temporary-path geometry, not endpoint bounds, padding or workload.

```sh
python3 tools/development_baseline.py verify
python3 tools/repository/repository_tooling.py --root . check long M9-001 --json --output docs/evidence/M9-001/current-map-task-check.json
scripts/check-task M9-001 --json --output docs/evidence/M9-001/task-check.json
```

The task gate still executes its own seven-scenario runner, negative regressions,
canonical repository check and HTML gate. A failed, skipped or missing scenario,
permission failure, cross-compilation or missing native facility cannot become
PASS. Native archives remain ignored local verification artifacts, not published
or signed releases.

## Evidence

- [Test plan](test-plan.md) records the separate foundational and current-map
  native paths, tamper rejection and actual API comparison requirements.
- [Capability correspondence](capabilities.json) and
  [API inventory](api-inventory.json) must reflect the current declarations.
- [Compatibility analysis](api-compatibility.json) must compare the actual current
  inventory with its recorded baseline. The historical two-constructor-default
  delta is not a description of the integrated tree. Old-binary and cross-SDK
  execution are not claimed without execution evidence.
- [Task results](task-check.json), [HTML result](docs-report.json) and actual
  browser evidence remain separate from the native receipts.
- The [source-bound evidence index](evidence.json) must verify after all current
  source inputs and acceptance receipts are frozen.

Earlier workspace, regression, failed-attempt, documentation-heap and publication
records remain historical provenance. Their counts, heap settings and SDKs are
not reused as current acceptance. The current documentation contract uses the
approved three-view scheduling bound and unchanged strict checks and deadlines.
No new heap override is introduced here.

## Scope exclusions

No historical M7/M8 release gate or other task is promoted. No formal independent
security review, 86,400-second soak, production signature, non-Linux platform or
system-DNS deployment matrix is qualified. Existing unsupported-operation and
resource assertions remain part of the actual native runners.

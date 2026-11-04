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

## Execution order

Use the qualified STS archive and trusted native cjdoc recorded by the current
qualification environment. Verify the current development baseline first, then
execute the long gate before the task gate's correspondence command:

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

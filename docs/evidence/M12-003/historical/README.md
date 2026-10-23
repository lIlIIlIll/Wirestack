# Historical M12-003 task gate receipt

`task-gate-2026-10-09.json` is the byte-exact task gate receipt generated on 2026-10-09 by `scripts/check-task M12-003 --json --output docs/gates/M12-003-task.json` for the campaign-bound inputs of that revision.

It is **not** current validation. Review fixes later changed `tools/gates/m12_003_network.py` after the campaign-bound digest was recorded, so current source-bound campaign verification exits 1 and the task is BLOCKED (see [verification.json](../verification.json) and [current-source-verification.log](../current-source-verification.log)).

The historical copy remains only to preserve the original tool output. Do not
write an `INVALID` or `FAILED` result to the canonical
`docs/gates/M12-003-task.json` path. Run the no-output check
`python3 tools/repository/repository_tooling.py --root . check task M12-003 --json`.
Publish the canonical receipt with
`scripts/check-task M12-003 --json --output docs/gates/M12-003-task.json` only
after the precheck reports `PASS` and executes the acceptance commands, and
after the source-bound native campaign passes. Repository-wide dependency
closure is required in addition to M12-003's direct prerequisites.

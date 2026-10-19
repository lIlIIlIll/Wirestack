# Historical M12-003 task gate receipt

`task-gate-2026-10-09.json` is the byte-exact task gate receipt generated on 2026-10-09 by `scripts/check-task M12-003 --json --output docs/gates/M12-003-task.json` for the campaign-bound inputs of that revision.

It is **not** current validation. Review fixes later changed `tools/gates/m12_003_network.py` after the campaign-bound digest was recorded, so current source-bound campaign verification exits 1 and the task is BLOCKED (see [verification.json](../verification.json) and [current-source-verification.log](../current-source-verification.log)).

The receipt is retained only to preserve the original tool output under an explicitly historical path. Regenerate the canonical `docs/gates/M12-003-task.json` with `scripts/check-task M12-003 --json --output docs/gates/M12-003-task.json` after a current-bound native campaign passes; this historical copy does not stand in for that run.

# Historical P1-012 receipts

`validate-tasks-c1d908a5.json` is the byte-exact output of

```shell
python3 tools/repository/repository_tooling.py --root . validate-tasks --json --output docs/evidence/P1-012/historical/validate-tasks-c1d908a5.json
```

executed at `c1d908a5d1f3a53f8b6e038cc0eacd2bb1e9e50a`, the first revision of
this branch. It records PASS for 41 task IDs. That revision predates the status
correction for M10-004, so the receipt cannot be reproduced at the final
revision: repository-wide validation now returns INVALID on the
`M10-004 -> M10-003` edge.

It is **not** current validation and no file references it as acceptance. The
receipt is retained only to preserve the original tool output under an
explicitly historical path. The current repository-wide result is
[`global-readiness.json`](../global-readiness.json), and the current
selected-task result is [`task-check.json`](../task-check.json). Regenerate a
current receipt with `python3 tools/repository/repository_tooling.py --root .
validate-tasks --json` after M10-003 completes; this historical copy does not
stand in for that run.

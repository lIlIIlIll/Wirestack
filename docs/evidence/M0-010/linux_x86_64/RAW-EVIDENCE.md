# Raw evidence handling

The formal report is committed as [`result.json`](result.json). It contains
all read-size arrays, RSS and thread samples, process results, paired execution
order, percentiles, `strace` receive traces and instrumentation digests.

The formal command is:

```text
timeout 900s env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack bash scripts/gate-net05-large-buffer-profile --warmup 1 --repetitions 11 --output /tmp/wirestack-m0-010-fair-shape-formal11.json --artifact-dir /tmp/wirestack-m0-010-fair-shape-formal11-artifacts --repository-revision working-tree-m0-010-fair-shape
```

Exit 1 is the expected command result for the retained report because the
runner completed its matrix and made the measured `linux_profile_status=FAIL`
decision. A missing tool, build error, timeout or malformed result would instead
emit `GATE-NET-05 profile: ERROR` and would not qualify as gate evidence.

# Command invocation note

Files created through the GitHub Contents API use a regular-file mode. Until a normal Git checkout records the executable bit, invoke the wrapper portably as:

```bash
sh scripts/architecture-guard
sh scripts/architecture-guard --format json
```

The canonical implementation remains `tools/architecture_guard.py`, which CI invokes directly with `python3`.

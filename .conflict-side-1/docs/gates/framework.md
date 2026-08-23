# Gate execution framework

Wirestack uses `tools/gates/gate_runner.py` to execute bounded, reproducible gate scenarios. The runner is infrastructure for GATE-NET-01 through GATE-NET-07; adding the framework does **not** mark any network gate or platform as passed.

## Result states

| State | Meaning |
|---|---|
| `PASS` | Every required scenario and executed step completed successfully. |
| `FAIL` | A command returned non-zero or exceeded its explicit timeout. |
| `ERROR` | The manifest, working directory, process launch, or harness itself was invalid. |
| `BLOCKED` | A required tool or external prerequisite was unavailable. |
| `SKIPPED` | The scenario was disabled or did not apply to the current platform. |

A run is `PASS` only when every scenario is `PASS`. `BLOCKED` and `SKIPPED` are evidence states, not successful execution.

## Manifest rules

- JSON schema version is explicit; unknown versions and unknown fields fail closed.
- Commands are arrays and never pass through a shell.
- Every scenario and step has a stable ID.
- Each command has a bounded timeout.
- Required tools are checked before side effects.
- Working directories must remain inside the repository or the scenario artifact directory.
- Placeholders are limited to `{repo_root}`, `{artifact_dir}`, and `{work_dir}`.

## Process and output handling

Each command receives its own process group/session. On timeout, the harness terminates the group and escalates to a forceful kill after a bounded grace period. Standard output and standard error are written to separate artifact files, while the JSON report embeds only a bounded excerpt.

The result report records:

- manifest SHA-256;
- repository revision when available;
- OS, architecture, platform and Python version;
- observed `cjc` and `cjpm` versions;
- `CANGJIE_HOME` when provided by the execution environment;
- UTC diagnostic timestamps and monotonic durations;
- exact commands, working directories, exit codes and timeout state;
- artifact paths and bounded output excerpts.

Reports are written through a temporary file followed by an atomic replacement.

## Commands

SDK-independent harness tests:

```bash
python3 -m unittest discover -s tools/gates/tests -p 'test_gate_runner.py' -v
```

Run an arbitrary manifest:

```bash
sh scripts/run-gates path/to/manifest.json output.json artifact-directory
```

After loading the supplied SDK environment, validate the current package skeleton and compile/run a Cangjie smoke program:

```bash
sh scripts/check-supplied-sdk
```

The SDK smoke establishes only that the selected SDK can check/build the current repository and execute a minimal program on that host. It is not a TCP, TLS, HTTP, cancellation, EOF, performance, or cross-platform result.

## Native-platform evidence

Later gate manifests must identify the exact native runner or device. Cross-compilation does not replace execution on Windows, macOS, Android, iOS, HarmonyOS/OpenHarmony, Linux glibc/musl, or another required target. Platform reports are stored under `docs/evidence/<TASK-ID>/<platform>/` or attached to CI with an immutable commit identifier.

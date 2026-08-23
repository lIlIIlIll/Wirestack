# Wirestack Codex Fleet Execution

This document defines dependency-aware parallel execution for the complete Wirestack backlog.
It complements, but does not replace, the PRD, accepted ADRs, `AGENTS.md`, or the task acceptance criteria.

## Execution model

Wirestack uses rolling parallelism:

1. parse the backlog dependency graph;
2. select every task whose dependencies are recorded COMPLETE, up to the configured concurrency cap;
3. create one Git branch, one Git worktree, and one Codex session per task;
4. keep task implementation and evidence isolated;
5. review and merge one PR at a time;
6. mark the merged task COMPLETE and immediately fill the freed lane with the next READY task.

The default cap is eight implementation sessions. A separate coordinator/reviewer owns shared-file integration, ordered merges, and state updates.

This is intentionally not “start every task at once.” Transport SPI, provider selection, public APIs, error models, pool keys, HTTP/2 connection state, and release claims must not be implemented before their declared dependencies are frozen.

## First active wave

| Task | Branch | Issue | Session ownership |
|---|---|---:|---|
| M0-008 | `task/M0-008-absolute-deadline` | #13 | absolute-Deadline probes and evidence |
| M0-009 | `task/M0-009-eof-terminal-evidence` | #14 | EOF/terminal probes and evidence |
| M0-010 | `task/M0-010-large-buffer-profile` | #15 | large-buffer/copy profile and evidence |
| M0-011 | `task/M0-011-leak-soak-harness` | #16 | leak/soak tools and evidence |
| M0-012 | `task/M0-012-mobile-network-change` | #17 | mobile evidence contracts/validators; absent devices stay BLOCKED |
| M0-013 | `task/M0-013-dns-carrier-thread` | #18 | DNS scheduler probe and evidence |
| M0-014 | `task/M0-014-windows-copy-profile` | #19 | Windows evidence contract/validator; absent native runner stays BLOCKED |
| M0-015 | `task/M0-015-tls-provider-matrix` | #25 | provider research matrix and evidence |

## Local commands

Load the supplied Cangjie SDK environment first. When the SDK has an environment setup script:

```bash
export WIRESTACK_SDK_ENV=/absolute/path/to/cangjie/envsetup.sh
```

Show the dependency-satisfied wave:

```bash
scripts/codex-fleet plan
```

Create all READY worktrees without starting Codex:

```bash
scripts/codex-fleet prepare
```

Launch up to eight sessions in isolated `tmux` sessions:

```bash
scripts/codex-fleet launch
```

Alternative without `tmux`:

```bash
scripts/codex-fleet launch --backend process
```

After a PR is reviewed and merged, the coordinator records completion and computes the next wave:

```bash
scripts/codex-fleet mark-complete M0-008
scripts/codex-fleet plan
scripts/codex-fleet launch
```

Environment controls:

```text
WIRESTACK_WORKTREE_ROOT   worktree parent; default ../Wirestack.worktrees
WIRESTACK_SDK_ENV         optional shell file sourced before Codex starts
CODEX_FLEET_MODEL         optional model override; omitted uses user configuration
CODEX_FLEET_EXTRA_ARGS    optional additional Codex CLI arguments
```

The launcher uses `codex exec --approve-for-me` in a workspace-write sandbox. Network is enabled by default so task agents can fetch, push, open PRs, and research source material. Disable it for an individual launch with `--no-network`.

## Worktree and file ownership

Every agent receives a distinct directory under `WIRESTACK_WORKTREE_ROOT`. Merely using separate branches in one working directory is not isolation.

Implementation agents do not edit these shared integration hotspots:

- `docs/planning/status.md`
- `scripts/check`
- `README.md`
- `AGENTS.md`
- `cjpm.toml`
- shared ADR indexes or cross-task architecture summaries
- another task's `docs/evidence/<TASK-ID>/`

Each task adds task-specific tools, tests, workflow files, and its own evidence. The coordinator performs one consolidated shared-file update after a merge wave.

## Host measurement serialization

Coding, deterministic tests, parser work, validators, and documentation can run concurrently. Final timing, throughput, copy, DNS-starvation, leak, and soak measurements on the same host cannot run concurrently because resource contention invalidates evidence.

Timing-sensitive commands must acquire the common Git repository lock:

```bash
scripts/with-host-gate-lock linux-native-gate -- <task-command> [args...]
```

All worktrees share the same lock through Git's common directory. Different native runners may use separate resource names, for example:

```text
linux-native-gate
windows-native-gate
android-device-01
ios-device-01
harmony-device-01
```

A task may develop its harness in parallel, then wait for its native resource lock before producing final evidence.

## Merge coordinator

The coordinator performs the following sequence:

1. verify changed-file ownership;
2. require task-specific tests and architecture guard success;
3. distinguish task COMPLETE from platform/global gate completion;
4. merge one PR;
5. update the remaining branches from `main` and rerun CI;
6. update shared status/check/index files;
7. record the task COMPLETE in `fleet-state.json`;
8. launch the newly READY replacement task.

Agents may commit, push, open PRs, and repair CI automatically. They do not merge their own PRs.

## Rolling M0 unlocks

- M0-015 unlocks M0-016 and M0-018.
- M0-008 through M0-014 unlock M0-019 after all evidence, including failures and BLOCKED platform results, is retained.
- M0-012 plus M0-016 unlock M0-017.
- M0-016 plus M0-018 unlock M0-020.
- M0-019 plus all gate evidence unlock M0-021.
- M0-004 through M0-021 unlock M0-022.
- M0 exit unlocks the M1 task graph; the same READY-task rolling policy continues through M7.

## Evidence integrity

Unavailable platforms, absent devices, cross-compilation, skipped tests, timeouts, incomplete soak duration, and unmeasured counters never count as PASS. Parallelism changes scheduling only; it does not weaken acceptance criteria.

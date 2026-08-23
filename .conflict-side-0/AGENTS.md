# Wirestack Repository Instructions

## Project identity

- Product and repository name: Wirestack.
- GitHub repository: `lIlIIlIll/Wirestack`.
- Default public Cangjie package prefix: `wirestack`.
- This is a greenfield implementation.
- Do not copy legacy stdx TLS APIs, global providers, OpenSSL configuration,
  timeout ownership, error strings, or compatibility behavior unless a task
  explicitly requires documented migration material.

## Sources of truth

Read these before modifying code:

1. `docs/product/prd.md`
2. Accepted ADRs in `docs/architecture/adr/`
3. `docs/planning/implementation-backlog.md`
4. `docs/planning/status.md`
5. The current task or GitHub issue
6. Existing tests and implementation

The PRD defines product scope and hard constraints.
Accepted ADRs may refine implementation details but may not silently weaken the PRD.
The backlog defines task dependencies and acceptance criteria.

When sources conflict, stop implementation and report the conflict. Do not
silently choose one interpretation.

## Task discipline

- Execute exactly one backlog task ID per implementation branch and pull request.
- Locate the task by ID in `docs/planning/implementation-backlog.md`.
- Verify all declared dependencies are COMPLETE and have evidence before editing.
- Do not implement later-milestone work merely because it is convenient.
- Do not start an `UP-*` task without a corresponding failed gate, reproducible
  evidence, affected platforms, and an approved minimal upstream interface.
- A blocked task remains BLOCKED. Never weaken acceptance criteria to mark it complete.
- Do not automatically continue to the next backlog task after completing the current one.

## Architecture invariants

The dependency direction is:

    HTTP -> TLS -> Transport SPI <- StdNetTransport -> std.net

Mandatory constraints:

- Only the StdNet transport adapter may import `std.net`.
- TLS Core, HTTP/1.1 Core, HTTP/2 Core, and public APIs must not import or expose
  `std.net` types.
- Wirestack must not call `CJ_MRT_Sock*` private runtime ABI.
- Wirestack must not implement separate epoll, kqueue, or IOCP event loops.
- Default release artifacts must not require a system OpenSSL installation.
- TLS providers are selected at build time; no runtime library guessing or
  automatic provider fallback.
- DNS, TCP, proxy, TLS, HTTP headers, and HTTP body operations share one
  monotonic absolute Deadline and CancellationToken.
- Do not introduce a second timeout owner.
- EOF, local close, abort, cancellation, deadline, RST, and TLS truncation must
  not be collapsed into one result.
- Every operation completes at most once.
- close and abort are idempotent.
- Every queue, buffer, cache, pool, session store, parser limit, table, and
  window is explicitly bounded.

## External repositories

The Cangjie SDK, `cangjie_stdx`, `std.net`, runtime source, and TLS provider
candidate repositories are read-only references unless the current task is an
explicit upstream task executed in that upstream repository.

Do not modify sibling repositories from a Wirestack task.
Do not vendor an SDK, toolchain, system certificate store, or arbitrary provider
checkout into this repository.

Record exact external versions and commit IDs under `docs/references/`.

`UP-*` tasks in Wirestack are tracking/evidence tasks. Any actual `std.net` or
runtime source change must be implemented and reviewed in the corresponding
upstream repository.

## Workspace safety

Before editing, record:

- current repository root;
- current branch and HEAD;
- merge base with the target branch;
- `git status --short`;
- existing dirty paths;
- available Cangjie toolchain and target platform.

Do not run reset, clean, stash, rebase, amend, force push, destructive checkout,
or discard unrelated changes unless the task explicitly authorizes it.

Do not commit, push, create a PR, or modify GitHub issues unless the task
explicitly authorizes those actions.

Preserve unrelated and concurrent workspace changes.

## Implementation requirements

- Production changes and their tests belong in the same task.
- No deferred “tests will be added later”.
- Waiting operations use the canonical OperationContext once it exists.
- Errors retain category, phase, stable code, retryability, native code when
  available, endpoints, and cause.
- Never use exception message text as control flow.
- Public API changes require API documentation, examples, and architecture
  dependency checks.
- Platform support claims require execution on a real device or native VM.
- Cross-compilation alone is not completion.
- Performance claims require raw output, environment metadata, baseline, and
  an explicit pass/fail decision.
- Security-sensitive parsers require negative tests and fuzz coverage.

## Build layout

The repository currently records only a logical module layout. Do not invent a
`cjpm.toml`, package tree, or target graph from assumptions. M0-002 must inspect
the actual supported Cangjie toolchain and freeze the physical package/target
layout before production package skeletons are treated as stable.

## Verification

Use canonical repository scripts once they exist:

- `scripts/check`
- `scripts/test`
- `scripts/verify`
- milestone-specific gate and benchmark commands

Until those scripts are established, use only commands supported by the actual
toolchain/environment and report the exact command and exit status.

Do not claim a test passed when it was skipped, unavailable, timed out, or only
compiled.

## Evidence and status

Store durable task evidence under:

    docs/evidence/<TASK-ID>/

Gate reports belong under:

    docs/gates/

Update `docs/planning/status.md` only for the current task.
Every COMPLETE entry must link to its tests, report, benchmark, PR, commit, or
other acceptance evidence.

## Required final report

Every task response must contain:

A. Workspace safety
B. Task ID and status: COMPLETE, INCOMPLETE, or BLOCKED
C. Scope completed
D. Files changed
E. Acceptance criteria and evidence
F. Commands and tests with exact results
G. Remaining risks or blockers
H. Suggested next READY task IDs

Never describe unavailable platform evidence as passed.

# M0-004 evidence — network-gate execution framework

## Scope

This task establishes the reusable execution and evidence layer for later GATE-NET scenarios. It does not implement network behavior and does not mark GATE-NET-01 through GATE-NET-07 as passed.

## Delivered

- versioned and strict JSON manifest validation;
- `PASS`, `FAIL`, `ERROR`, `BLOCKED`, and `SKIPPED` result semantics;
- process-group termination for timed-out commands;
- bounded report excerpts with full stdout/stderr artifact files;
- atomic JSON report publication;
- repository/toolchain/platform metadata capture;
- SDK-independent harness unit tests and CI;
- a supplied-SDK smoke manifest that runs `cjpm check`, `cjpm build`, and a compiled Cangjie program.

## Verification commands

```text
python3 -m unittest discover -s tools/gates/tests -p 'test_gate_runner.py' -v
python3 tools/gates/gate_runner.py \
  --manifest tools/gates/manifests/sdk-smoke.json \
  --repo-root . \
  --artifact-dir build/gates/sdk-smoke-artifacts \
  --output build/gates/sdk-smoke.json
```

The unit suite covers success, non-zero failure, timeout/process-group cleanup, missing-tool blocking, platform/disabled skipping, mixed PASS+SKIPPED aggregation, bounded output, fail-closed schema validation, atomic publication, and malformed-manifest CLI behavior.

## Supplied SDK baseline

The supplied archive identifies:

```text
cjc 1.1.0-alpha.20260817040003 (cjnative)
target: x86_64-unknown-linux-gnu
cjpm 1.1.3
```

A checked-in result must only be added after rerunning the SDK smoke against the exact task commit. Linux x86_64 evidence cannot be generalized to any other target or platform.

## Explicit non-claims

- no `std.net` close/cancel/EOF behavior is proven;
- no raw TCP baseline is established;
- no TLS provider is selected;
- no Transport, Resolver, TLS, HTTP/1.1, or HTTP/2 production code is added;
- no `UP-*` task is unlocked.

# ADR-0007: Desktop TLS adoption gate

- Status: Accepted
- Date: 2026-08-31
- Owner: Wirestack project owner
- Related task: M3-031
- PRD references: §13, §14, §21.5, §23, §25 M3

## Context

The Linux delivery profile implemented and qualified the provider-neutral TLS
Core under M3-028 through M3-030. The global backlog still names M3-001,
M3-002, M3-006, M3-009 through M3-012, M3-016 and M3-018 as direct
prerequisites for the Windows and macOS adapters. Those historical task IDs do
not have global COMPLETE entries or independent evidence directories.

ADR-0002 does not permit a Linux result to change a global task status. Directly
starting M3-014 would therefore bypass the declared dependency graph even
though the shared implementation now exists.

At the time of the decision, the provider evidence had a second split. AWS-LC
5.5.0 passed the retained Windows x86_64 PoC, while the retained macOS arm64
result predated the strengthened external-signer contract. Neither result
selected a production desktop provider by itself.

## Decision

M3-031 is the one-time adoption gate between the completed provider-neutral
Core and the desktop platform adapters. It does not relabel or complete the
historical global tasks. Its evidence maps only the desktop-applicable
contract from M3-001, M3-002, M3-006, M3-009 through M3-012, M3-016 and
M3-018 to current source, tests and retained M3-028 or historical M3-030 evidence.

Retained M3-030 reports are historical provenance, not current Core
qualification. M3-031 still runs the complete historical identity, inventory,
digest and provenance verifier. A historical verifier error is recorded by
`audit-core` as `status: HISTORICAL` with `integrity_status: STALE` or `FAIL`
and the exact error code/detail; that diagnostic neither blocks current Core
admission nor supplies qualification. Current admission requires a separate
source-bound `docs/evidence/M3-031/current-core/qualification.json` receipt
captured from the frozen candidate revision using the pinned STS SDK. The
receipt binds production and execution inputs, actual provider selection and
native ABI, executed build/guard/substitution commands and their retained logs,
and a fresh installed HTTPS consumer qualification. Verification repeats
these checks; `audit-core` and `aggregate` must consume the current verified
receipt and reject a hand-authored PASS summary.

The mapping is a scoped dependency projection, not a substitute for each
historical task's global acceptance. In particular, M3-001's six-platform
target-build condition remains unproven and unchanged. Any condition requiring
a mobile build, simulator or device stays with the original global or M4 task.

The M3-031 manifest has no recursive task dependencies. Its acceptance
directly validates the current-desktop report and validation pair for M2-004
(Windows x86_64) and M2-006 (macOS arm64), each bound to its pinned STS SDK,
current source inventory, executed native cases, and retained logs. The legacy
generic M2 evidence indexes, global M2 task statuses, and M2-006 iOS evidence
are not M3-031 inputs. This scoped projection does not rewrite or promote any
M2 status or evidence. M3-030 evidence is separately integrity-checked as
historical diagnostics: its status or retained-report failures do not block
current Core admission. These are evidence inputs, not task-graph edges; no
upstream closure is traversed or task status promoted.
After M3-031 passes, the desktop dependency graph is:

```text
           M3-031
          /      \
     M3-014      M3-015
        |           |
     M3-019      M3-020
```

M3-014 and M3-015 retain their original trust-adapter acceptance criteria.
M3-019 and M3-020 retain their non-exportable-key and external-signer criteria.
Replacing the dependency list does not remove any product requirement.

Windows x86_64 and macOS arm64 select pinned AWS-LC 5.5.0 for their desktop
adoption path. The selection becomes effective only after an exact-revision
schema-v11 PoC reports PASS for every required capability on both GitHub-hosted
native runners. Provider selection remains a build-time decision. Unknown
providers, unsupported platform combinations and any automatic fallback fail
closed.

GitHub `windows-2025` is accepted as the native Windows x86_64 execution
environment. GitHub `macos-15` arm64 is accepted as the native macOS execution
environment. An iOS Simulator run is useful integration evidence but is not an
iOS device result. Android and Harmony hosted compilation is not device
evidence.

## Consequences

- M3-031 can complete without changing TLS or HTTP state machines.
- The audit reports the projected desktop contract and excluded global
  conditions separately; an excluded condition can never be recorded as PASS.
- The desktop trust tasks can start from one current, source-bound Core
  contract instead of inventing replacement historical status rows.
- Windows and macOS provider PoCs must be rerun when their source, PoC,
  provider pin or required capability list changes.

- M3-030 evidence is checked only for historical identity, inventory,
  digests and provenance; its semantic contents cannot satisfy the current
  Core admission proof.
- Current Core admission is invalidated by source, execution-input, SDK,
  native archive, command-log, installed qualification or consumer-artifact
  drift.
- M0-016 remains BLOCKED until the complete six-platform PoC matrix passes.
- M0-020 remains BLOCKED for the global six-platform decision.
- M4 dependencies and mobile device requirements do not change in this task.
- Production Windows and Apple trust/key adapters remain M3-014, M3-015,
  M3-019 and M3-020 work.

## Evidence

- `docs/evidence/M3-031/README.md`
- `docs/evidence/M3-031/test-plan.md`
- `docs/evidence/M2-004/current-desktop/windows-x86_64/report.json` and
  `validation.json` with retained logs
- `docs/evidence/M2-006/current-desktop/macos-arm64/report.json` and
  `validation.json` with retained logs
- `docs/evidence/M3-031/core-prerequisite-audit.json`
- `docs/evidence/M3-031/desktop-provider-matrix.json`
- `docs/evidence/M3-031/current-core/qualification.json`

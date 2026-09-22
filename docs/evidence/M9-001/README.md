# M9-001 — native network capability baseline

Task acceptance is complete when the [source-bound evidence index](evidence.json)
verifies. Native execution, capability correspondence and the canonical repository
checks pass. Publication of the separate prerequisite branches and this task is
authorized. The index records the exact source candidate; publication does not
qualify M8-007 or authorize a production release, signing or automatic merge.

## Scope

- Correct `SocketCapabilities()` and Internet UDP factory values: `broadcast`
  and `multicast` are false. No public option-application or membership operation
  exists. Connected Internet UDP send remains true.
- Register all 16 M9–M12 roadmap rows, their issue links, start dependencies and
  separate completion/integration dependencies. M9-001 starts from P1-015, not
  from the historical M8-007 release gate. No later task is implemented.
- Maintain one [capability description](../../references/linux-network-capabilities.json)
  containing 54 field claims and 27 operation/boundary rows. The static checker
  reuses the repository Cangjie API extractor; it rejects unmapped operations,
  missing fields, constructor-default drift, absent conditions/backend links,
  invalid typed failures, and generated-document drift.
- Build a fresh archive and compile four consumers whose only Wirestack
  dependency is its extracted installation outside the checkout. Execute
  Internet IPv4/IPv6, Unix pathname/abstract, capability/resource, configured
  DNS and DNS-to-connect scenarios. Existing peer/profile helpers are reused;
  historical reports are not qualification inputs.

## Evidence

- [Workspace snapshot](workspace.json): pre-edit HEAD, merge base, dirty paths
  and the successful prerequisite verification.
- [Red/green regression](regression.json): the focused Cangjie case fails before
  the flag correction and passes after it; filtered cases are not called passed.
- [Test plan](test-plan.md): operation paths, error/resource boundaries and
  mutation scenarios. Focused Python regressions exercise rejected claims,
  skipped/missing scenarios, wrong SDK digest domain, changed source/helper
  bytes, altered logs/archive bytes and evidence-path escapes.
- [Native receipt](native-capabilities.json): seven scenarios, fifteen bounded
  command records, six socket classes × nine observed flags, source and
  installed-source equality, exact SDK archive identity, and 183 execution
  input digests. Every scenario must be `PASS`; compilation or skipping is not
  native qualification.
- [Capability correspondence](capabilities.json) and [API inventory](api-inventory.json).
- [Compatibility classification](api-compatibility.json): only the two
  constructor defaults changed in the public inventory. No declaration, field
  or enum case was added or removed. Default-value semantics changed; rebuild
  consumers. No old-binary or cross-SDK execution claim is made.
- Canonical task results are recorded in `task-check.json`; HTML documentation
  results are in `docs-report.json`. A failed or absent receipt is not PASS.

The native archive remains in ignored `dist/m9-001/`, at the relative path and
byte digest recorded in the receipt. It is a local verification artifact, not a
published or signed release. Raw native logs are under `native-capabilities/`.
Machine-specific checkout, SDK, home and temporary paths are normalized before
log digests are calculated.

## Unsupported and conditional behavior

Raw IPv4, IPv6, packet and netlink operations reject without a privileged socket
attempt. Half-close, empty datagram send, Unix connected send and invalid
outgoing abstract names retain their distinct typed errors. During these
probes, native syscall traces show no socket allocation, thread creation or
shutdown syscall; process FD and task inventories remain unchanged. Established
I/O and open/listening state remain usable after rejection.

Linux outgoing abstract names remain constrained to 107 valid UTF-8 bytes;
incoming named sources can retain arbitrary bytes. An unbound Unix datagram
source still produces the existing post-consumption conversion failure; the
implementation does not synthesize an unnamed endpoint or restore the packet.
Pathname cleanup remains caller-owned.

Permission denial and unavailable native facilities are environmental failures,
not evidence that a build-time capability exists. DNS evidence covers the
configured local nameserver, parser and controlled connection path only. It
makes no system-resolver deployment-matrix claim.

## Reproduction

Use the exact SDK archive and native target recorded in the native receipt.
Set `WIRESTACK_BASELINE_SDK_ARCHIVE` to that archive and put its Cangjie tools on
`PATH`. The SDK-compatible cjdoc is the rebuilt 0.7.2 executable from the P1-015
development baseline, not an untouched historical pinned executable.

Combined documentation generation hit `Out of memory` with `cjHeapSize` unset;
the [failed command](documentation-heap/default-failure.json) is retained. Point
`CJDOC_BIN` at an executable launcher with a bounded heap for cjdoc only, and
set `WIRESTACK_CJDOC_EXECUTABLE` to that SDK-compatible executable:

```sh
#!/bin/sh
set -eu
export cjHeapSize=1GB
exec "${WIRESTACK_CJDOC_EXECUTABLE:?Set the SDK-compatible cjdoc executable}" "$@"
```

The variable and accepted units are documented in the
[runtime environment guide](https://docs.cangjie-lang.cn/docs/1.1.0-beta.23/dev-guide/source_zh_cn/Appendix/runtime_env.html#cjheapsize).
The [reduced generation result](documentation-heap/bounded-heap.json) records
the executable byte identity and source inventory. Native consumers retain the
SDK default heap settings; no SDK or documentation-generator source is changed.

```sh
scripts/check-task M9-001 --json --output docs/evidence/M9-001/task-check.json
```

This runs the plan validator, focused regressions, fresh installed native
qualification, correspondence checker, canonical repository checks and HTML
API documentation. Individual acceptance commands and timeouts are in
[`tools/tasks/M9-001.json`](../../../tools/tasks/M9-001.json).

The pre-edit P1-015 verification passed. Its receipt is historical after this
source change and is not rewritten to imply that the M9 source is unchanged.
Independent security review, the candidate-bound 86,400-second soak, signing and
historical M7/M8 release qualification remain outside this task.

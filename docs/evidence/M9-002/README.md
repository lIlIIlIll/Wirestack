# M9-002 — typed Internet socket options

M9-002 acceptance is bound by the [source-bound evidence index](evidence.json),
which must verify against the exact candidate. The owner authorized this repair's
source/seal commits, publication of PR #191 and merge after required gates.
[publication.json](publication.json) records the candidate and authorization
boundary; it is not release qualification. The original dirty workspace remains
untouched.

## Scope

- Twelve typed `SocketOption` cases and matching `SocketOptionName` queries.
  Listener and UDP bind options, outgoing TCP options, independently owned
  accepted-TCP policy, runtime TCP/UDP configuration and effective native queries.
- Complete list validation before native allocation/mutation; bounded option
  count and value domains; default overrides; deterministic application order.
- On unqualified targets, empty options preserve basic factories, explicit lists
  remain Unsupported, and Linux-specific defaults are skipped.
- First/middle/last failure cleanup for factories and accepted sockets; runtime
  successful-prefix retention rather than rollback. Accepted failure leaves the
  listener usable. Listener close before publication closes the private accepted
  socket instead of returning it.
- Bidirectional exclusion between control and I/O, including a real UDP send
  delayed at the syscall boundary. Cancellation/expiry do not gratuitously abort
  healthy sockets; existing terminal ownership is retained.
- IPv4/IPv6-specific support and structured unsupported results. IPv4 UDP now
  advertises broadcast configuration; IPv6 does not. Multicast membership, Unix
  options, arbitrary raw options and M9-003 remain outside this task.

The complete public contract, value/stage matrix and migration instructions are
in the [network guide](../../guides/network-foundation-linux.md#配置与查询-typed-socket-options).
The [installed consumer](../../../examples/linux/m9_002/socket_options.cj) also
uses the options through a custom HTTP connector without replacing its supplied
OperationContext or adding a timeout owner.

## Acceptance evidence

| Requirement | Evidence |
|---|---|
| Workspace and prerequisite safety | [workspace.json](workspace.json): clean isolated worktree, preserved original dirt, exact base commits, successful pre-edit M9-001 seal verification |
| Exact public SDK capability | [SDK reference](../../references/m9-002-option-sdk.json), [four compiled and executed probes](sdk-probes.json), raw `sdk-probes/*.strace` |
| Boundaries, target/family/stage rejection, native readback | `M9002SocketOptionTest`: 10 cases; [test plan](test-plan.md) |
| Ordered faults, cleanup, ownership and concurrency | `M9002OptionExecutionTest`: 15 cases, including two qualification-injected fallback regressions; accepted-close regression fails before the fix and passes after it |
| Installed public-only consumers | [native-options.json](native-options.json): 11 native scenarios, five independently built consumers, exact SDK/archive/source/input digests |
| No socket allocation for invalid factory input | `native-options/options/invalid-option-admission.syscalls.log`: no `socket()` calls |
| Active UDP send excludes query/configure without losing data | `native-options/options/active-send-control.syscalls.log`: actual delayed `sendto`; consumer verifies typed rejection, exact payload and unchanged Broadcast |
| Effective buffers, not requested-value echoes | IPv4 and IPv6 installed consumers request 4096 and read 8192 |
| Capability and API correspondence | [capabilities.json](capabilities.json), [api-inventory.json](api-inventory.json); 86 rows and all 11 required scenarios |
| Conditional claims and receipt tamper rejection | 24 focused Python cases, including missing IPv6 observation and false IPv6 broadcast claims |
| Existing lifecycle/protocol regressions | Canonical `scripts/check`: 695 Python checks; 811 Cangjie cases pass, 23 Performance cases excluded, zero failures/errors |
| API source compatibility | [api-compatibility.json](api-compatibility.json): old exhaustive client builds and runs on the retained M9-001 archive; compilation against the new archive fails specifically on four uncovered cases |
| Generated API and HTML | [docs-report.json](docs-report.json), generated API artifacts; exact task-level result in [task-check.json](task-check.json) |
| Final command, source and privacy record | [verification.json](verification.json), [privacy.json](privacy.json) |

Focused Cangjie selection passes 25 cases; its 155 filtered cases are not called
passed. The canonical repository run excludes only its existing 23 Performance
cases. Diagnostic text such as `SOAK_ALREADY_RUNNING` appears in negative Python
fixtures; it is not a new long-duration gate execution or a release result.

The accepted-close regression held an accepted option executor, closed the
listener, then released execution. Before the fix, `accept` returned a stream
and the expected-Closed assertion failed. Publication now checks listener state
under its lifecycle mutex, retains close on the failure path and closes the
unpublished socket. The retained regression passes.

## Compatibility and limits

Existing calls omitting new named parameters rebuild successfully in the full
suite and installed consumers. Four additional `SocketOption` variants break
old exhaustive matches: add the new cases or an intentional fallback. The
factory declaration shape changes; rebuild and relink consumers. No old-binary
or cross-SDK execution claim is made. External compat-test scenario PE01 is only
supporting classification; the task-specific two-archive compilation is the
Wirestack source proof.

SDK failures without a public native code remain Option/SystemFailure with
Unknown retryability and retained cause. No message parsing guesses errno.
IPv4 multicast interface readback remains Unsupported: the native address value
is not an interface-index contract. Buffer values may be clamped or adjusted by
the kernel. Bool and UInt8 domains exclude invalid values at compile time.

Native evidence is Linux x86_64 glibc with Cangjie 1.1.3 only. The receipt does
not qualify another platform, M8-007, a production release, signing or a soak.
Historical M9-001 and earlier receipts retain their own committed snapshots;
they are not rewritten as evidence for this task.

## Reproduction

Use the SDK archive digest in the SDK reference. Put that SDK's tools on PATH
and set `WIRESTACK_BASELINE_SDK_ARCHIVE` to its archive. Set `CJDOC_BIN` to the
SDK-compatible rebuilt cjdoc 0.7.2. Use the bounded-heap launcher from
[M9-001 reproduction](../M9-001/README.md#reproduction); apply `cjHeapSize=1GB`
only to cjdoc, never to the native consumers.

```sh
scripts/check-task M9-002 --json --output build/m9-002-task-check.json
```

The task manifest runs the scenario-plan validator, focused Cangjie/Python
checks, fresh installed-native qualification, strict native receipt validation,
`scripts/check`, and HTML documentation generation. SDK probes can be compiled
with `cjc docs/evidence/M9-002/sdk-probes/<probe>.cj -o <binary>` and executed under
`strace -f -e trace=setsockopt,getsockopt`; their exact executed commands are in
`sdk-probes.json`. Native archives remain ignored local verification artifacts
under `dist/m9-001/` and `dist/m9-002/`, not published releases.

The original working-tree qualification and raw logs are frozen source inputs.
The committed-candidate run writes separate `candidate/` evidence and checks the
source tree before and after execution. `evidence.json` is the canonical index;
`publication.json` records its candidate execution and authorization boundary.
The visual receipt retains `docs-option-name.webp.hex`; decode with
`bytes.fromhex` to recover the exact WebP image.
Do not start M9-003 or rewrite another task's status as part of this work.

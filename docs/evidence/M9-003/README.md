# M9-003 — UDP lifecycle

M9-003 adds UDP disconnect and IPv4/IPv6 multicast membership to the Linux StdNet transport. Acceptance is complete when [evidence.json](evidence.json) verifies against the exact source candidate. [publication.json](publication.json) records the candidate rerun. The source and evidence commits are local; this task does not include a push, pull request, merge or release. The original dirty workspace remains unchanged.

## Scope

- `disconnect(context:)` clears the connected peer, preserves the local bind and is idempotent. It excludes active send and receive operations. `sendTo` remains available after disconnect.
- `joinMulticastGroup` and `leaveMulticastGroup` support IPv4/IPv6 membership with an interface index and a 16-entry per-socket bound. Duplicate joins, unmatched leaves, invalid zones and full tables return structured errors. Close releases memberships.
- Multicast capability is true only for the natively qualified Linux x86_64 glibc StdNet backend. No other platform is claimed.

## Acceptance evidence

| Requirement | Evidence |
|---|---|
| Scenario coverage | [test-plan.md](test-plan.md); plan validation reports 7 paths, 7 scenarios and 4 tests. |
| UDP lifecycle transitions | `M9003UdpSocketTest` covers three public behaviors; `M9003StdNetUdpLifecycleTest` covers two adapter behaviors. |
| Installed native behavior | [native-udp.json](native-udp.json) records 18 passing Linux scenarios and the installed package digest. Raw consumer and syscall output is under [native-udp/](native-udp/). |
| Capability claims | [capabilities.json](capabilities.json) and [api-inventory.json](api-inventory.json) validate 86 capability/API rows against the native report. |
| API compatibility | [api-compatibility.json](api-compatibility.json) reports three added `UdpSocket` members and 325 unchanged declarations. Binary and forward compatibility were not run. |
| Repository regressions | [task-check.json](task-check.json) and [long-check.json](long-check.json). The full run passed 699 Python checks and 814 Cangjie cases; 23 Cangjie performance cases were skipped. |
| Public API documentation | [docs-report.json](docs-report.json) and generated API HTML. All 1,507 symbols and 739 parameters are documented. |
| Candidate rerun and seal | Candidate receipts and [publication.json](publication.json) bind the rerun to the committed source candidate. [evidence.json](evidence.json) is the canonical task index. |

The native qualification uses Cangjie SDK 1.1.3 on Linux x86_64 glibc. It does not qualify another operating system, CPU, libc or SDK. The API report is source-compatibility evidence only.

## Reproduction

Use the pinned toolchain recorded in [workspace.json](workspace.json). The cjdoc 0.7.2 bounded launcher and its setup are described in the [M9-002 reproduction notes](../M9-002/README.md#reproduction). The heap setting applies only to cjdoc.

Run the task-specific acceptance gates:

```sh
scripts/check-task M9-003 --json --output build/m9-003-task-check.json
scripts/check-long M9-003 --json --output build/m9-003-long-check.json
```

The committed-candidate native rerun writes separate receipts and raw output under `candidate/`; it must not modify the source inputs. The local package archive under `dist/m9-003/` is qualification output, not a release artifact.

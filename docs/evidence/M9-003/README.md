# M9-003: UDP disconnect, broadcast, and multicast

M9-003 qualifies UDP disconnect, IPv4 broadcast, and IPv4/IPv6 multicast membership against installed Linux consumers. The evidence index binds the acceptance reports to the committed source candidate. The user authorized a dedicated branch, source and seal commits, push, and pull request. Merge and production release are not authorized.

## Scope

- Disconnect clears a connected peer while retaining the local binding. A cancelled disconnect leaves the peer selected. Explicit `sendTo` remains available after disconnect.
- Active receive and send behavior preserves operation ownership, cancellation, and close semantics.
- Broadcast support is claimed only for qualified IPv4. IPv6 and unqualified targets report it as unsupported.
- IPv4 and IPv6 multicast membership paths have native evidence. Invalid family/address/index, duplicate membership, interface mismatch, bounded-table exhaustion, native failure, leave, and close cleanup are covered.
- The public API inventory, compatibility report, capability map, guide, and generated API documentation describe the same contract.

## Acceptance evidence

| Requirement | Evidence |
|---|---|
| Disconnect, cancellation, concurrent-operation, membership validation, and bounded cleanup | [test plan](test-plan.md), `M9003UdpLifecycleTest`, and `M9003UdpLifecycleAdapterTest` |
| Installed Linux contract | [native-udp.json](native-udp.json): all 18 installed scenarios pass on `linux-x86_64-glibc`, including `udp-disconnect`, `udp-broadcast`, `udp-multicast-ipv4`, `udp-multicast-ipv6`, `udp-membership-errors`, `udp-active-receive`, and `udp-active-send` |
| Capability and API correspondence | [capabilities.json](capabilities.json), [api-inventory.json](api-inventory.json), and [api-compatibility.json](api-compatibility.json) |
| Generated API and HTML | [docs-report.json](docs-report.json) and the committed `docs/api/generated` artifacts |
| Focused and repository acceptance | [task-check.json](task-check.json), [long-check.json](long-check.json), and the command logs under [commands](commands/) |
| Source freshness and publication boundary | [evidence.json](evidence.json), [verification.json](verification.json), [privacy.json](privacy.json), and [publication.json](publication.json) |
| Workspace isolation and prerequisite evidence | [workspace.json](workspace.json): current-main base, completed M9-002 prerequisite, preserved original workspace, and Linux x86_64 glibc toolchain |

The native report records 18 passing scenarios. No other operating system, architecture, libc, or SDK is qualified by this task.

## Reproduction

Use the Cangjie 1.1.3 SDK and cjdoc 0.7.2 recorded in `workspace.json`. Offline native qualification uses the clean AWS-LC checkout pinned by `native/tls/aws_lc/provider.json`. For Unix fixture runs, set `TMPDIR`, `TMP`, and `TEMP` to a short, disk-backed directory under `$HOME/.cache/agent-tmp`; the shared AF_UNIX fixture name must remain within Linux's 107-byte endpoint bound.

The native runner needs the Cangjie SDK archive pinned in `docs/references/m7-033-ci-toolchain.json` (`cangjie-sdk-linux-x64-1.1.3.tar.gz`, SHA-256 `2b68905afc466e665ae181595c63f96c18d75fd2c1fb6c6f0cb64e179c28d61a`). Set `CANGJIE_HOME` to the extracted SDK and `WIRESTACK_BASELINE_SDK_ARCHIVE` to the matching archive.

Separately, the task requires the qualified M7-021 baseline artifact at `dist/m7-021/wirestack-0.1.0-linux-x86_64-glibc.tar.gz`. Its SHA-256 is `c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`, recorded by the M7-025 bundle. Do not replace that fixture with an archive rebuilt from the M9-003 source candidate.

```sh
export WIRESTACK_BASELINE_SDK_ARCHIVE="$HOME/.cache/agent-tmp/wirestack-m9-003/cangjie-sdk-linux-x64-1.1.3.tar.gz"
scripts/check-task M9-003 --json --output docs/evidence/M9-003/task-check.json
scripts/check-long M9-003 --json --output docs/evidence/M9-003/long-check.json
```

Both reports must show `PASS`. The evidence records only the Linux x86_64 glibc qualification; it is not a release approval or merge authorization.

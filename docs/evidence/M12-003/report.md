# M12-003: STS native fault and resilience evidence
## Current source status

BLOCKED. Current source-bound campaign verification exits 1 because review fixes changed tools/gates/m12_003_network.py ([verifier log](current-source-verification.log)). The current Python contract suite ran 42 tests, 41 passed and one was skipped ([final log](review-contract-tests-final.log)). No native campaign has been rerun against the updated gates. Results below remain historical.

## Workspace and scope

One task: M12-003 / issue #184. Dependency M9-001 was COMPLETE with source-bound acceptance evidence before edits. `workspace.json` records the isolated task worktree, logical branch `m12-003-resilience`, physical `gitbutler/workspace`, HEAD `e023996a847a863bc52be20983139ff6d28d9625`, merge base `00d6864f8f5dee6a5c13a5a68144135e9e9601bc`, and 254 preexisting dirty entries. Those changes were preserved. No commit, push, PR, issue mutation, SDK build or upstream edit was performed.

Three subagents delivered independent resource, network and protocol/lifecycle slices. Integration adds the bounded campaign supervisor, complete coverage/binding verifier, task manifest and cross-environment evidence. Production sources and public APIs are unchanged.

Future SDK execution is STS-only. This task executed only the qualified STS 1.1.3 compiler/CJPM/runtime/std closure. Existing historical main/alpha SDK evidence remains historical, not a current execution target.

## Installed input

- Archive: `docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz`.
- Exact archive SHA-256: `e430f08ff8596b1c43c1d1090b5c42d721abac3c03505656b2aea107ee7a079f`.
- Payload SHA-256: `6f7e9d20f021ffb84fa91a8cf28f7a17488b8e3fa17e607975ed2af6d568ac3e`.
- 164 production inputs; selected build-time AWS-LC 5.5.0, commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a`.
- Compiler, CJPM, full runtime/std/import closure, native archives, source/probe digests and consumer binaries are bound in the selected family reports and `acceptance.json`.

## Native acceptance

| Slice | Historical execution | Result | Evidence |
|---|---|---|---|
| Resource limits/admission | Eight supported cgroup/FD/quota scenarios, plus typed negative 96-MiB allocation experiment; seed 184003 | Supported 8/8 PASS; negative runtime OOM classified, native exit 23 remains FAIL | `resources/final/report.json` |
| DNS/connect/transport | Twelve native scenarios, seeds 12003, 12004, 12005; own KVM guest and real qdisc/filter counters | 36/36 PASS | `network/native-guest/current/report.json`, `stress-12004/report.json`, `stress-12005/report.json` |
| Protocol/lifecycle/long streams | Thirteen scenarios ×20 rounds; seed 184003 | 260/260 PASS | `lifecycle/current-stress/report.json` |
| Shared supervision | Native STS compiler invocation and real timeout/cancel/exception/output-limit descendants | STS CLI PASS; cleanup contracts PASS | `supervision/sts-smoke.json`, `unit-tests.log` |
| Native network regressions | Actual packet loss and original-response retransmission, DNS and native peer modes | 4/4 PASS, 0 skipped | `network/native-guest/unit-tests.log` |
| Host behavioral suite | 37 discovered; packet regression unavailable on host | 36 PASS, 1 explicitly skipped | `unit-tests.log` |

Historical record: the task gate reported PASS for the original source inputs. That receipt is preserved byte-for-byte as an explicitly historical [task gate receipt](historical/task-gate-2026-10-09.json); it does not validate the updated gates, and no canonical `docs/gates/M12-003-task.json` is published. The current [task-gate disposition](verification.json) is BLOCKED because `tools/gates/m12_003_network.py` changed; no fresh native campaign validates the updated sources.

Native semantics cover distinct DNS deadline/late response, IPv6 blackhole with reachable IPv4, multi-candidate cancellation, real delay/loss, RST, silent disconnect, peer backpressure, new connections after fault removal, bounded resolver admission, HTTP/2 slow consumers/GOAWAY/per-stream isolation, SSE/WebSocket cancellation/disconnect, gzip rejection/recovery, cancellation storms and rotation/shutdown races. Public ledgers and observable resolver work return to zero. Native FD/tasks/RSS are sampled separately; RSS is not a logical ownership counter. Unobservable cancellation-registration, reserved-request and local H2-window counters remain UNAVAILABLE.

## Commands and actual outcomes

All commands selected `--sdk-root "$HOME/cangjie_sdk/sts1.1.3"` explicitly. Temporary outputs used unique disk-backed directories under `$HOME/.cache/agent-tmp`, with TMPDIR/TMP/TEMP set.

- `python3 tools/gates/m12_003_resources.py --sdk-root "$HOME/cangjie_sdk/sts1.1.3" --archive docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz --scratch <scratch>/resource-final --output docs/evidence/M12-003/resources/final --seed 184003`: exit 0, nine classified profiles; no pressure-process success or library-refusal claim.
- `python3 tools/gates/m12_003_lifecycle.py --sdk-root "$HOME/cangjie_sdk/sts1.1.3" --archive docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz --scratch <scratch>/lifecycle/current-stress --output docs/evidence/M12-003/lifecycle/current-stress --seed 184003 --mode stress --rounds 20`: exit 0, 260 PASS, wall 294.57 seconds.
- Guest `python3 tools/gates/m12_003_network.py --sdk-root "$HOME/cangjie_sdk/sts1.1.3" --archive docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz --scratch run-current-final --output network-current-final --seed 12003`: exit 0, twelve PASS after guest-only build prerequisites were installed. Run inside a private glibc 2.44 mount namespace; complete commands are retained by the family report.
- Same guest network command with `--reuse-build --seed 12004 --output network-current-stress-12004`, then seed 12005/output `network-current-stress-12005`: both exit 0, twelve PASS each; stop-on-error shell, no retry.
- Guest `WIRESTACK_NETWORK_PACKET_TESTS=1 python3 -m unittest tools.gates.tests.test_m12_003_network -v`: exit 0, four PASS, zero skipped, 0.856 seconds.
- Host `python3 -m unittest tools.gates.tests.test_m12_003_resources tools.gates.tests.test_m12_003_network tools.gates.tests.test_m12_003_lifecycle tools.gates.tests.test_m12_003_supervision tools.gates.tests.test_m12_003_campaign -v`: exit 0, 37 run/36 passed/one explicitly skipped. The guest executed the skipped packet path.
- `python3 tools/gates/m12_003_campaign.py run --sdk-root "$HOME/cangjie_sdk/sts1.1.3" --scratch <scratch>/campaign-host-native --output docs/evidence/M12-003/host-campaign --mode smoke --seed 120003`: exit 1. Resource and lifecycle families passed; network was BLOCKED on four missing-qdisc setup paths. All three supervisors reported zero live owned processes. This FAIL is retained, not relabeled PASS; native guest execution clears the required network coverage separately.
- `python3 tools/architecture_guard.py --root . --format text`: PASS after typed digest/path-domain corrections; no guard exemption added.
- `scripts/check-m7-032-public-api --json`: PASS, 363 public declarations, zero internal public aliases; not a historical compatibility claim.

## Isolation, retained failures and qualification limits

`network/native-guest/provenance.json` binds the Ubuntu Jammy cloud image, native KVM/kernel, private libc closure, SDK launcher, guest-only prerequisites and three current-source rounds. Consumer execution used glibc 2.44, not the guest base glibc 2.35. No host kernel module, shared network or unrelated VM was modified. The owned VM was stopped; launcher exit 0 and `cleanup.json` reports zero remaining live owned processes.

The 96-MiB diagnostic consumer catches public STS `OutOfMemoryError` by type, emits one structured marker and exits 23. Classification PASS is not supported operation, library ResourceExhausted refusal or in-process recovery. Kernel `oom_kill` counters, typed runtime OOM and unknown signal/nonzero exits remain distinct.

The original combined 25%-CPU/96-MiB 30,181-ms timeout remains FAIL in `resources/mixed-pressure-failure.json`; no recovery claim is made for that configuration. Earlier uncaught-memory observations, host packet prerequisites and lifecycle pre-fix build failures retain their original records and bindings. Later changed-source runs do not rewrite those failures.

The SDK exposed the real RST fixture through SystemFailure rather than a structured ConnectionReset code. Evidence records that result separately from EOF and deadline; no exception-message classification or production workaround was added. The synchronous SDK resolver boundary is explicitly measured as abandoned-but-running work with bounded admission, not falsely described as preemptible cancellation.

Task-level native coverage is not release qualification. Formal 86,400-second candidate soak, committed publication/signing, guest base glibc, and non-Linux platforms remain NOT_QUALIFIED/NOT_EXECUTED. M12-004 was not started. Next READY task: M12-004, with its existing release-evidence prerequisites intact.

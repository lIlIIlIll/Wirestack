# Linux resilience campaign

M12-003 exercises the verified installed public archive, not checkout-linked production code. Only explicitly selected, previously qualified STS SDK bytes are eligible. Current evidence uses STS 1.1.3; main, alpha and nightly SDKs are not execution targets. Historical multi-SDK evidence is unchanged.

## Run and verify

Create a unique disk-backed scratch directory with at least 2 GiB free. Use a Linux host or owned native VM with systemd user cgroup delegation, user/network namespaces, bubblewrap, and `sch_netem`, `sch_ingress`, `cls_flower`, `act_gact` support. Missing fault setup is BLOCKED, not a Wirestack PASS. Never change shared host routing, firewall rules or kernel modules to make a gate pass.

```sh
python3 tools/gates/m12_003_campaign.py run \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --scratch "$HOME/.cache/agent-tmp/<unique-campaign>" \
  --output "$HOME/.cache/agent-tmp/<unique-output>" \
  --mode smoke --seed 120003
```

The runner starts three bounded family subprocesses concurrently. Smoke runs one round; scheduled stress defaults to three distinct seed rounds. `--rounds` accepts 1–100. The first failed batch stops subsequent rounds; no automatic retry replaces failures. Each family has a 1,200-second supervisor deadline, bounded logs and an owned process group. Family-specific cleanup owns its namespaces, cgroups, peers and samplers. The supervisor covers ordinary descendants in that group, not arbitrary deliberately detached processes.

The families expose independent native entrypoints:

- [Resource limits and admission](linux-resource-fault-profiles.md): seven required coverage keys, eight supported scenarios and one separately classified negative memory experiment.
- [DNS, connection and packet faults](linux-network-fault-profiles.md): eleven required keys, twelve scenarios, actual packet counters and post-removal connections.
- [HTTP/2, lifecycle and long streams](linux-lifecycle-fault-profiles.md): seven required keys; peer-wire flow-control/GOAWAY/reset proof, stream interruption, cancellation storms and rotation/shutdown barriers.

`collect` accepts repeatable `--report family=relative/report.json` arguments for `resources`, `network`, and `lifecycle`. Split native environments and multiple stress rounds are allowed; each selected report must match the same archive, production payload and qualified STS closure. Coverage requires all 25 keys and rejects failed selected rounds, duplicate execution identities, contradictory semantics, missing cleanup and source drift. `--retained relative/failure.json` preserves historical failed diagnostics without relabeling them as passing executions.

```sh
python3 tools/gates/m12_003_campaign.py collect \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --report resources=docs/evidence/M12-003/resources/final/report.json \
  --report network=docs/evidence/M12-003/network/native-guest/current/report.json \
  --report network=docs/evidence/M12-003/network/native-guest/stress-12004/report.json \
  --report network=docs/evidence/M12-003/network/native-guest/stress-12005/report.json \
  --report lifecycle=docs/evidence/M12-003/lifecycle/current-stress/report.json \
  --retained docs/evidence/M12-003/resources/mixed-pressure-failure.json
python3 tools/gates/m12_003_campaign.py verify \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3"
scripts/check-task M12-003 --json
```

## Native evidence boundary

The current host could not apply packet faults: its running kernel did not have the required qdisc/classifier modules. The network slice therefore ran in a task-owned KVM guest, not a simulation. The Ubuntu Jammy cloud image is bound by SHA-256; the guest kernel is 5.15.0-198-generic. The selected consumer ran with the previously bound glibc 2.44 closure in a private mount namespace. This is **not** evidence that the consumer runs on the guest's base glibc 2.35. The copied STS SDK, archive, native archives and consumer are byte-bound; neither SDK nor provider source was edited.

Guest setup loads fault modules only inside that VM, uses 4 vCPUs/2 GiB memory, a bounded disk overlay and a loopback-only ephemeral SSH forward. Native reports record namespaces, applied qdisc/filter state, affected packets, recovery, native FD/tasks/RSS and cleanup. The VM supervisor's final record must report zero live owned processes.

The supported 512-MiB resource tier must complete without process OOM. The 96-MiB allocation experiment instead validates the runtime/kernel failure boundary: STS `OutOfMemoryError` is caught by type, emits one structured marker and exits 23. Its native outcome stays FAIL; diagnostic PASS is not library ResourceExhausted refusal, supported operation or recovery. The earlier combined 25%-CPU/96-MiB timeout remains a retained FAIL with no recovery claim.

Unavailable internal cancellation-registration, reserved-request and local HTTP/2 window counters stay UNAVAILABLE. RSS is an OS sample, not a logical live-object count. Public ledgers, resolver work, native handles and peer-wire observations provide the asserted boundaries.

## Formal qualification

Daily smoke and scheduled stress do not replace the frozen-candidate 86,400-second soak. M12-003 records `NOT_QUALIFIED` and does not run M12-004. Non-Linux platforms, the guest's base libc and a committed release candidate are not qualified by these results.

# M11-004 — Installed application acceptance

Task: [GitHub #181](https://github.com/lIlIIlIll/Wirestack/issues/181). Final status and source-bound results are recorded in [verification.json](verification.json). This task delivers applications against an extracted current-source package, not a signed or qualified release.

## Workspace and dependencies

[workspace.json](workspace.json) records the starting HEAD, merge base, physical GitButler workspace branch, task branch and all 226 pre-existing dirty entries. [initial-status.txt](initial-status.txt) preserves their normalized paths. No unrelated changes, upstream repository, SDK, commit, push, PR or issue was modified. [dependencies.json](dependencies.json) binds the COMPLETE evidence for all eleven required M9/M10/M11 dependencies before implementation.

## Deliverables

Four independently buildable CJPM executable projects cover the three requested categories:

- `examples/linux/m11_004/cli`: raw HTTPS/download command, explicit CONNECT proxy, one total budget and cancellation, bounded output and atomic publication.
- `examples/linux/m11_004/decoded`: explicit optional gzip variant; `--raw` and `--decoded` select transport bytes versus bounded decoded content. The base CLI does not import or link gzip, SSE or observability.
- `examples/linux/m11_004/streams`: bounded SSE, H2 sibling isolation and ws/wss commands; finite caller-directed recovery, parsed-cursor policy and no POST replay.
- `examples/linux/m11_004/service`: HTTPS upload/download and SSE service with bounded concurrency, resources, administrative input, live TLS generations and graceful drain.

Each manifest has exactly one package dependency, `../../install/wirestack`, and declares an executable project with minimum Cangjie version1.1.0. There is no SDK/provider handle, global checkout path, foreign import, `std.net` or `stdx` import in an application. A local filesystem is not a general server deployment framework.

[The operational guide](../../guides/installed-applications-linux.md) contains six byte-for-byte regions from the compiled projects. The [integration review](integration-review.md) records ownership, necessary boilerplate and public API gaps with links to their originating tasks. The public API inventory remains unchanged at363 entries; [public-api.json](public-api.json) is the executed check.

## Acceptance inventory

| Project | Native CHECK inventory | Additional behavior beyond the common terminal scenarios |
|---|---:|---|
| cli | 11 | Raw gzip33 bytes, exact CONNECT authority/SNI/authorization, partial-publication failure preserves an existing destination |
| decoded | 10 | Decoded gzip16 bytes, partial-publication failure preserves an existing destination |
| streams | 12 | Parsed cursor/duplicate delivery on explicit recovery, adversarial POST exactly once, actual bounded slow H2 consumer and surviving sibling, untrusted chain refusal |
| service | 14 | Actual server overload, untrusted chain refusal, ordinary TLS drain, security cancellation/required-mTLS rotation, shutdown pending until held exchange release |

The common scenarios in every project are success, pre-cancel, active cancellation, deadline, capacity refusal, peer disconnect, explicit close and terminal cleanup. The runner requires every named feature check exactly once and a single final acceptance marker; a missing feature cannot be hidden by passing only common scenarios.

Native self-checks are not the only runtime proof. The runner also starts the actual service through its stdin protocol, runs both operational download commands and checks exact8-byte output, exercises each CLI's real pre-cancel diagnostic/exit/output contract, runs operational SSE and WSS commands, and observes bounded stdin shutdown of both endpoints.

## Installed proof and platform boundaries

- [Default SDK report](installed/report.json): current-source archive, four fresh applications, exact source/package/binary/compiler digests, full normalized argv/cwd, exit results and actual stdout/stderr.
- [SDK1.1.3 report](installed-sdk113/report.json): separate native profile with its actual compiler digest and the same application contracts, plus fresh installed M9 socket-option and UDP consumer probes.
- The secondary profile runs socket options, HTTP option propagation and invalid-option refusal; UDP disconnect, broadcast, IPv4 multicast, IPv6 multicast, membership cleanup and active receive. Its IPv6 route exists only in a disposable user/network namespace.
- No previously published M9 report is substituted for a current installed run. Send-control/active-send delay-injection profiles and another-platform support are not claimed by these probes.
- `readelf` requires only the SDK/glibc C++ runtime allowlist; `nm` proves the base consumer has no optional modules while enabled consumers actually contain gzip/SSE symbols. The three pinned static native archives and every packaged file digest are checked before and after execution.
- Every build, help, native check and operational invocation sees an empty mount over the repository. Only that profile's own disk-backed scratch is writable. An explicit probe proves the checkout is empty.

## Current review evidence

[Review boundary tests](review-boundary-tests.log) pass 11 checks, including exact M9 mode markers. Separately, [the installed M9 review report](installed-review-m9/report.json) and per-mode logs record oversized custom-trust rejection in the cli, decoded and streams consumers. This is not release qualification.

## Canonical commands

Run in the corresponding SDK environment:

```sh
scripts/check-task M11-004 --json --output docs/evidence/M11-004/task-gate.json
python3 tools/m11_004_installed_consumers.py --validate-only
python3 tools/m11_004_installed_consumers.py --include-m9 --output docs/evidence/M11-004/installed-sdk113
```

The last command requires the already-qualified SDK1.1.3; it does not build or qualify an SDK. The task gate runs architecture and API checks, application/documentation contracts, package check, the new negative acceptance-gate tests alongside existing release/API regressions, and a fresh default-SDK installed execution. Exact invoked commands and results are retained in the reports.

Negative gates cover an escaping/global or second dependency, internal/transport/SDK imports, foreign/native override, default optional-module import, missing/tampered native archive, implicit system-library dependency, documentation drift/missing application, missing/duplicate acceptance scenarios and proxy worker cleanup. Tests use actual file inputs and digests rather than mock forwarding assertions.

## Preserved failure evidence

- [failed-install-layout.tar.gz](failed-install-layout.tar.gz): first fresh profiles rejected the versioned extraction directory instead of the required fixed dependency root. The runner now extracts through the existing archive machinery and renames only its own extracted directory.
- [failed-proxy-reset.tar.gz](failed-proxy-reset.tar.gz): the applications completed, but the inherited fixture treated an actual terminal native reset as a forwarding error. The task fixture now records EOF and reset separately through typed socket exceptions, without matching exception messages or changing production networking.
- [failed-sdk113-peer.tar.gz](failed-sdk113-peer.tar.gz) and [typed diagnostic/source capture](failed-sdk113-peer-diagnostic.tar.gz): SDK1.1.3 actual peer abort produced HttpException.ProtocolViolation. Acceptance now recognizes that typed failure without weakening the producer barrier, unpublished-output or zero-resource assertions.
- [readonly namespace failure](failed-readonly-namespace.tar.gz): user/network namespace creation must precede the readonly checkout sandbox so its uid map can be written.
- [loopback multicast failure](failed-loopback-multicast.tar.gz): the native receive timed out; an independent Python packet reproduced the kernel fixture failure. A private owned TAP interface delivers the real two-byte IPv6 multicast packet without host changes or module loading.

Logs are normalized to `<repo>`, `<scratch>`, `<sdk>`, `$HOME` and controlled documentation addresses/domains. Disposable certificate private keys and extracted package/build trees are not retained in the repository. The task scratch is removed only after useful evidence is published; no earlier task workspace or unrelated temporary directory is cleaned.

Historical M8-007 release blockers, production signing, security review, performance claims, long soak and non-Linux platforms remain outside this task. M12 tasks are not implemented here.

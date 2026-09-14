# M8-007 Linux release qualification

M8-007 qualifies the final Linux x86_64 glibc artifact after M8-001 through M8-006. Acceptance requires the frozen candidate's own 86,400-second soak, independent security review, and production signature verification.

## Qualification inputs

The dedicated reports below bind qualification to the artifact and source. Source corrections invalidate dependent reports; `verify-core` and `verify-fuzz` reject stale inputs before final acceptance.

- [Fresh native build](linux_x86_64/native-rebuild.json) records the TLS provider, resolver, and HTTP filesystem archives. The [complete build log](linux_x86_64/native-rebuild.log) and [executed driver](reproductions/native-rebuild-driver.py.txt) retain the build evidence.
- [Installation qualification](linux_x86_64/qualification.json) records two byte-identical package builds, a clean installed CJPM consumer, HTTPS behavior, and the complete consumer build and dynamic dependency output.
- [API inventory](linux_x86_64/api-inventory.json) compares the current declarations with the dedicated [M8-007 baseline](../../api/baselines/wirestack-linux-pre1-m8-007.json). It does not claim binary or semantic compatibility with a previous release.
- [Supply-chain bundle](linux_x86_64/supply-chain/bundle.json) binds the native dependencies, SPDX SBOM, provider metadata, and build fingerprint to the artifact.
- [License report](linux_x86_64/licenses.json) checks the packaged project license, third-party notices, AWS-LC license and notice, and Public Suffix List MPL-2.0 license against their source bytes.
- [Parser mutation campaign](linux_x86_64/fuzz-report.json) records all ten maintained targets and their source bindings. The campaign identifier remains `M7-023-LINUX-FUZZ`; `verify-fuzz` requires a matching M8-007 execution rather than a copied historical result.

## Reproductions

[Baseline controls](reproductions/baseline.json) reproduce the schema-2 SBOM self-validation failure and acceptance of a mutated resolver archive. [Fixed controls](reproductions/fixed.json) exercise their corrected behavior.

[The 600-second diagnostic](reproductions/cancel-diagnostic.json) completed 5,833 cycles with 730 connection cancellations. Its maximum cancellation latency was 8.485144 milliseconds. It is an incomplete preflight, not the final long gate. The earlier cancellation outlier remains in [the diagnostic record](reproductions/connection-cancellation-latency.json).

The initial [protocol review](security/initial-protocol-review.json) found a fixed-length request body-limit bypass. The [lifecycle review](security/initial-lifecycle-review.json) found three cleanup races or unbounded waits and literal soak ownership counters. The [TLS review](security/initial-tls-review.json) found no actionable issue in its assigned scope. These are source reviews, not formal-soak results.

The [body-limit regression](reproductions/http-fixed-limit-before.log) failed before the correction: 115 cases passed, three were skipped, and the new oversized-request assertion failed. The exact-boundary request remained accepted.

The [runtime controls](runtime-review-controls.json) reproduce all six targeted failures on the baseline and pass the complete corrected HTTP/1 and TLS suites. They also retain the corrected concurrent close/abort disposal case.

The [registration failure control](reproductions/tls-close-registration-before.json) records a seventh regression in the intermediate TLS correction. An already-cancelled token invoked a throwing abort callback before cleanup began, leaving the engine unreleased. The archived source and failing test output preserve that failure; the corrected complete TLS suite passes the same case.

The [owner controls](soak-owner-controls.json) reproduce acceptance of the old literal-owner schema, reject it with the corrected parser, and exercise weak-owner growth and terminal cleanup. The [current measured preflight](reproductions/measured-owner-preflight-corrected.json) records actual cycles, cancellation latency, resource trends, and terminal owners for the current artifact. It is not formal 24-hour evidence. The [review scope](security-scope.md#review-regression-evidence) explains retained failures and the distinction between weak-reference liveness and active ownership.

The [API command failure](reproductions/public-api-inventory-before-refresh.json) records an acceptance-command mismatch: the M7-032 validator received an M7-026-format release baseline. `verify-api` now validates the task's release baseline and report while retaining the existing public-alias ownership checks.

The [archive controls](archive-review-controls.json) reproduce seven failures on `14a9925dd78ded4f5d99eb8aa70c34f676404f3c` and pass with the bounded reader. They cover the 8 MiB member boundary, aggregate payload, decoded bytes, PAX metadata, member-header count, cumulative metadata fields, and sparse encodings. Rejected extraction does not create an installation.

The first formal run was stopped after the archive review. Its [interrupted capture](reproductions/formal-soak-14a9925/interrupted.json) is `INCOMPLETE`. Its elapsed time does not count toward the replacement candidate's 86,400 seconds.

The [signing policy](linux_x86_64/signing-authorization.json) records administrator-only signing-tag creation, blocked tag updates and deletion, and the sole release-owner reviewer for `m8-007-release`. Administrator bypass is disabled. The pre-soak capture contains no approved SHA.

The later `linux_x86_64/signing-approval.json` records the owner's independently selected full source SHA. `verify-all` rejects a different hosted source, missing archival inputs, removed source inputs, and changes to the approved task contract. The [publication controls](hosted-source-controls.json) reproduce six failures on `14a9925` and pass with the corrected verifier. Cryptographic verification is stubbed successful in the source-selection and archival controls; actual signatures remain a separate gate.

## Local commands

Use the configured Cangjie SDK and pinned native provider source on Linux x86_64 glibc. Run these commands from the repository root.

```sh
python3 tools/m8_007_final_release.py prepare
python3 tools/m8_007_final_release.py verify-core
```

`prepare` creates the artifact under `dist/m8-007` and refreshes the installation, API, SBOM, and license reports. `verify-core` checks those reports against the current artifact and source. Its `PASS` result does not qualify the separate soak, security review, or signature gates.

The formal soak uses the installed archive as its only Wirestack dependency. Its duration is 86,400 seconds. A preflight result, a previous task's soak, or an interrupted run cannot satisfy that gate.

## Publication sequence

1. Commit the qualified source and independent review as frozen candidate F. Run its own 86,400-second soak without changing frozen inputs.
2. Commit the completed formal output as signing source S. Select that real full SHA with `python3 tools/m8_007_signing_authorization.py approve-source --commit SHA`, then create its protected signing tag and approve the hosted jobs.
3. Retain the downloaded `release-manifest.json`, `artifact.sigstore.json`, `sbom.sigstore.json`, and `release-manifest.sigstore.json` under `linux_x86_64/signatures`. Add them to the task's `source_paths`.
4. Under `linux_x86_64`, also bind `frozen-candidate.json`, `soak.json`, `soak.log`, and both logs under `commands/formal-soak` in `source_paths`. The separate soak-command and hosted-attestation reports do not replace these raw files.
5. Finish acceptance and closure documentation, commit source plus complete reports as T, then create the evidence-only seal E. Preserve the exact candidate refs and verify a fresh full clone with tags.

The F-to-S and S-to-T task contracts permit additional source paths only. Existing inputs cannot be removed, and commands, required reports, dependencies, and timeouts cannot change. Frozen qualification inputs remain byte-bound throughout. Final planning status is sealed at T rather than falsely marked complete before signing.

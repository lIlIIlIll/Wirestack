# M7-030 test plan

## Semantics

M7-030 signs the exact Linux x86_64 glibc release artifact, its SPDX SBOM and
its release manifest. Verification binds each signature to the file bytes, the
release identity, the platform, the provider identity and the source release
bundle. A valid signature over the wrong file or an unsigned replacement must
fail.

The local release tool accepts an external OpenSSH Ed25519 key. It never creates
or stores a production key in the repository. Test and update rehearsals create
a temporary key inside a temporary directory and label every result
`REHEARSAL`. A GitHub-hosted release workflow uses GitHub OIDC and
`actions/attest` to generate the production Sigstore attestations. Local
rehearsal signatures cannot satisfy the hosted-attestation gate.

The update rehearsal validates a newer provider manifest and matching SBOM,
rejects an unsigned downgrade, accepts a rollback only with a signed rollback
authorization and records the security advisory. It does not claim that a
synthetic provider fixture is a released AWS-LC update.

## Control-flow path matrix

| Path ID | Conditions and values | Check | Reachability | Required result |
|---|---|---|---|---|
| P001 | M7-021 artifact and M7-025 bundle, SBOM and provider manifest match their recorded SHA-256 values | Input binding | Reachable | Continue |
| P002 | Artifact or M7-025 document is missing, stale or malformed | Input binding | Reachable error | FAIL |
| P003 | External Ed25519 private key matches the trusted public key and is outside repository output | Signing identity | Reachable | Continue |
| P004 | Key is missing, wrong type, mismatched or placed in release output | Signing identity | Reachable error | FAIL without printing key material |
| P005 | Canonical release manifest binds artifact, SBOM, provider manifest, build fingerprint, source bundle and signing policy | Manifest generation | Reachable | Deterministic manifest |
| P006 | Manifest has an unknown schema, unknown field, unsafe path, duplicate subject or inconsistent digest | Manifest validation | Reachable error | FAIL |
| P007 | Artifact, SBOM and release manifest each have a valid detached Ed25519 signature | Offline verification | Reachable | PASS |
| P008 | Signed subject or signature changes by one byte | Offline verification | Reachable error | FAIL |
| P009 | Report or signed output is published successfully or atomic replacement fails | Atomic writer | Reachable/error | Complete output or prior bytes preserved |
| P010 | Clean consumer verifies signatures and extracts only a safe archive | Consumer install | Reachable | PASS |
| P011 | Archive contains an absolute path, traversal, symlink escape or unexpected root | Consumer install | Reachable error | FAIL before extraction |
| P012 | Provider version and source digest advance and the SBOM records the same provider | Update policy | Reachable | Upgrade accepted |
| P013 | Provider manifest changes without the matching SBOM and advisory changes | Update policy | Reachable error | FAIL |
| P014 | Candidate provider version is lower than installed and has no signed rollback authorization | Rollback policy | Reachable error | FAIL |
| P015 | Lower version has a signed authorization bound to from-version, to-version, provider digest, advisory and expiry | Rollback policy | Reachable | Rollback accepted |
| P016 | Advisory is absent, expired, unsigned, severity-invalid or bound to another update | Advisory policy | Reachable error | FAIL |
| P017 | Test or rehearsal private key, fixture provider or synthetic update enters the default artifact | Payload boundary | Reachable error | FAIL |
| P018 | GitHub workflow uses exact action revisions and only a GitHub-hosted runner with `contents: read`, `id-token: write` and `attestations: write` | Hosted signing contract | Reachable | PASS |
| P019 | Hosted workflow attests the artifact, SBOM and release manifest and publishes bounded bundles | Hosted signing | Remote-only | PASS only with run evidence |
| P020 | Hosted attestation is absent, failed, from a self-hosted runner, another repository or another workflow | Hosted verification | Reachable error | BLOCKED or FAIL, never PASS |
| P021 | Signing or provider input changes after a prior report | Evidence freshness | Reachable | Prior report becomes STALE |
| P022 | Signing workflow depends on a Cangjie version that the hosted installer cannot resolve | Toolchain installation | Hosted failure | FAIL before signing; hosted signing must not depend on a compiler because it consumes the already frozen artifact |
| P023 | Signing workflow rebuilds and overwrites the frozen M7-021 artifact | Frozen subject binding | Hosted failure | M7-025 digest validation fails; remove the rebuild and attest only the exact reviewed artifact |
| P024 | Frozen artifact is absent from source checkout and must cross the hosted-runner boundary | Frozen asset retrieval | Reachable/hosted error | Download one exact draft Release asset by fixed tag, verify its fixed SHA-256, then validate the M7-025 bundle; missing, mismatched, latest or fallback selection fails closed |
| P025 | Read-only GitHub Actions token cannot see the unpublished draft Release | Hosted token boundary | Hosted error | A separate staging job gets only `contents: write`, downloads and checks the draft asset, then passes it to an attestation job that has no contents write permission; OIDC and draft-write permission never coexist in one job |
| P026 | `gh attestation verify` receives a relative signer workflow path | Hosted identity verification | Reachable/hosted error | FAIL; signer identity must be the exact `owner/repository/.github/workflows/file.yml` value for all three subjects |

## Input and state domains

| Domain | Partitions | Required behavior |
|---|---|---|
| Subject | artifact; SBOM; release manifest; provider manifest; unrelated file | Only the three declared release subjects require signatures; provider metadata remains digest-bound by the manifest. |
| Digest | exact lowercase SHA-256; uppercase; short; non-hex; mismatched | Only an exact 64-character lowercase digest is accepted. |
| Signing key | matching Ed25519; mismatched Ed25519; RSA; missing; repository path | Only the matching external Ed25519 key can sign. |
| Signature | valid; missing; truncated; wrong namespace; wrong identity; wrong subject | Only the exact identity, namespace and subject bytes pass. |
| Provider transition | newer; equal; lower; different identity; same version with different digest | Upgrade and rollback policy decides explicitly. No string guess or fallback is allowed. |
| Advisory | signed current notice; missing; expired; wrong update; unsupported severity | Only the signed notice bound to the transition is accepted. |
| Archive entry | regular file; directory; absolute path; `..`; symlink; hard link; second root | Only bounded files and directories below the one expected root are extracted. |
| Execution mode | local rehearsal; external-key offline release; GitHub OIDC attestation | Rehearsal is never promoted to production PASS. |
| Hosted artifact source | exact staging tag and digest; missing asset; wrong tag; wrong digest; latest or fallback lookup | Only the exact tag, asset name and SHA-256 may supply the frozen artifact. |
| Hosted token | staging contents write without OIDC; attestation contents read with OIDC; combined contents write and OIDC | Only the two isolated permission sets pass. The combined token is forbidden. |
| Signer workflow identity | exact owner/repository/path; relative path; another repository; another workflow | Only the exact full workflow identity passes. |

## State and side effects

- The tool reads the frozen M7-021 artifact and M7-025 sidecars. It does not
  rebuild the SDK, runtime, std or stdx.
- Signing writes to a temporary directory and publishes files atomically.
- The private key remains caller-owned. Reports contain only the public key
  fingerprint and signing scheme.
- A failed verification does not extract, install or replace the consumer's
  current version.
- An accepted upgrade changes the installed provider state only after every
  signature, digest, SBOM and advisory check passes.
- An accepted rollback requires a separate signed authorization. Re-running the
  same authorization is idempotent and cannot authorize another transition.
- The one-hour SSE profile and the 86,400-second soak are not part of this task.

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Current artifact and M7-025 documents | Clean output directory | P001,P005,P007 | Signed release bundle verifies | Three subjects, digests, identity and policy match | normal,supply-chain | P0 |
| S002 | Missing or stale artifact/SBOM/provider input | No output | P002 | FAIL | Stable input error and no partial final report | negative,supply-chain | P0 |
| S003 | Wrong or repository-resident signing key | Valid inputs | P003,P004 | FAIL | Key material is absent from output and diagnostics | security,negative | P0 |
| S004 | Unknown schema, extra field, unsafe subject path or duplicate subject | Signed or unsigned manifest | P006 | FAIL | Strict schema and path checks reject it | parser,negative | P0 |
| S005 | One-byte mutation of each subject and signature | Previously valid bundle | P007,P008 | FAIL | Each mutation is detected independently | security,regression | P0 |
| S006 | Injected final replace failure | Prior report exists | P009 | FAIL | Prior bytes remain unchanged | persistence,fault-injection | P1 |
| S007 | Clean consumer verifies and extracts the current artifact | Empty temporary consumer | P010 | PASS | Exact root, release manifest and public package are present | integration | P0 |
| S008 | Traversal, absolute, link or second-root archive entry | Empty temporary consumer | P011 | FAIL | No file is written outside the destination | security,negative | P0 |
| S009 | Synthetic newer provider and matching updated SBOM/advisory | Current version installed | P012 | PASS rehearsal | Provider, SBOM and advisory transition agree | update,rehearsal | P0 |
| S010 | Provider changes without matching SBOM or advisory | Current version installed | P013 | FAIL | Installed state remains unchanged | update,negative | P0 |
| S011 | Unsigned downgrade | Newer rehearsal version installed | P014 | FAIL | Monotonic policy blocks downgrade | rollback,negative | P0 |
| S012 | Signed, unexpired rollback authorization | Newer rehearsal version installed | P015 | PASS rehearsal | Exact from/to digests and advisory are checked | rollback,rehearsal | P0 |
| S013 | Missing, expired or mismatched rollback advisory | Newer rehearsal version installed | P016 | FAIL | Authorization cannot be reused for another transition | rollback,security | P0 |
| S014 | Test provider or private key added to payload | Candidate artifact | P017 | FAIL | Payload inventory contains neither item | supply-chain,negative | P0 |
| S015 | Pinned GitHub-hosted attestation workflow | Repository workflow | P018 | PASS static contract | Permissions, runner and immutable action SHAs are exact | CI,supply-chain | P0 |
| S016 | Hosted run generates three attestations | Merged release commit | P019 | PASS | Three Sigstore bundles verify against `lIlIIlIll/Wirestack` and the exact workflow | CI,remote | P0 |
| S017 | Hosted run or attestation evidence is missing or has another identity | Local implementation complete | P020 | BLOCKED or FAIL | Task cannot report production signing PASS | CI,negative | P0 |
| S018 | Signing policy, provider manifest, SBOM or workflow changes | Prior M7-030 evidence exists | P021 | STALE | Old PASS cannot be reused | evidence,regression | P0 |
| S019 | Configured Cangjie pin is absent from the setup action nightly index | Hosted workflow checked out | P022 | FAIL closed before attestations | No skipped signing step is recorded as PASS; final signing workflow has no compiler dependency | CI,negative,regression | P0 |
| S020 | Hosted workflow rebuilds the artifact with another toolchain or host | Frozen M7-021 artifact checked out | P023 | FAIL at M7-025 digest validation | Rebuilt bytes cannot inherit soak, SBOM or review evidence; final workflow validates and attests the checked-in frozen bytes | CI,supply-chain,regression | P0 |
| S021 | Source checkout lacks the ignored artifact, or hosted retrieval selects missing, latest, fallback or digest-mismatched bytes | Frozen artifact exists only in the draft Release | P024 | FAIL closed before supply-chain validation or attestations | Workflow downloads once by exact tag and name, checks the fixed SHA-256, then validates M7-025; no other asset is accepted | CI,supply-chain,negative | P0 |
| S022 | Read-only job queries the draft tag, or one job holds both contents write and OIDC | Unpublished draft Release | P025 | FAIL closed or static rejection | Staging and attestation permissions stay in separate jobs; both sides verify the fixed artifact digest | CI,permissions,security | P0 |
| S023 | Attestations exist but verification uses `.github/workflows/linux-release-attestation.yml` without repository identity | Three signed subjects | P026 | FAIL closed | All verification commands use `lIlIIlIll/Wirestack/.github/workflows/linux-release-attestation.yml`; relative or foreign identity is rejected | CI,identity,regression | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002 | P001,P002,P005 | Current and stale M7-025 fixtures | PASS/FAIL | Exact digest set and no partial output | unit,supply-chain |
| T002 | S003 | P003,P004 | Matching, mismatched, non-Ed25519 and repository keys | PASS/FAIL | Public fingerprint only; secret text absent | fault-injection,security |
| T003 | S004 | P006 | Unknown schema/field, duplicate and escaped path fixtures | FAIL | Stable validation codes | fault-injection,parser |
| T004 | S005 | P007,P008 | Mutate artifact, SBOM, manifest and each signature | FAIL | All six mutations are rejected | fault-injection,security |
| T005 | S006 | P009 | Injected `replace` failure | FAIL | Prior report remains byte-identical | fault-injection,persistence |
| T006 | S007,S008 | P010,P011 | Current and malicious tar archives | PASS/FAIL | Safe root extracted; unsafe entries write nothing | integration,security |
| T007 | S009,S010 | P012,P013 | Newer provider with matching and mismatching SBOM/advisory | PASS/FAIL rehearsal | Installed version changes only for matching set | update,rehearsal |
| T008 | S011,S012,S013 | P014,P015,P016 | Downgrade with no, valid, expired and mismatched authorization | FAIL/PASS rehearsal | Exact transition and expiry checks | rollback,rehearsal |
| T009 | S014 | P017 | Payload inventory with test provider and private-key patterns | FAIL | Default artifact remains production-only | supply-chain,negative |
| T010 | S015 | P018 | Workflow static contract | PASS | Hosted runner, minimal permissions and immutable action revisions | unit,CI |
| T011 | S016,S017 | P019,P020 | GitHub attestation run and absent/wrong identity reports | PASS/BLOCKED/FAIL | Three verified subjects and exact repository/workflow identity | remote,CI |
| T012 | S018 | P021 | Source digest mutation | STALE | Evidence verifier names the changed path | evidence,regression |
| T013 | S001,S005 | P005,P007,P008 | End-to-end temporary Ed25519 key rehearsal | PASS | Artifact, SBOM and manifest verify; tampered copy fails | integration,rehearsal |
| T014 | S007,S009,S012 | P010,P012,P015 | Clean consumer install, upgrade and rollback sequence | PASS rehearsal | Version history, provider identity and SBOM digest are exact | integration,rehearsal |
| T015 | S015,S019 | P018,P022 | Hosted workflow with compiler installer injected | FAIL | Static contract rejects `setup-cangjie`; unavailable installer run is retained as failed evidence only | CI,regression |
| T016 | S015,S020 | P018,P023 | Hosted workflow with release rebuild command injected | FAIL | Static contract rejects artifact regeneration and requires supply-chain validation before attestation | CI,supply-chain,regression |
| T017 | S015,S021 | P018,P024 | Wrong tag, digest, latest selector and download/validation order injected into hosted workflow | FAIL | Static contract binds one exact draft asset retrieval and requires digest check before supply-chain validation | CI,supply-chain,fault-injection |
| T018 | S015,S022 | P018,P025 | Inject OIDC into staging job or contents write into attestation job | FAIL | Static contract requires two jobs, isolated permissions and SHA-256 checks before and after bounded transfer | CI,permissions,fault-injection |
| T019 | S016,S023 | P019,P026 | Replace full signer workflow identity with a relative path | FAIL | Static contract requires the exact repository-qualified identity three times; published artifact bundle verifies with that identity | CI,identity,fault-injection |

## Coverage and gap review

The local suite proves the offline signing format, clean-consumer verification,
tamper rejection and update policy. It uses only temporary test keys and
synthetic provider metadata. It does not claim a real AWS-LC upgrade.

Production completion requires a GitHub-hosted run from the release workflow.
The run must publish and verify Sigstore attestations for the exact artifact,
SBOM and release manifest. Until that report exists, M7-030 remains INCOMPLETE
even if every local rehearsal passes.

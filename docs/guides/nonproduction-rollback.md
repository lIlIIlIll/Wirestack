# Rehearse an exact non-production rollback

Use `tools/m12_004_rollback.py` to authenticate the original release, build a clean installed consumer with STS 1.1.3, and reject replacement unless a fresh security disposition permits those exact bytes. This command does not qualify the M12-004 upgrade candidate or authorize production signing.

The recorded rehearsal is **BLOCKED**. Archive authentication, original formal acceptance bindings, and the new STS consumer probe passed. The deployment stayed unchanged because no fresh signed security disposition authorizes the original archive. The current HPACK availability finding must not be ignored just because historical signatures verify.

## Prerequisites

- Python 3, `gh` with attestation verification support, `ssh-keygen`, `readelf`, and repository tooling.
- The selected STS SDK at `$HOME/cangjie_sdk/sts1.1.3` and `$HOME/.codex/scripts/codex_cangjie_env`. Do not execute the historical alpha SDK.
- A private directory on disk-backed storage. Check `df -T "$HOME/.cache"` and free space first. Do not put build output on a tmpfs.
- Original release evidence, not the current replacement qualification. The original public artifact has SHA-256 `5896572753484b3f64903b2b4ccc4f0f471ddab33ef034f5c3b1bb1c3d509669`, size 2,805,219 bytes, and original payload SHA-256 `cb7e11e7caafc85bfc669b06c7f1951680bce46419433a2b7b56d0549f170008`.

## 1. Retrieve the unchanged archive and original evidence

Run from the repository root. The source snapshot is now reachable at the original commit, despite the earlier identity audit's missing-source observation.

```sh
WORK=$(mktemp -d "$HOME/.cache/agent-tmp/wirestack-rollback.XXXXXXXX")
chmod 700 "$WORK"
export TMPDIR="$WORK" TMP="$WORK" TEMP="$WORK"
REPO=lIlIIlIll/Wirestack
SOURCE=2fcaac47f0ad75b87d73235810f6b096a1a2157e
SIGNER=ffd6551656ef990591dbd3bb9c67e6720588dd15
ARCHIVE=wirestack-0.1.0-linux-x86_64-glibc.tar.gz
gh release download m8-007-frozen-artifact-58965727 \
  --repo "$REPO" --pattern "$ARCHIVE" --dir "$WORK"
gh api "repos/$REPO/tarball/$SOURCE" > "$WORK/original-source.tar.gz"
mkdir "$WORK/source"
tar -xzf "$WORK/original-source.tar.gz" -C "$WORK/source" \
  --strip-components=1 --no-same-owner
```

Do not rebuild the archive. Do not substitute draft release assets, today's qualification, or the signing approval from the replacement candidate. The CLI checks archive bytes against the signed qualification, every signed `qualifiedInputs` digest, source inventory, and production source bytes against the archive. It verifies artifact, SBOM, and release-manifest Sigstore bundles using the original repository/workflow/source/signer identity and rejects self-hosted runners.

M8-007 uses Sigstore, not M7's SSH bundle format. The command retains the existing M8 `gh attestation verify` contract and M7 release-manifest validation. It uses the existing offline `verify_file` verifier for security authorization and `atomic_bytes`/`atomic_json` for deployment. It does not rewrite M8 bundles into test-key SSH signatures or weaken `verify_offline_bundle`'s M7 task/workflow checks.

## 2. Prepare only a task-owned deployment

The deployment is an artifact-store rehearsal, not a running production service. Readers resolve `current.json` to `versions/<sha256>/artifact.tar.gz`. All writers must take `.rollback.lock`. The pointer replacement is atomic; the old archive and pointer bytes remain available.

The following initializes only the private deployment with the exact M12-004 upgrade candidate. This artifact-store setup is not release qualification or production deployment.

```sh
CANDIDATE=bb12abafb87ffe60b3e3adbdf4c1ac6ea7f8da47a7a5ad8a2df58b9e8981556d
DEPLOY="$WORK/deployment"
mkdir -p "$DEPLOY/versions/$CANDIDATE"
cp docs/evidence/M12-004/upgrade/candidate.tar.gz \
  "$DEPLOY/versions/$CANDIDATE/artifact.tar.gz"
printf 'M12-004\n' > "$DEPLOY/.wirestack-nonproduction"
printf '%s\n' \
  "{\"artifact\":{\"domain\":\"artifact-bytes-v1\",\"sha256\":\"$CANDIDATE\"},\"version\":\"$CANDIDATE\"}" \
  > "$DEPLOY/current.json"
```

For another authorized candidate, retain its exact archive and set `CANDIDATE` to its byte digest. The CLI compares both pointer and stored bytes before replacement. It refuses deployments outside `WORK`, missing private markers, candidate drift, or overwriting an existing rollback version.

## 3. Exercise authentication, STS compatibility, and rejection

This invocation intentionally omits security authorization. It must not replace the deployment.

```sh
python3 tools/m12_004_rollback.py \
  --artifact "$WORK/$ARCHIVE" \
  --history-root "$WORK/source" \
  --qualification "$WORK/source/docs/evidence/M8-007/linux_x86_64/qualification.json" \
  --signing-commit "$SIGNER" \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --work-root "$WORK" --deployment "$DEPLOY" \
  --candidate-sha256 "$CANDIDATE" \
  --output "$WORK/rehearsal.json" --restore
```

The observed exit code was 1, with `status=BLOCKED`, `qualification=NOT_QUALIFIED`, `restore=NOT_RUN`, and `deployment_unchanged=true`. The blocker was `SECURITY_DISPOSITION_MISSING`. The original source-with-native-archives package built and ran the existing public release consumer under explicitly selected STS 1.1.3. The native dependency scan reported only the Cangjie runtime, boundscheck, libc, and libm. That is an artifact-bound API/native compatibility probe, not fresh performance, matrix, fuzz, independent-review, or 86,400-second qualification for the upgrade candidate.

## 4. Obtain security acceptance before requesting restore

The security gate owner must review current advisories against this exact archive. Historical release approval is not a present-day security decision. In particular, consult `docs/evidence/M8-007/security/hpack-cost-triage.json` and both current requalification reviews. Do not issue an allowance while affected release blockers remain open.

The CLI accepts a UTF-8 JSON disposition plus its original adjacent `.sig` SSH signature. An authorized security authority signs in the existing `wirestack-release` namespace. Obtain the authority public-key byte digest independently; never derive trust from a key shipped beside an artifact.

Required disposition fields:

| Field | Required value |
| --- | --- |
| `schema_version`, `purpose`, `decision` | `1`, `nonproduction-rollback`, `ALLOW` |
| `artifact` | Exact `artifact-bytes-v1` digest from the rehearsal |
| `qualification` | Exact signed `text-utf8-lf-v1` qualification digest |
| `candidate_sha256`, `signing_commit` | Exact currently installed candidate and original signer commit |
| `issued_at`, `expires_at` | UTC timestamps, currently valid, interval no longer than 86,400 seconds |
| `advisory_review_complete` | `true` after the security owner completes current review |
| `current_review_inputs` | Exact path-to-typed-text-digest mapping from `security_requirements()`: historical reviews/HPACK triage, initial and final M12 review, fresh intake inventory and every preserved official response |
| `advisories` | Records with `id`, `disposition` and supporting `evidence`; cover every unresolved finding, review coverage gap and returned raw public GHSA ID |

Only `not_affected` or `remediated` dispositions are accepted. `risk_accepted`, omitted findings/gaps/public advisories, stale review/response digests, unavailable channels, intake older than 24 hours, unsigned reports, or altered signed bytes fail closed. Remediation claims must describe the exact old bytes, not fixes present only in newer source. Response hashes and timestamps bind the preserved retrieval record; they do not independently authenticate the retrieval or prove a signed assertion truthful. An independently authorized security authority must assess those facts.

Once the security owner has supplied genuine acceptance, repeat step 3 with these additional arguments, keeping `--restore`:

```sh
--security-disposition "$DISPOSITION" \
--security-key "$SECURITY_PUBLIC_KEY" \
--security-key-sha256 "$INDEPENDENTLY_PINNED_KEY_SHA256"
```

The CLI stages exact archive and original signature sidecars in a new immutable version, saves `previous-current.json`, and atomically replaces `current.json` only after every gate passes. Do not point production at this store. No actual eligible historical restore was performed in the recorded rehearsal.

## Evidence and regression controls

`docs/evidence/M12-004/rollback/rehearsal.json` preserves the initial baseline-store rehearsal. `final-candidate-refusal.json` records the final upgraded store, current driver source digest, original authenticated release, STS consumer PASS, actual CLI exit 1 and unchanged pointer/archive bytes. `retrieval.json` retains immutable public locations and original evidence digests. `tests-initial.json` preserves the initial tests; refreshed `tests.json` records 14 rollback cases within the 80-case combined integration invocation. Controls use real disposable SSH signatures for tampering, stale policy, omitted findings/gaps/public advisories and official-response drift; deployment tests cover candidate drift, exact archive/sidecar preservation and CLI refusal. The failing-before advisory-omission log is retained under `integration/`. Unit-test keys and artificial archive bytes are test-only and never qualify a production rollback.

Keep the downloaded originals while the blocker is investigated. Delete only your own `WORK` when the evidence is no longer needed. Never bulk-clean another task's scratch directory.

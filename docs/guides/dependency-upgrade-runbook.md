# Rehearse a dependency upgrade without promoting it

M12-004 selects AWS-LC 5.11.0 for an isolated Linux x86_64 glibc rehearsal. The accepted production pin remains AWS-LC 5.5.0. Neither a successful build nor a signed historical release qualifies this candidate or authorizes production signing.

Use only an explicitly selected STS SDK. This rehearsal uses the already qualified STS 1.1.3 compiler/runtime/import closure. Main, nightly, alpha and development SDKs are excluded.

## 1. Select and review exact inputs

Before changing dependencies:

1. Record branch, HEAD, target merge base, dirty paths, SDK identity and native platform. Preserve unrelated changes.
2. Inventory provider, resolver, filesystem, PSL and optional compression from the exact installed archive. Record source revisions, patches, licenses/notices, declared and defined symbols, native archives, SDK bytes and build inputs. Optional gzip is pure Cangjie and is selected by explicit import; do not add a system zlib dependency.
3. Retrieve the official release and advisory channels. Record unavailable responses and pagination limits. An empty page or a numerically newer version is not a security clearance.
4. Resolve the public upstream tag to its exact commit/tree. Review the complete changed-path inventory and relevant crypto, certificate, assembly, ABI and build changes. Preserve unreviewed areas as gaps; do not claim a complete crypto audit from selected hunks.
5. Record the selected pin in `docs/references/m12-004-aws-lc-upgrade.json`. Keep the accepted provider manifest and ADR pin unchanged during the rehearsal.

The selected tag resolves to commit `fa9bc8d6f7cfb2cf849b247fb06bbbfc41ecc9d6`, tree `e9d52ead35793426b465d4ec694e34d4ee9a6d5e`. Its source-content identity hashes commit, LF, tree, LF; it is not a tarball-byte digest. No local provider patches are selected. Public tag resolution was checked; a cryptographically signed tag was not established.

## 2. Build and exercise the isolated candidate

Check the scratch filesystem and free space. Create task-owned mode-0700 storage under a disk-backed `$HOME/.cache/agent-tmp`; do not use tmpfs for the build. The checkout must contain the exact selected clean upstream source. The build command requires a new work directory outside Wirestack.

```sh
WORK=$(mktemp -d "$HOME/.cache/agent-tmp/wirestack-upgrade.XXXXXXXX")
chmod 700 "$WORK"
export TMPDIR="$WORK" TMP="$WORK" TEMP="$WORK"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git clone --filter=blob:none --single-branch --depth 1 --branch v5.11.0 \
  https://github.com/aws/aws-lc.git "$WORK/aws-lc"
python3 tools/m12_004_upgrade.py \
  --source-dir "$WORK/aws-lc" \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --work-root "$WORK/build"
```

The driver reuses the existing static provider builder, release archive collector and SPDX generator. It verifies the exact source and qualified STS closure, rebuilds the shim/provider, packages the existing production modules and unchanged resolver/filesystem archives, copies the selected upstream license, and refreshes the isolated package's provider notice identity. It does not rewrite the production notice or copy an arbitrary provider checkout into the repository.

The native probe checks ABI version, random output, provider version, source identity and keylog refusal. The installed public consumer builds and executes HTTPS/HTTP2 with the Wirestack checkout hidden. `readelf` must show no implicit `libssl` or `libcrypto` dependency. Report commands retain exit status, timeout/completion and owned-process cleanup results.

Outputs are under `docs/evidence/M12-004/upgrade/`: exact candidate archive, native/input/SDK identities, normalized consumer logs and newly generated supply-chain documents. `status=PASS` means the stated rehearsal passed. `qualification=NOT_QUALIFIED` remains mandatory.

## 3. Run fresh candidate-bound checks

```sh
python3 tools/m12_004_inventory.py \
  --artifact docs/evidence/M12-004/upgrade/candidate.tar.gz \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --selected-version 5.5.0 \
  --output docs/evidence/M12-004/inventory/candidate
python3 tools/m12_004_verifier_controls.py \
  --scratch-parent "$WORK" \
  --native-artifact docs/evidence/M12-004/upgrade/candidate.tar.gz \
  --output docs/evidence/M12-004/verifier-controls/candidate-verification.json
```

Run the installed candidate TLS, full unchanged fuzz campaigns and paired performance driver as described in [candidate dependency gates](candidate-dependency-gates.md). Use the same STS closure and fresh session for baseline/candidate comparisons. Record noisy or failing comparisons as such. Do not substitute old M12-001 performance or M12-002 matrix results for this archive.

The additional advisory-review version is 5.5.0; the artifact itself supplies 5.11.0, so both official tag channels are retained. The [release rejection controls](release-verifier-rejection-controls.md) must reject archive/SBOM replacement, missing or wrong signatures, wrong source/repository policy, stale reports, keylog capability and native archive drift. Their disposable `TEST_ONLY` signatures exercise the existing offline verifier; they do not emulate production GitHub OIDC attestations.

## 4. Assess semantics, ABI and recompilation separately

Wirestack ABI-v1 function signatures and the public Cangjie API are unchanged by the identity correction. Runtime version and source identity now come from the selected build rather than hardcoded 5.5.0 constants. A dependency change still requires rebuilding static native archives and relinking/recompiling consumers. A same-signature ABI probe is not an exhaustive upstream ABI or semantic guarantee.

For installed-source/CA/relocation checks, use the existing `tools/m12_002_source_sdk.py` with the exact new archive, an explicit STS root and the accepted STS installed-consumer compiler report. That prior report authorizes the compiler only; runtime/import/native/package bytes and behavior must be freshly measured. Native minimum CPU/kernel/libc cells and independent TLS coexistence also need this candidate's own captures. Failed or unavailable cells are not supported platforms.

## 5. Qualify or stop

Every candidate needs its own source seal, consumer evidence, accepted performance, native matrix, complete fuzz coverage, independent review and full 86,400-second soak. Short preflights cannot replace that soak. Source, provider, toolchain, build flags, native archives, notices or artifact changes invalidate affected reports and signatures. Regenerate them; do not edit timestamps or copy verdicts.

Do not promote a candidate with open release-blocking security findings. An AI process-isolated review is not independent human approval or a full upstream cryptographic audit. Production signing requires separate explicit authorization, original trusted identity constraints, and fresh exact-subject attestations.

Emergency upgrades use the same trust boundaries: select a minimal reviewed change, rerun affected consumer/security/protocol/ABI checks, regenerate fingerprints and SBOM, and obtain the required review, authorization and soak. Urgency does not permit fallback providers, relaxed signatures, old report reuse, or an unsigned default downgrade.

## 6. Rehearse exact rollback or retain the candidate

Follow [non-production rollback](nonproduction-rollback.md). Retrieve the original immutable artifact and its original source, SBOM, attestations and approval. Never rebuild an approximation or resign it with test keys. A fresh signed security disposition must cover these exact old bytes, all current findings/coverage gaps and every returned public advisory, with all final review/intake digests bound. Historical approval is not current security acceptance.

If security acceptance is missing or unresolved, exit nonzero, preserve the candidate pointer and exact bytes, and retain failure evidence. Diagnose missing native dependencies, ABI/runtime incompatibility, TLS policy or certificate changes before retrying. No implicit provider or system-OpenSSL fallback is permitted.

## Release checklist

- [ ] Exact baseline/candidate source, provider, native archives, SDK and selected build flags recorded; no unreviewed patches.
- [ ] License, notice, PSL and optional-module inventories agree with packaged bytes and regenerated SPDX.
- [ ] Runtime version/source identity agree with the selected provider manifest.
- [ ] Clean installed consumer, affected protocol/security checks and declared public ABI checks pass.
- [ ] Complete candidate fuzz, accepted paired performance and candidate-native matrix evidence pass.
- [ ] All release-blocking review findings and coverage gaps resolved for these exact bytes.
- [ ] Committed source and complete 86,400-second candidate soak bound; no stale or borrowed reports.
- [ ] Production signing separately authorized; original workflow/source/signer constraints retained.
- [ ] Rollback old artifact currently security-acceptable and STS-compatible; exact original signatures retained.
- [ ] Non-production deployment changes only after every rollback gate; refusal leaves bytes and active pointer unchanged.

Unchecked items keep M12-004 BLOCKED. The [task evidence](../evidence/M12-004/README.md) distinguishes executed rehearsal proof from unmet release qualification.

# Native dependency inventory

`tools/m12_004_inventory.py` inventories an existing Linux package. It uses the M7-025 supply-chain reader, validation rules, license inventory and SPDX package identifiers. It does not generate a second SBOM, approve an upgrade, qualify a candidate, or authorize signing.

## Run the inventory

Use the selected STS SDK explicitly. Use disk-backed scratch with private permissions.

```sh
scratch=$(mktemp -d "$HOME/.cache/agent-tmp/inventory.XXXXXX")
chmod 700 "$scratch"
export TMPDIR="$scratch" TMP="$scratch" TEMP="$scratch"
python3 tools/m12_004_inventory.py \
  --artifact docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --output docs/evidence/M12-004/inventory/current
python3 -m unittest tools.tests.test_m12_004_inventory
rmdir "$scratch"
```

The CLI accepts `--artifact` for the candidate's own package after its build. Pass `--source-root` when its six native shim and bridge source files live in a separate authorized checkout. `--selected-version` sets the release tag queried alongside the embedded baseline version and defaults to `5.11.0`. No production pin changes are made.

The report binds exact archive bytes and verified payload bytes, all packaged Cangjie sources, the six native source files, the inventory implementation, licenses and notices. Provider source revision, tree, content fingerprint, patches and patch level come from the embedded native build manifest. This is an inventory of declared upstream provenance, not independent upstream source authentication. The controlled upgrade must verify that provenance separately.

Provider, resolver and filesystem archives are inspected with `nm`. Exported Wirestack symbols must match their packaged public headers exactly. Undefined native compression symbols are rejected. The optional gzip module must retain explicit import selection, the pure Cangjie implementation identifier, no native dependencies, and a complete source list matching packaged code digests. PSL source bytes and MPL-2.0 license bytes are validated using M7-025 conventions.

A small C consumer links the exact three packaged native archives and runs ABI version checks, provider creation and secure random, keylog rejection, resolver pool lifecycle and filesystem invalid-argument handling. This bounded smoke is not the full consumer, performance, matrix, fuzz, independent security review or 86400-second soak qualification.

The STS wrapper executes `cjc --version` and `cjpm --version`. Compiler, CJPM, runtime, standard native archives and import metadata are fingerprinted. This records the SDK actually used for this inventory. A source package does not prove which SDK originally built every native dependency or qualify a later candidate against that SDK.

## Advisory intake

The CLI queries official AWS-LC latest and version-specific release endpoints, the repository security advisories endpoint, its SECURITY.md policy and AWS security bulletins. Each query has a 25-second timeout and a 2 MiB response limit. Official response bodies, typed text digests, intake timestamps, HTTP status and unavailable-channel errors are retained under the output directory.

The captured current run returned five public GitHub advisories and release metadata for v5.5.0 and v5.11.0. All six queried channels responded. The advisory version ranges use AWS-LC 1.x and FIPS version labels. Both selected version applicability assessments remain unknown until version lineage and ranges are reviewed. A version number comparison alone does not establish safety. The advisories response is only the first page; private, unpublished and later-page findings remain unknown. The AWS bulletin page is intake material, not a complete machine-readable AWS-LC vulnerability feed.

`status: PASS` means the bounded inventory and native smoke completed. Every report says `qualification: NOT_QUALIFIED`. Missing advisory responses are recorded as unknown, never safe. Use the existing release verifier and qualification gates before any release or rollback decision.

## Evidence and rejection tests

`docs/evidence/M12-004/inventory/current/inventory.json` preserves the pre-upgrade baseline snapshot; it is not a post-edit validation of today's native source. The final 5.11.0 archive has its own `inventory/candidate/inventory.json`, with 5.5.0 as the additional advisory-review version so both release channels are captured. Initial advisory-lineage fields remain unknown in the collector; the separate independent review records source assessment without claiming exhaustive clearance. Refreshed `current/tests.json` records 11 inventory cases within the combined integration run; `tests-initial.json` preserves the initial invocation. Tests isolate six source fixtures with matching embedded manifest digests, then reject actual archive replacement, native source drift, PSL byte/license drift, changed or unlisted gzip source, native gzip dependencies, missing/added public symbols, keylog enablement and NOTICE mismatch. Production inventory still compares the selected archive against the real supplied source root.

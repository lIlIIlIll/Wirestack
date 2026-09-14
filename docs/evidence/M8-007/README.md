# M8-007 Linux release qualification

M8-007 qualifies the final Linux x86_64 glibc artifact after M8-001 through M8-006. The task remains open until the frozen candidate completes its own 86,400-second soak, independent security review, and production signature verification.

## Completed checks

- [Fresh native build](linux_x86_64/native-rebuild.json) records the TLS provider, resolver, and HTTP filesystem archives. The [complete build log](linux_x86_64/native-rebuild.log) and [executed driver](reproductions/native-rebuild-driver.py.txt) retain the build evidence.
- [Installation qualification](linux_x86_64/qualification.json) records two byte-identical package builds, a clean installed CJPM consumer, HTTPS behavior, and the complete consumer build and dynamic dependency output.
- [API inventory](linux_x86_64/api-inventory.json) compares the current declarations with the dedicated [M8-007 baseline](../../api/baselines/wirestack-linux-pre1-m8-007.json). It does not claim binary or semantic compatibility with a previous release.
- [Supply-chain bundle](linux_x86_64/supply-chain/bundle.json) binds the native dependencies, SPDX SBOM, provider metadata, and build fingerprint to the artifact.
- [License report](linux_x86_64/licenses.json) checks the packaged project license, third-party notices, AWS-LC license and notice, and Public Suffix List MPL-2.0 license against their source bytes.
- [Parser mutation campaign](linux_x86_64/fuzz-report.json) reruns all ten maintained targets on the current source. The campaign identifier remains `M7-023-LINUX-FUZZ`; this file is a new execution, not a copied historical result.

## Reproductions

[Baseline controls](reproductions/baseline.json) reproduce the schema-2 SBOM self-validation failure and acceptance of a mutated resolver archive. [Fixed controls](reproductions/fixed.json) exercise their corrected behavior.

[The 600-second diagnostic](reproductions/cancel-diagnostic.json) completed 5,833 cycles with 730 connection cancellations. Its maximum cancellation latency was 8.485144 milliseconds. It is an incomplete preflight, not the final long gate. The earlier cancellation outlier remains in [the diagnostic record](reproductions/connection-cancellation-latency.json).

## Local commands

Use the configured Cangjie SDK and pinned native provider source on Linux x86_64 glibc. Run these commands from the repository root.

```sh
python3 tools/m8_007_final_release.py prepare
python3 tools/m8_007_final_release.py verify-core
```

`prepare` creates the artifact under `dist/m8-007` and refreshes the installation, API, SBOM, and license reports. `verify-core` checks those reports against the current artifact and source. Its `PASS` result does not qualify the separate soak, security review, or signature gates.

The formal soak uses the installed archive as its only Wirestack dependency. Its duration is 86,400 seconds. A preflight result, a previous task's soak, or an interrupted run cannot satisfy that gate.

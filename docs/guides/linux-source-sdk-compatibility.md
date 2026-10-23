# Rebuild an installed package with a selected Linux SDK

Use the same development archive to build independent consumers with each selected Cangjie SDK. This proves source compatibility and public behavior for those exact SDK bits. It does not prove that a precompiled executable can use another SDK runtime.

## Prerequisites

- Linux x86_64 glibc, Cangjie compiler and matching CJPM/runtime from one SDK installation.
- Python 3.11 or newer, Bubblewrap, `readelf`, `findmnt`, and OpenSSL for local test certificates. OpenSSL generates fixtures only. Wirestack consumers use their installed static AWS-LC provider, not system OpenSSL.
- A disk-backed scratch directory with at least 2 GiB free. Do not place build trees on a tmpfs `/tmp`.
- The accepted development archive at `docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz`. Its qualification is `NOT_QUALIFIED`; these commands do not sign or publish it.

The source profiles select qualified stable SDK 1.1.3 and the available candidate whose actual compiler binding matches the accepted M11-004 installed-consumer report. Candidate version labels do not authorize arbitrary nightlies. The capture fingerprints compiler, CJPM, runtime, standard-library archives and import metadata, then runs the consumers again. Read each profile's report for its result before using it as evidence.

## Observed source matrix

Both profiles ran on native Linux x86_64, glibc 2.44 and kernel 7.2.7. These host results are not minimum CPU, glibc or kernel evidence.

| Compiler and matching CJPM | Installed source build | Native consumer behavior | Consumer recompile | Binary cross-SDK | Evidence |
|---|---|---|---|---|---|
| Stable 1.1.3 | PASS | 47 checks, raw/gzip downloads, SSE/WSS, service and six CA probes PASS | Required | Not claimed | [Stable report](../evidence/M12-002/source-sdk/stable-native/report.json) |
| Candidate 1.3.0-alpha.06 | PASS | Same 47 checks and operational outcomes; six CA probes PASS | Required | Not claimed | [Candidate report](../evidence/M12-002/source-sdk/candidate-native/report.json) |

The [comparison](../evidence/M12-002/source-sdk/summary.json) binds all 164 identical production source files, the identical archive, distinct SDK/runtime and executable digests, and installed native build manifests. Native archives were built with Clang 15.0.7. The observed host `cc` is GCC 16.2.1, which is not the recorded archive builder. The artifact manifests record native flags and provider configure options; consumer builds have no added CPU option. ISA and minimum-platform claims belong to the separate binary deployment evidence.

The public trust probe reports `ERROR ca_file_missing` for an absent explicit DER file and `ERROR certificate_untrusted phase=tls_handshake` for an incorrect explicit or installed system CA. With all system CA locations hidden, it reports `ERROR trust_unavailable`. Successful downloads report `TRUST_DOWNLOAD_PASS bytes=8`. These are application diagnostics derived from actual public calls, not provider exception-text matching.

## 1. Capture a stable source profile

Set `SDK_ROOT` to the SDK containing `bin/cjc`, `tools/bin/cjpm`, `runtime`, `lib` and `modules`. Set `SCRATCH` to your disk-backed task directory. Use a new profile name for a new capture; the runner preserves existing evidence rather than overwriting it.

```bash
export SDK_ROOT="$HOME/cangjie_sdk/sts1.1.3"
export SCRATCH="$HOME/.cache/agent-tmp/wirestack-source-sdk"
mkdir -p "$SCRATCH"
chmod 700 "$SCRATCH"
export TMPDIR="$SCRATCH" TMP="$SCRATCH" TEMP="$SCRATCH"
python3 tools/m12_002_source_sdk.py \
  --sdk-root "$SDK_ROOT" \
  --archive docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz \
  --qualification docs/evidence/M11-004/installed-sdk113/report.json \
  --profile stable-rebuild \
  --scratch "$SCRATCH"
```

A successful capture prints a JSON result with `status` equal to `PASS`. Its report and normalized command logs are under `docs/evidence/M12-002/source-sdk/stable-rebuild/`. A failure retains the exact exit result and reports the failed step; do not describe that profile as supported.

For the accepted candidate, provide its actual SDK root and use `docs/evidence/M11-004/installed/report.json` as the qualification input. If the compiler digest differs, the capture fails closed. Qualify that new candidate separately before adding it to the matrix.

## 2. Read source and binary outcomes separately

The runner extracts the archive and checks every installed payload entry. It compares production sources with the current checkout, copies the four M11-004 consumers and the public trust probe, and builds from relative package dependencies while the checkout is hidden in a private mount namespace.

It then moves the whole installation and consumer tree to a new location. The old location and development checkout remain hidden during native execution. CLI/raw, CLI/gzip, SSE/WSS and service acceptance exercise real native networking, TLS, cancellation, cleanup and configuration rotation. The command logs record the actual compiler diagnostics and runtime outputs.

Every source profile requires consumers to recompile. `binary_cross_sdk` stays `NOT_CLAIMED`. Compare the separately maintained binary deployment matrix before deploying precompiled programs. A successful rebuild neither establishes ABI compatibility nor tests an older kernel or a weaker CPU.

## 3. Install trust material deliberately

The Linux system adapter selects a readable, nonempty PEM CA bundle at one of these locations, in order:

1. `/etc/ssl/certs/ca-certificates.crt`
2. `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`
3. `/etc/pki/tls/certs/ca-bundle.crt`
4. `/etc/ssl/ca-bundle.pem`

If no bundle is usable, it searches hashed certificate directories at `/etc/ssl/certs` and `/etc/pki/tls/certs`. Use your distribution's CA installation mechanism to provision system trust. No provider default or environment-variable fallback replaces Wirestack's selected system trust policy.

`HttpClient.builder()` uses system trust. `HttpClientTlsConfig([certificateDer])` explicitly selects DER roots supplied by the caller. The task-owned public probe accepts:

```text
main system HTTPS_URL
main explicit HTTPS_URL CA_DER_FILE
```

The capture uses its private namespace to install a controlled PEM at `/etc/ssl/certs/ca-certificates.crt`. It does not change host CA files. It checks successful system and explicit trust, absent system material, incorrect system material, a missing explicit file and an incorrect explicit CA. The report records each observed diagnostic and exit code. This establishes the bundle installation path; it does not infer hashed-directory execution from bundle success.

## 4. Reject stale evidence

Verify a retained successful report against the archive, the currently selected SDK bits and the retained capture root:

```bash
export WIRESTACK_SOURCE_CAPTURE_ROOT=<disk-backed-source-capture-root>
python3 tools/m12_002_source_sdk.py \
  --sdk-root "$SDK_ROOT" \
  --archive docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz \
  --verify docs/evidence/M12-002/source-sdk/stable-rebuild/report.json
```

The success signal is `M12_002_SOURCE_SDK_VERIFY_PASS`. A changed archive, compiler, CJPM, runtime, import metadata, runner, consumer source or normalized command log invalidates the report.

`WIRESTACK_SOURCE_CAPTURE_ROOT` is the private capture root passed to the capture's `--scratch`; the verifier reads `<root>/<profile>/` from it. The report carries only artifact-byte digests of the seven TLS fixture files, so the verifier re-hashes `certificate.key`, `certificate.pem`, `certificate.der`, `untrusted.key`, `untrusted.pem`, `untrusted.der` and `key.der` in that directory and rejects a missing, mutated, swapped or foreign-profile file. Without the selector the verifier refuses with `WIRESTACK_SOURCE_CAPTURE_ROOT must select the retained source captures`; retaining a report alone never satisfies the fixture binding.

**Private-key boundary.** These fixtures include generated private keys. They stay in the private task scratch root and are never committed to the repository or attached to evidence. Only their typed digests are published, and the digest alone does not let anyone reconstruct a key. A capture root that keeps key material under version control defeats this boundary and is not acceptable retained evidence. Rebuild and rerun the matching source profile after such changes. Provider and native toolchain changes require the existing release gates as well; this source capture is not release qualification.

The focused verifier regression tests use real retained evidence:

```bash
export WIRESTACK_SOURCE_SDK_REPORT=docs/evidence/M12-002/source-sdk/stable-rebuild/report.json
export WIRESTACK_SOURCE_SDK_ROOT="$SDK_ROOT"
export WIRESTACK_SOURCE_CAPTURE_ROOT=<private-source-capture-root>
python3 -m unittest tools.tests.test_m12_002_source_sdk
```

Without those inputs the tests skip, rather than inventing native evidence. See the [installed applications guide](installed-applications-linux.md) for the four consumer commands and their ownership contracts.

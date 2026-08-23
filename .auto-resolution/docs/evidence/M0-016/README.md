# M0-016 evidence: TLS provider PoC

## Current status

- Task: **IN PROGRESS**
- Linux glibc native PoC: **scheduled by repository CI**
- Linux musl, Windows and macOS: **NOT_RUN**
- Android, iOS and HarmonyOS/OpenHarmony native execution: **BLOCKED — no device runner connected**
- Final provider selection: **out of scope; M0-020**

The first implementation establishes a fail-closed, provider-neutral runner and executes AWS-LC, Mbed TLS and vendored OpenSSL from pinned source on a native Linux glibc runner. It does not mark M0-016 complete until the required platform/capability matrix and durable native evidence are present.

## Pinned sources

| Provider | Version | Source identity |
|---|---:|---|
| AWS-LC | 5.5.0 | exact commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a` |
| Mbed TLS | 4.2.0 | official archive SHA-256 plus commit `ece41aa84d7879d7e55c59e955a5884b541f7f3b` |
| OpenSSL control | 3.6.3 | official archive SHA-256; CI peels `openssl-3.6.3` to its exact commit |

The canonical machine-readable pins are in `tools/tls_provider_poc/providers.json`.

## Reproduction

```bash
python3 tools/tls_provider_poc/validate.py \
  --matrix docs/evidence/M0-016/platform-matrix.json

python3 tools/tls_provider_poc/run.py \
  --provider aws-lc \
  --output build/tls-provider-poc/aws-lc/result.json

python3 tools/tls_provider_poc/validate.py \
  --result build/tls-provider-poc/aws-lc/result.json
```

Use `aws-lc`, `mbedtls` or `openssl`. Network access, CMake/Ninja, a C/C++ toolchain, Perl, Git and a host `openssl` command for fixture generation are required.

## Evidence rules

- Every provider/platform cell stays `NOT_RUN` or `BLOCKED` until an actual run is retained.
- A missing external-signer or session test makes a result `PARTIAL`, never `PASS`.
- System TLS-library discovery or runtime fallback makes the result `FAIL`.
- Cross-compilation does not change a native platform cell to `PASS`.
- CI artifacts are supporting evidence; accepted results will be checksum-pinned under this directory before M0-016 is completed.

# M0-016 evidence: TLS provider PoC

## Status

M0-016 is **BLOCKED** because Android, iOS, and HarmonyOS or OpenHarmony do
not have native-device evidence.

The previous schema-v4 desktop evidence is superseded. All desktop cells are
`NOT_RUN` until native runners produce schema-v5 results. Schema v5 adds
evidence that schema v4 could not represent: required and optional client
authentication, provider license payloads, exact repository and execution
identity, bounded resident/allocation profiles, and native memory diagnostics
where supported.

The superseded schema-v4 results remain in the repository for audit history,
but the platform matrix no longer treats them as passing evidence. The next
native run must retain:

- expired certificate rejection;
- malformed certificate rejection;
- adapter rejection of an empty ALPN identifier and a 256-byte ALPN
  identifier;
- a complete final-artifact symbol inventory, capped at 16,384 symbols and
  256 bytes per symbol;
- mTLS with required client authentication and optional client authentication
  both with and without a certificate;
- a digest-bound provider license bundle;
- exact repository, hosted-runner, and immutable musl container identity;
- bounded resident-memory and harness-allocation measurements;
- ASan and UBSan diagnostics on Linux glibc and macOS, with an explicit
  unsupported result on the other current desktop targets.

## Superseded desktop runs

The Linux and macOS results came from [GitHub Actions run
33384563625](https://github.com/lIlIIlIll/Wirestack/actions/runs/33384563625).
The Windows results came from [GitHub Actions run
33384563633](https://github.com/lIlIIlIll/Wirestack/actions/runs/33384563633).
Both pull-request runs report head revision
`0513ded006334d1c14f79b1b7c8b128b9d263d51`. GitHub executed merge revision
`837a63df942d67e77154c3127e2b917dfc1190cb`.

These runs do not satisfy schema v5 and must not be used as current PASS or
PARTIAL evidence. In particular, their musl results lack an embedded exact
repository revision and immutable container identity.

| Platform | Provider | Status | Symbols | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---:|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 3,802 | `f9e7c6b5273fe34766457fa5d545fac46bb747a1aa37e1581c5e0798b94e34f2` | `9755083574` | `d7c5cb1466ecfe5215f1432b2f96778905de43966bbdebfc502047a805024855` |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 1,113 | `eaf597ec40e027149c16ebfe559f808e0f2637cc57581a0bb3fea1ea38500c39` | `9755098794` | `162f0d9d4354c8bfc45251545df73197672516f2cb0fc041f42a415dd4dbda15` |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 9,576 | `7727db37b56fce645879432d50f23f94d4de8eeac226a251298be518acc87b44` | `9755104142` | `9b290d50e62f7d1e91098d4bc13c6cc677a65e5297230ccf831fbe553454bfdd` |
| Linux musl x86_64 | AWS-LC | PASS | 3,795 | `3afcf04b08be421d02575c4b1433411d5fc314452ba9b137c5ecb7503a54823a` | `9755097629` | `fd3ce11a44e64b35f81790f5af5ab2f77ffe281f0c04dae3033d8d33da519aa8` |
| Linux musl x86_64 | Mbed TLS | PARTIAL | 1,111 | `548f0114cb5048c74ba0c47dbde127441b85e579329ae61458e957cc3b2310b3` | `9755107115` | `689937c29063c2084d8c77b3c64f95e742e658b6928feeb919cb8a40edc8b0b4` |
| Linux musl x86_64 | OpenSSL | PARTIAL | 9,571 | `1544a851073d005510aa5eb9f61642b567b91a7804d1affd26dbdae013bcfea8` | `9755129394` | `77e3c7d245d491806dfd98914808372c40860822fe9cbef970b6e6defb6121da` |
| macOS arm64 | AWS-LC | PASS | 3,368 | `1cbfbc0ba36979fe1c6bdd28bdbaa90104918678a16ae7f4588b1825a35d56bd` | `9755084289` | `fb323068d5e15fcd1fa86b9a9be547b3f7190495d58611d3a9474234c857286e` |
| macOS arm64 | Mbed TLS | PARTIAL | 1,101 | `b0869b2c00cace869066f2d232e744dfea30d192e46d851670d7ceef4253cbc2` | `9755089166` | `fe6a653a992bd32fc7fc35be21f08980e3e32830f7afebbc0f1d66734b5435d4` |
| macOS arm64 | OpenSSL | PARTIAL | 9,534 | `b09ed3a4a015656c612a1a3f429f10adfa4c4cc82ba25975822fe07412896a2b` | `9755113459` | `f744ac9829d7df28f428c4a69be7254d88b59f9904f7928a2645eb7c751c6a78` |
| Windows x86_64 | AWS-LC | PASS | 9 | `d01de77bffd1760a36455e86e5f82cc6ea3903f000cb0e7eef4a43ab212460f1` | `9755105791` | `a2a8bf9f28ebcfb31b87ed6454716052ae3c64d3eec70879a7afaf7d43a94e8d` |
| Windows x86_64 | Mbed TLS | PARTIAL | 0 | `346ddb0ea8278c5c2f05ff8a56d3a989a2eb71e7937da30fc4ccb50c3a64a48a` | `9755162465` | `8505a46f34e2251e46280677e3a0b62cb22cbdb59201ebe9a7a4100dba46a52f` |
| Windows x86_64 | OpenSSL | PARTIAL | 0 | `d37a949c14f150147031d338bb0f39391d155d3a47ba652f9a53f1ecbeb59e45` | `9755348468` | `d9dd5255934c1d89321efea8ac55eb5c74dad5b67b10e85521bcc8033bf94ef2` |

Each result contains `build_log_sha256`. The platform matrix records the
result path and SHA-256. The Windows run metadata, artifact digests, and build
log digests are in
[`windows-x86_64-run.json`](windows-x86_64-run.json). GitHub artifacts can
expire, so the committed result JSON files and matrix digests are the durable
evidence.

## Pinned sources

| Provider | Version | Source identity |
|---|---:|---|
| AWS-LC | 5.5.0 | commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a` |
| Mbed TLS | 4.2.0 | commit `ece41aa84d7879d7e55c59e955a5884b541f7f3b` plus archive SHA-256 |
| OpenSSL control | 3.6.3 | official archive SHA-256 and peeled tag commit |

`tools/tls_provider_poc/providers.json` contains the machine-readable source
pins.

## Validate the current matrix

Run the validator and the fault-injection tests from the repository root:

```bash
python3 tools/tls_provider_poc/validate.py \
  --matrix docs/evidence/M0-016/platform-matrix.json

python3 -m unittest tools.tests.test_tls_provider_poc
```

The PoC runner requires network access, CMake, Ninja, a C or C++ toolchain,
Perl, Git, and a host `openssl` command for fixture generation. The host
`openssl` command does not provide the TLS implementation under test. The
runner links the PoC binary against the pinned provider archives and rejects
system TLS runtime dependencies.

## Evidence rules

- A retained incomplete native result is PARTIAL only when it satisfies the
  current schema.
- A missing external-signer or session test prevents PASS.
- A runtime provider fallback or a system TLS dependency produces FAIL.
- Cross-compilation does not satisfy a native platform cell.
- This PoC does not select or claim a production provider outside Linux.

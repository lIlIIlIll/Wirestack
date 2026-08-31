# M0-016 evidence: TLS provider PoC

## Current status

- Task: **BLOCKED**
- Native desktop results: **NOT_RUN after ALPN contract expansion**
- Previous 12 schema-v3 results: **superseded; they do not contain negative ALPN metrics**
- Android, iOS and HarmonyOS/OpenHarmony: **BLOCKED** because no native device runner is connected

The current PoC adds TLS 1.2 and TLS 1.3 ALPN no-overlap rejection plus two
malformed-input checks. The prior native results predate those checks, so the
canonical matrix does not accept them. M0-016 remains blocked while desktop
reruns and the three mobile platform runs are missing.

The Linux and macOS results came from [GitHub Actions run 33376714398](https://github.com/lIlIIlIll/Wirestack/actions/runs/33376714398).
The Windows results came from [GitHub Actions run 33376714550](https://github.com/lIlIIlIll/Wirestack/actions/runs/33376714550).
Both pull-request runs report head revision
`cc62416bdab6c7b9a090f830a757d896ffacb231`; GitHub executed merge revision
`dd9a7f248ec2c60d9a9d965d08af0ac359806f23`. The musl runner executes inside
an isolated Alpine minirootfs, so its retained JSON does not repeat the
repository revision; its artifact remains bound to run 33376714398.

## Superseded native results

These results remain for audit history but do not count as current matrix
evidence. Their artifact digests identify the archived build log and result
pair.

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | `453846edf24a89fab2ef9a0c9b1bbebe6e9cb2648185492d2f96d073997b775a` | `9752199848` | `43e052fcd269856f59707f7406baa393849abbd323ac822ae8f56105fc7b6279` |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | `f30c0c9ce5571c6b9ac54a768419ee02d0ff274901dca5aa18d290b8e71d928c` | `9752207980` | `fde4689a50d0d7b8d908649afcad998c12bfd82eeed232d6a350166fc7619fc7` |
| Linux glibc x86_64 | OpenSSL | PARTIAL | `fb06c53bdc4992e94004521825653f5ad99e54443423612b56a34473b4824ed5` | `9752193526` | `374ddb83fbee46c7b55ac65e719fea3a569b252e2e77075a003f73dd5fd7dd1c` |
| Linux musl x86_64 | AWS-LC | PASS | `cce81e4cb20a5099a99c9ce005b476c0870bdd1051b7a1d2ba72b4859f974834` | `9752199339` | `308655cc73c9b9a133233ed7245c8da47207fc7fa1fe64c4f7b14bc841bbffea` |
| Linux musl x86_64 | Mbed TLS | PARTIAL | `a005e3d670f67bf4a563e988e12d61964906c9a647eb8699e05d508b5f4a28ef` | `9752207104` | `12ab2daffdfb3968c8e0e3e223766a6205810d0b13f672b596467431d7922c4b` |
| Linux musl x86_64 | OpenSSL | PARTIAL | `406b3ebd79583b7c7d3ca51cc8885375081f9691a18caf798c945d89f13c6075` | `9752218636` | `ebe8800d30892ee29f1464966b5ab4aab21c7675d15061c638f08bef5f148ac6` |
| macOS arm64 | AWS-LC | PASS | `3716824385649737a4447160ee1fd0a26749d8fc18abd284ab1cf68c8f2857a1` | `9752192064` | `1e1518e37289865716664c84c3e352c88af894c5a1bccbb53b3a240d73db3f81` |
| macOS arm64 | Mbed TLS | PARTIAL | `8616ae8131fc2a971bb8cc7c1d0b4bc2899db8e4e0ac0a3827e25927a1bc9016` | `9752199977` | `ae0ce0a4cc1e7c9e98b6c34a89c784a74ef0e9dbf801a2c55d9512aede198d38` |
| macOS arm64 | OpenSSL | PARTIAL | `5195dca0d53f6acf0fc3b2ef8747b066ad9791302f200b6549709441ce27bb7a` | `9752206574` | `1e25a6d6f88cada7fe503ff26ce3c042439775af08d8f7ff0a8d53ea1beb7ea6` |
| Windows x86_64 | AWS-LC | PASS | `47e0ae7433b0bf25a70ea8c048f411488537ad7218029763f73989f101d81d95` | `9752197413` | `3d34931460e00445f8c1c575ee34f704bf878641dadad55090ecbbff05c0a823` |
| Windows x86_64 | Mbed TLS | PARTIAL | `18267e413cd443992a837fe80243df0897f99ce7857dd4d70199cc8facc6dd78` | `9752254052` | `a7221c3b172870b3443fdb60d5067bdd870782022dc2d6c0975a96acab753e0b` |
| Windows x86_64 | OpenSSL | PARTIAL | `4cdbc31baf559a95abbac242b8cbcd6cfaa8a365281db0406f1f19878f283b3b` | `9752436045` | `6abd91a3622912aad81e27bad9d874c6f7c900483241dd6c8e1de648da860577` |

The Windows run metadata and build-log digests are retained in
[`windows-x86_64-run.json`](windows-x86_64-run.json). CI artifacts are
supporting evidence and may expire; the committed result JSON and matrix
digests are durable.

## Pinned sources

| Provider | Version | Source identity |
|---|---:|---|
| AWS-LC | 5.5.0 | commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a` |
| Mbed TLS | 4.2.0 | commit `ece41aa84d7879d7e55c59e955a5884b541f7f3b` plus archive SHA-256 |
| OpenSSL control | 3.6.3 | official archive SHA-256 and peeled tag commit |

The canonical machine-readable pins are in
`tools/tls_provider_poc/providers.json`.

## Reproduction and validation

```bash
python3 tools/tls_provider_poc/validate.py \
  --matrix docs/evidence/M0-016/platform-matrix.json

python3 -m unittest tools.tests.test_tls_provider_poc
```

The PoC runner requires network access, CMake, Ninja, a C/C++ toolchain, Perl,
Git and a host `openssl` command for fixture generation. It links the test
binary against the pinned provider archives and rejects system TLS runtime
dependencies.

## Evidence rules

- A retained incomplete native result is `PARTIAL`, never `PASS`.
- A missing external-signer or session test makes a result `PARTIAL`.
- Runtime provider fallback or a system TLS dependency makes the result `FAIL`.
- Cross-compilation does not satisfy a native platform cell.
- This PoC does not select or claim a production provider outside Linux.

# M0-016 evidence: TLS provider PoC

## Current status

- Task: **BLOCKED**
- Native desktop results: **NOT_RUN after schema-v4 contract expansion**
- Previous 12 schema-v3 results: **superseded; they lack certificate-negative and durable symbol-inventory evidence**
- Android, iOS and HarmonyOS/OpenHarmony: **BLOCKED** because no native device runner is connected

The current PoC adds deterministic expired and malformed certificate rejection,
adapter-level rejection of an overlong ALPN identifier and a bounded export
inventory for the final artifact. The previous native results predate those
checks, so the canonical matrix does not accept them. M0-016 remains blocked
while desktop reruns and the three mobile platform runs are missing.

The Linux and macOS results came from [GitHub Actions run 33379997844](https://github.com/lIlIIlIll/Wirestack/actions/runs/33379997844).
The Windows results came from [GitHub Actions run 33379997896](https://github.com/lIlIIlIll/Wirestack/actions/runs/33379997896).
Both pull-request runs report head revision
`e2376b0de9c0f936070f0e473be152a615de7242`; GitHub executed merge revision
`dc0e4d54e5f35d32a6b974f96a0006595729dbfe`. The musl runner executes inside
an isolated Alpine minirootfs, so its retained JSON does not repeat the
repository revision; its artifact remains bound to run 33379997844.

## Superseded native results

These results remain for audit history but do not count as current matrix
evidence. Their artifact digests identify the archived build log and result
pair.

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | `c23c56c6e8f21c00343992f2e77cd2849128456a3efabea67f74ee102a4a4cd9` | `9753403303` | `ccb155e4e9cf29fd1a6927b101975bf0db656ddac5567c3db64e929290c0aa40` |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | `ed5b3d99a8e3698f5994fcc41d0d6ca7eff3919e6225b1ceaafacdefa0f8c02c` | `9753431167` | `c03e497d7e89ff91357dd3a70b02246d94b6e5dab296c6e73b817493d0c58d1d` |
| Linux glibc x86_64 | OpenSSL | PARTIAL | `de4b761ad1f8098020d56b5cf719b17a4a03f45f4e8b621da9c8336549ad6546` | `9753438762` | `a378ba050b21b32fe7859587058bb51a033bb56859ed77fb6bfd9fbc663639aa` |
| Linux musl x86_64 | AWS-LC | PASS | `465d7538be0c23060286ba75dd93099c08321b6bc4e566e75d74784bffd22eea` | `9753417277` | `84870828d6fbe2ac48ec0a9711501ce6f7ee31549185f213faabef4ea8c99a9d` |
| Linux musl x86_64 | Mbed TLS | PARTIAL | `ec67f326642980e559842f249d2dab5280377d46d3cb839e791235ab55281a55` | `9753411107` | `6194bce0c87cd0934ee8750f73f467e83a5049149d02735b674ed27f4cb94bcb` |
| Linux musl x86_64 | OpenSSL | PARTIAL | `fed4370df3d036aae03c4470c185ae1cd41c85d997b473c50cb8a33d49dfd8e3` | `9753446398` | `f45fb44e6dfd1bcfbb024908ff8e55a3d819662d18acc56a0ff00c45c2d30909` |
| macOS arm64 | AWS-LC | PASS | `52bfcef9ec1d235588236054f28fb2ffa83be075ab948bb4451be280f13e2d4d` | `9753398248` | `a4aad200f7295638f3efc1353ce47e71ccad3f356e252548b14f2b93822f101c` |
| macOS arm64 | Mbed TLS | PARTIAL | `3db4f230e1b21da1bbbd6ab6ae10c0ceb556ff40c1f8bda21e2c06f699964b9c` | `9753408506` | `f3bc278474857a62e58b31aa8c39b1947384529e400d42d0b83bc1e6d54f2d74` |
| macOS arm64 | OpenSSL | PARTIAL | `87c754ba2fa062f42b5be890de8650baf16f24dc582f4b59f6aa960703b85e9a` | `9753433117` | `f02c683394049bdbd4aa8a93823e0fd192d5f8899992b36b5f3ec40dce65292e` |
| Windows x86_64 | AWS-LC | PASS | `b679aeb5060555507a9ef3536b7070c0ba4ac97d2d88f11860e967b6a0f22587` | `9753432545` | `e7e992339341fc87301f50f64b102c3f83e817d77d01eb8bc0c05064283fbdf3` |
| Windows x86_64 | Mbed TLS | PARTIAL | `da39a64e175f73b4d0f02225780c99d7820bf39ba8c0246da0a315ecae153500` | `9753476656` | `adb98f8bfa85ef24928d067c4560e0a8ee46ea47fb53baa87691dc2063c3e0d5` |
| Windows x86_64 | OpenSSL | PARTIAL | `5ff29f56fba5c41d92d59827f47888adb95f2cf5555691b7fbba7e9b142de3f2` | `9753592384` | `03b0efce32f28e50f80d2879862b27c4d5f880b921fc2ddcb9d5eeb652a6971a` |

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

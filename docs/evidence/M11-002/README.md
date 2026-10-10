# M11-002 — explicit bounded gzip decoding

Status: **COMPLETE** for native Linux x86_64 glibc working-tree acceptance. This is
not a committed candidate or qualified/signed release. Dependencies M9-001 and
M10-001/002/003 were COMPLETE before implementation. No next task was started.

## Scope

The separately imported `wirestack.gzip` package provides `GzipClient`,
`GzipResponse`, `GzipBodyStream`, typed errors and absolute limits. The original
Cangjie RFC 1951/1952 decoder adds no native compression library. HTTP Core and
default consumers stay raw. Request deadline/cancellation, DATA admission and
H1/H2 ownership remain the existing client's responsibility; the decoder does not
retry a returned response or create another timeout owner.

Wire headers remain separate from decoded headers/unknown decoded length.
Headers containing wire representation validators are not reused as decoded
validators. HTTP trailers remain explicitly documented wire metadata. Output is
provisional until every gzip member and physical wire EOF validate. Defaults:
one member, 64 MiB input/output, 4 KiB header/input buffers, 4,096 blocks, 16 KiB
output per read and a conservative 135,168-byte codec reservation. All values
have hard ceilings. Checkpoints occur within 512 counted work steps, not an
asserted wall-clock SLA.

## Acceptance and receipts

| Acceptance | Executed evidence |
|---|---|
| Incremental, optional-header, empty/large and exact boundary decoding | 11 codec/corpus/differential tests plus 13 native tests; [verification](verification.json) |
| Bombs, invalid trees, members, coding layers, CRC/ISIZE, truncation, trailing input | Fixed negative corpus and 96 seeded oracle rows: 52 exact outputs, 44 rejections |
| Context, finite work/storage and real resource ownership | Native cancel/deadline/local-close, H1 abandonment, live H2 sibling, buffered CPU timeout and zero terminal owners |
| Default raw versus explicit decode and wire metadata | [Two installed consumers](installed/report.json), H1 and TLS H2; five explicit installed checks |
| Dependency/license/SPDX delivery | [Source supply chain](supply-chain/report.json), [SPDX 2.3](supply-chain/sbom.spdx.json); four source digests and equal direct native dependencies |
| API, examples, docs | [Current inventory](public-api.json), [strict seven-package docs](docs/report.json), [live rendered/search proof](docs/browser.json), [guide](../../guides/gzip.md) |
| Whole-tree regression | [Five canonical task commands](task-gate.json): 986 native passed, 28 explicitly skipped; 48 Python tooling checks |
| Secondary SDK | Native SDK 1.1.3 gzip: 24 passed, zero skipped/errors/failures; [raw log](logs/sdk113-gzip.log) |

The canonical task gate passed before the installed runner gained automatic
source-SPDX generation. The final runner was then rebuilt/executed independently;
its report and SPDX bind the same actual source archive and current runner digest.
The later API-navigation and task-status edits change documentation only.

## Measured baseline

Both modes process eight 1 MiB inputs, verify 8,388,608 output bytes and checksum
813,694,976. Raw output, native CPU/compiler metadata and exact durations are in
[the installed report](installed/report.json). This records a measured baseline,
not a claimed optimization or throughput SLA.

| Mode | MiB/s | Elapsed ns | Maximum counted work between checks | Codec retained bound bytes |
|---|---:|---:|---:|---:|
| Raw | 11.766 | 679952029 | 0 | 0 |
| Gzip | 1.096 | 7296705407 | 512 | 135,168 |

Decision: **PASS** for exact output, validated integrity, bounded work/storage and
owner reclamation. No speed threshold was specified; the decoder is slower than
the raw baseline. These runs do not qualify other operating systems or SDKs.

## Reproduction

Use the repository's existing SDK environment and a disk-backed scratch directory:

```bash
TMPDIR=<scratch> TMP=<scratch> TEMP=<scratch> cjHeapSize=1GB scripts/check-task M11-002 --output docs/evidence/M11-002/task-gate.json
python3 tools/m11_002_native_gzip.py --scratch-parent <scratch>
python3 tools/architecture_guard.py --root . --format text
scripts/check-m7-032-public-api --json
```

The task contract records each exact compiler/test/docs command. Installed
certificates are generated with the test fixture tool only; the executables'
`readelf -d` lists have no OpenSSL or native compression dependency. SPDX is a
source/binary acceptance record, not a replacement for formal release
qualification. Source/report digests, initial workspace safety, execution counts,
explicit exclusions and non-claims are in [verification.json](verification.json).

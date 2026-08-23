# GATE-NET-03 — Linux x86_64 supplied-SDK result

**Task:** COMPLETE  
**Linux gate:** PASS  
**Global six-platform gate:** INCOMPLETE

## Result

| Scenario | Budget | Samples | Overshoot P50 | P95 | P99 | Maximum | Decision |
|---|---:|---:|---:|---:|---:|---:|---|
| idle-read | 50 ms | 20 | 0.344 ms | 0.496 ms | 4.603 ms | 4.603 ms | PASS |
| idle-read | 200 ms | 20 | 1.941 ms | 2.306 ms | 4.729 ms | 4.729 ms | PASS |
| idle-read | 1000 ms | 20 | 4.238 ms | 10.238 ms | 10.245 ms | 10.245 ms | PASS |
| partial-write | 50 ms | 20 | 0.418 ms | 0.516 ms | 0.575 ms | 0.575 ms | PASS |
| partial-write | 200 ms | 20 | 1.930 ms | 3.075 ms | 4.510 ms | 4.510 ms | PASS |
| partial-write | 1000 ms | 20 | 2.801 ms | 10.184 ms | 10.359 ms | 10.359 ms | PASS |
| blocked-connect | 50 ms | 20 | 0.453 ms | 0.928 ms | 1.979 ms | 1.979 ms | PASS |
| blocked-connect | 200 ms | 20 | 2.155 ms | 2.553 ms | 2.589 ms | 2.589 ms | PASS |
| blocked-connect | 1000 ms | 20 | 3.802 ms | 10.244 ms | 10.310 ms | 10.310 ms | PASS |
| blocked-accept | 50 ms | 20 | 0.425 ms | 0.571 ms | 0.838 ms | 0.838 ms | PASS |
| blocked-accept | 200 ms | 20 | 1.899 ms | 2.584 ms | 3.030 ms | 3.030 ms | PASS |
| blocked-accept | 1000 ms | 20 | 9.539 ms | 10.182 ms | 10.248 ms | 10.248 ms | PASS |

All 240 measured samples proved the operation remained pending until the external deadline owner ran, then terminated through public `close()` without a harness timeout. The configured acceptance bound is `max(20 ms, budget × 5%)`; every measured maximum is below 20 ms.

## Deadline ownership

- A single `Timer.once` owns each absolute budget.
- `readTimeout`, `writeTimeout`, and per-attempt `connect(timeout)` are not used.
- Repeated write uses one absolute deadline for the whole loop; it does not reset a timeout after each successful write.
- The write probe records two progress checkpoints and requires no progress before close, proving that the measured operation was actually blocked.
- Terminal categories are captured by exception type or return value, never exception message text.

## Execution grouping

Final measurements were serialized by scenario. The blocked-connect case was split into two 10-sample batches per budget so local listen-backlog and TIME_WAIT accumulation could not distort later samples; the two batches were merged without dropping or replacing any sample.

## Toolchain

```text
Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)
Target: x86_64-unknown-linux-gnu
Cangjie Project Manager: 1.1.3
SDK archive SHA-256: bc2ed8a34b9b6846a5445d3eba0ac66b146730a005d3df56d45a2b119416f40d
```

## Durable raw evidence

The complete schema-versioned report is split only to keep individual Git blobs small. Reconstruct it byte-for-byte with:

```bash
cat result.json.gz.part-* > result.json.gz
gzip -dc result.json.gz > result.json
sha256sum -c SHA256SUMS
```

Expected reconstructed digests:

```text
result.json     48892db949975cc2e3f36095ba78e3765bf2f5a8897e19a2eaf6626a45ff8e8b
result.json.gz  acfebf94124c494de65f284c0f656b57335e0dd734932494e6266731bbd53068
```

## Boundary

This result is native Linux x86_64 evidence for the supplied SDK. It does not establish Windows, macOS, Android, iOS, or HarmonyOS/OpenHarmony behavior, does not implement Wirestack `OperationContext`, and does not claim that public `TcpSocket.abort()` exists.

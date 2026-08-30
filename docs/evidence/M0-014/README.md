# M0-014 Windows socket copy profile

Status: **COMPLETE**

M0-014 profiles the native Windows x86_64 `std.net` receive path on GitHub's
`windows-2025` runner. The formal run used Cangjie
`1.3.0-alpha.20260830010011`, a 64 KiB application buffer, five payload sizes,
and five performance samples per payload.

## Result

Run [33324754109](https://github.com/lIlIIlIll/Wirestack/actions/runs/33324754109)
passed on revision `0c01829c64c71b7867b1d11a10dc3a26dedd9235`. The runner
validated the result against the same revision before uploading the artifact.

| Payload | Reads | Read size | Copied bytes | Allocation events | P50 throughput |
|---:|---:|---:|---:|---:|---:|
| 1 KiB | 1 | 1 KiB | 1,024 | 10,231 | 6.081 MiB/s |
| 16 KiB | 4 | 4 KiB | 16,384 | 10,232 | 97.413 MiB/s |
| 64 KiB | 16 | 4 KiB | 65,536 | 10,232 | 272.926 MiB/s |
| 1 MiB | 256 | 4 KiB | 1,048,576 | 10,232 | 738.334 MiB/s |
| 100 MiB | 25,600 | 4 KiB | 104,857,600 | 10,235 | 667.497 MiB/s |

The 16 KiB through 100 MiB cases reproduce the fixed 4 KiB effective read cap.
The test-only MinGW link wrapper counts each completed
`CJ_SOCKET_BufferRCopy` call and its returned byte count. Each copy count equals
the application-visible read count, and copied bytes equal the payload. WPR and
xperf provide the per-process allocation-event totals. Win32 process counters
provide peak private and working-set bytes.

## Evidence

- [Formal result](windows-x86_64/result.json)
- [Exact-revision validation](windows-x86_64/validation.json)
- [Runner and toolchain identity](windows-x86_64/environment.json)
- [Test plan](test-plan.md)

The link wrapper is used only by the M0-014 probe. It does not modify or enter
Wirestack production code, runtime, `std`, `stdx`, or the SDK.

## Low-copy decision

The counters show one native-to-managed copy per application read. The 100 MiB
case therefore performs 25,600 copies even though the application requests a
64 KiB buffer. Wirestack will pass each returned chunk directly to its bounded
protocol consumers and will not concatenate chunks into another staging
buffer. This avoids a second Wirestack-owned copy but cannot remove the
`std.net` copy or its 4 KiB cap.

Removing that copy requires a future public SDK improvement tracked by UP-006
and new native Windows evidence. Wirestack will not use private socket handles,
runtime ABI, or an unbounded TLS buffer as a workaround.

## Excluded gates

This task did not run the one-hour SSE profile, the 86,400-second soak, mobile
device gates, TLS provider qualification, or HTTP platform qualification. The
result completes only the Windows socket copy profile described by M0-014.

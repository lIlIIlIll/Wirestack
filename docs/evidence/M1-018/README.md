# M1-018 Linux bounded write staging evidence

- Task: `M1-018`
- Profile: Linux x86_64 glibc
- Task result: **PASS**
- Repository gate result: **PASS**
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

## Scope

`StdNetTransport.writeSome` now retains its exact-size staging array on the
connection and reuses it for consecutive writes of the same bounded chunk
size. If the next partial write has a different size, the connection replaces
the staging array instead of retaining a collection of differently sized
buffers.

When a bounded read or write covers its complete backing array and is no
larger than the configured staging bound, the adapter now passes that array
directly to `std.net`. Offset and shortened spans retain the bounded staging
path, so bytes outside the requested range are never exposed or overwritten.

The pinned `std.net.TcpSocket.write` surface accepts only a whole
`Array<Byte>` and has no offset/length or span overload. Therefore the adapter
must use an exact-size array for every native write. The retained array is
always sized to `min(source.length, stagingBufferSize)`, so its live capacity
never exceeds the configured connection bound and cannot grow with an HTTP
body. The default bound remains 16 KiB.

No public declaration was added or changed. The existing
`stagingCopiedBytes` diagnostic continues to count every byte copied solely
for the whole-array `std.net` boundary.

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| partial write is allowed | staging size 3 returns 3 for 5- and 4-byte sources; exact received prefixes are asserted | PASS |
| staging is reused per connection | `writeStaging` is a connection field and is replaced only when the bounded chunk size changes | PASS |
| memory does not grow with body size | the only retained write array has size `min(source.length, stagingBufferSize)`; no body-sized collection or cache exists | PASS |
| typical TLS record fits | the default connection sends and receives one exact 16 KiB record in one `writeSome` call | PASS |
| whole-array fast path | one exact 16 KiB read/write round trip reports zero staging copies | PASS |
| fallback copy is measurable | subrange coverage and 3 + 3 + 2 byte partial writes retain exact copy accounting | PASS |

## Tests

`writeSomeIsPartialAndReusesBoundedConnectionStaging` verifies partial progress,
exact byte prefixes across a stable chunk size and a shorter tail, and copied
byte accounting. `wholeArrayReadAndWriteBypassStagingForATypicalTlsRecord`
verifies the 16 KiB default boundary with exact loopback payload equality and
zero staging copies. `subrangesRetainBoundedStagingAndCopyAccounting` verifies
the safe fallback.

Focused command:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=StdNetTransportTest.*' --no-color --no-progress
```

Result: exit 0. Twelve selected cases passed; 505 unrelated cases were skipped.
The first restricted-sandbox attempt could not create the unittest runner
socket (`Operation not permitted`); the same command passed in the authorized
loopback environment.

Compatibility classification: `compatible`. The declaration diff contains
only one new private `writeStaging` field; the rejected draft public allocation
counter was removed before final validation.

## Repository gate

The canonical command was executed once after the fast-path change:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0. Python suites passed 50/50, 98/98 and 11/11; the architecture
guard, `cjpm check` and `cjpm build` passed. The Cangjie suite reported 517
total, 512 passed, 5 Performance-tagged skips, zero errors and zero failures.

## Remaining boundary

Offset and shortened spans still require one bounded adapter copy, and the
retained write array is replaced when the partial chunk size changes.
GATE-NET-05 still fails one short-payload comparison, so throughput
qualification remains open. M1-018 does not complete M1, typed half-close, or
the six-platform matrix.

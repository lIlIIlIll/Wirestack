# M1-002 Linux byte-span evidence

## Status

- Task: `M1-002`
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**

This task qualifies TR-BUF-001 for the current Linux profile. Vectored I/O is
the separate P1 requirement TR-BUF-002.

## Dependency

M1-001 is complete and has retained evidence for the Transport package and test
layout.

## Acceptance mapping

| Criterion | Evidence | Result |
|---|---|---|
| Constructor checks every range | Both span types call `validateSpanRange`; negative offset/length, offset past the end, and length past the remaining range fail with `IllegalArgumentException`. | PASS |
| Range arithmetic cannot overflow | Validation compares `length` with `arraySize - offset` after rejecting invalid offsets. It never accepts a range by computing `offset + length`. | PASS |
| Subranges do not copy | `slice` retains the same `Array<Byte>` and adjusts offset and length. `sliceAndAdvanceKeepTheOriginalArray` observes a later source-array mutation through the slice. | PASS |
| Mutable views write through | `mutableViewWritesThroughAndConvertsWithoutCopying` changes the original array through a `MutableByteSpan` and observes it through `asByteSpan`. | PASS |
| Advance returns the remaining range | Both `advance` implementations delegate to the checked relative slice. Tests cover valid suffixes and out-of-range values for both span types. | PASS |
| Empty ranges are stable | Empty arrays and zero-length ranges at the array end report `isEmpty`; advancing exactly to the end produces a valid empty range. | PASS |
| No native address escapes | The span structs contain only the array, offset, and length. They do not derive, store, or expose a native pointer, so no user-array address can outlive a native call through these types. | PASS |

The evidence closure adds mutable slice and advance rejection checks. Production
code already satisfied the contract and did not change.

## Commands and results

```bash
/home/elliot/.codex/scripts/codex_cangjie_env cjpm test \
  --filter='ByteSpanTest.*' --no-color --no-progress
```

Result: all 5 `ByteSpanTest` cases passed. Project totals were 5 passed, 560
skipped, 0 failed, and 0 errors. Exit status 0.

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit status 0. The command passed 57 repository tool tests, 114 gate
tool tests, 23 benchmark tool tests, the architecture guard, `cjpm check`, and
`cjpm build`. Non-performance Cangjie totals were 545 passed, 20 skipped, 0
failed, and 0 errors. The command retained the existing compiler warnings for
`metrics`, `waitUntilAcceptActive`, and `waitUntilWaiters`; this
test-and-documentation-only task introduced no new warning.

## Scope limits

- No runtime, std, or SDK source was modified.
- No SDK component was built.
- TR-BUF-002 vectored I/O remains P1 and is not required for M1-002.
- Non-Linux platforms were not executed.

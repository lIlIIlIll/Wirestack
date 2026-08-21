# Native backend internals and contracts

> 面向用户的选择、安装与最小示例见 [Backend 使用指南](../backends.md)。本文保留 C ABI、
> activation seam、symbol isolation、semantic index 与安全验证等维护者契约。

## Product boundary

`yjson` is the portable default and semantic oracle. It has no native
link dependency. `yjson_all` re-exports the core and AST macros only; it
does not install or enable a native backend.

`yjson_native` and `yjson_yyjson` are supported opt-in packages.
Selecting one package is explicit. If a selected native package cannot be built
or linked, the operation fails; package unavailability is not silently hidden by
falling back to Pure Cangjie. Internal semantic fallback inside a selected
backend is permitted when it preserves the same public contract.

The yyjson package statically vendors yyjson and compiles its public API with
ELF hidden visibility. The resulting Cangjie shared library exports no
`yyjson_*` symbols. A dual-version fixture verifies that the adapter continues
to bind its vendored 0.12.0 implementation while an application independently
uses yyjson 0.11.1, in either shared-library load order. The upstream vendored
source remains byte-for-byte unmodified; isolation is a build property.

## Backend matrix

| Backend | Stability for this RC | Toolchain | Lifetime | Thread safety | Primary operations |
|---|---|---|---|---|---|
| Pure Cangjie AST/Compact/typed codec | stable freeze candidate | Cangjie SDK | GC-managed | ordinary value/object rules | encode, decode, AST, Compact |
| Custom Native Compact | supported opt-in; backend-specific tuning knobs remain experimental | C11, Python 3, `ar` | explicit `Resource.close()` | not thread-safe | native DOM, lookup, bulk traversal, serialize |
| yyjson Direct Native DOM | supported opt-in; qualification selectors remain experimental | C11, Python 3, `ar` | explicit `Resource.close()` | not thread-safe | fastest measured general native DOM, coarse query, serialize |

Native document destructors are leak safety nets, not deterministic lifecycle
APIs. Use `try (document = ...)` or an explicit `try/finally`. A value view keeps
its document owner reachable, but closing that owner invalidates the view.

The thread contract is deliberately strict:

- callers provide external synchronization for read/read access;
- read/close and serialize/close races are forbidden;
- `close()` requires exclusive ownership and is idempotent;
- operations after close fail with `IllegalStateException`.

## Float64 fast-parser bridge

The core package exposes `JsonNativeFloatParserBackend` as an optional,
process-global seam for numeric-heavy generated codecs. `yjson_native` supplies
the supported `@FastNative` implementation and `enableYJsonNative()` installs
it together with the structural and bulk-number scanners. For isolated
measurements, `enableYJsonNativeFloatOnly()` installs only the Float64 parser;
`enableYJsonNativeNumericOnly()` is the separate bulk-number mode. These modes
are mutually exclusive. The matching disable function must be used before
selecting another isolated mode, and installation/removal must not race with
decoding.

The C bridge `YJ_JSON_ParseDouble` receives an already validated JSON number
token, copies at most 256 bytes to a bounded stack buffer, and returns `NaN`
for invalid bounds, malformed text, or a declined parse. The Cangjie caller
then uses the portable parser. The bridge makes no Cangjie calls or I/O and is
kept separate from the core package: Pure Cangjie remains usable without the
native archive.

Generated macro output calls the public
`JsonFastReader.suggestRawCollectionCapacity()` bridge for generic object
arrays. It is a bounded allocation hint rather than a stable application-level
capacity API. `yjson`, `yjson_macros`, `yjson_all`, `yjson_native`, and
`yjson_yyjson` must be
consumed at the same release version; see the
[1.0 RC API/ABI change inventory](../public-api-inventory.md).

## Access model

Both native parsers cross the Cangjie/C boundary once for a whole-document
parse. There is no per-token or per-field parse FFI. Use coarse lookup, native
bulk traversal, and native serialization. Fine-grained getters are suitable for
small query-style access, not sequential traversal of millions of nodes.

Native DOM does not accelerate `JsonNode.parse(bytes)`. Materializing a native
DOM into the Cangjie AST was measured and rejected as a product fast path.

## Number and duplicate semantics

All backends preserve exact `Int64`. Overflow integers, decimals, exponents,
`-0`, and `PreserveLiteral` inputs keep the required literal semantics. The
yyjson backend uses bounded semantic dispatch and may internally use Custom
Native for shapes that cannot use the direct representation safely.

Duplicate policy is `LastWins` by default or `Reject` when configured. Equality
uses decoded key bytes, so source spellings `"a"` and `"\u0061"` collide.

## Error compatibility

| Failure | Pure Cangjie | Custom Native | yyjson Direct |
|---|---|---|---|
| invalid UTF-8 | reject; detailed `JsonException` | reject; byte offset | reject; byte offset, coarser category |
| invalid escape | reject; detailed category/path | reject; byte offset | reject; generally `parse_error` |
| invalid number | reject; detailed category/path | reject; byte offset | reject; generally `parse_error` |
| duplicate with Reject | reject; currently `parse_error` | reject; currently `parse_error` | reject; currently `parse_error` |
| maximum depth | `max_depth` | `max_depth` | `max_depth` |
| document byte budget | `document_too_large` | `document_too_large` before DOM allocation | `document_too_large` before DOM allocation |
| decoded string/key budget | `string_too_large` | `string_too_large` before DOM allocation | `string_too_large` before DOM allocation |
| root container byte budget | `polymorphic_object_too_large` | `polymorphic_object_too_large` before DOM allocation | `polymorphic_object_too_large` before DOM allocation |
| trailing content | reject | reject | reject |
| allocation/document limit | runtime/OOM semantics | `out_of_memory` or `document_too_large` | `out_of_memory` or `document_too_large` |

The public guarantee is semantic rejection plus a meaningful byte offset where
available. Error categories and messages are not byte-for-byte identical across
backends, and backend-internal numeric codes are not public API.

Resource budgets are the exception to the otherwise coarser native categories:
their public `JsonException.code` values are identical across all three
backends. The old `YJ_Compact_Parse` and `YJ_Yyjson_Parse` C symbols remain;
limited parsing uses the additive `*ParseWithLimits` symbols only when a budget
is enabled.

## Security boundary

Custom and yyjson semantic indexes use a per-document randomized seed. Linux
uses `getrandom`, then `/dev/urandom`; a process-specific fallback preserves
correctness if both entropy sources fail. Exact byte equality is always checked.
Randomization materially reduces predictable collision attacks, but no open
addressing table can promise that worst-case behavior is impossible.

Native code expands the memory-safety surface. Release qualification therefore
includes targeted malformed-input tests, ASan/UBSan/LSan, and deterministic
differential fuzzing.

# Current API/ABI change inventory

This is a release-delta inventory, not a complete yjson API reference. It records
the public surfaces stabilized in the `1.0.0-rc.1` baseline plus accepted
Unreleased development deltas. Post-tag entries are not part of the immutable
`1.0.0-rc.1` artifact until a later candidate is frozen. The inventory includes
resource-limited parsing, the reusable fast collection bridge, and the optional
native Float64 parser. The machine-readable source is
[`release/public-api-inventory.toml`](../release/public-api-inventory.toml).

Most entries are additive relative to pre-1.0 snapshots. `JsonReadConfig.init`,
the `JsonDirectCodec<T>` to `JsonCodec<T>` rename, and the `JsonValue` to
`JsonNode` AST-root rename require snapshot consumers to rebuild. The latter is
required because the new unqualified `@JsonValue` macro occupies the same
Cangjie declaration namespace. The reviewed delta and the complete generated
declaration snapshot must be reviewed whenever a declaration is added, removed,
renamed, or changed. CI compares
[`release/public-api-snapshot.txt`](../release/public-api-snapshot.txt), which
includes public interface members and exported `YJ_*` C functions, so an
unregistered public addition can no longer pass through a needle-only check.

## Package pairing

`1.0.0-rc.1` 尚未发布到 registry。当前 cjpm manifest 只接受三段数字版本，因此
release identity 使用 `1.0.0-rc.1`，checked-in package manifests 使用未来正式版
`1.0.0`。候选阶段只支持 checkout path dependencies。

Generated code is compiled in the application, so `yjson_macros` cannot safely
be mixed with an older `yjson` runtime after the generated reader starts using
`JsonFastReader.suggestRawCollectionCapacity`. Use the aggregate package, or
pin all packages to the same release:

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_macros = { path = "../yjson/packages/yjson_macros" }
# or, for normal applications:
yjson_all = { path = "../yjson/packages/yjson_all" }
```

`yjson_native`, `yjson_schema_formats`, and `yjson_yyjson` must use the same `yjson` version because
their public facades and native bindings are compiled against the core package.
Repository manifests use path dependencies for development; release manifests
under [`release/package-manifests/`](../release/package-manifests/) use exact
`1.0.0` dependencies. During checkout-based RC use, every yjson package must
come from the same checkout and exact commit; matching manifest version strings
alone do not prove package pairing.

## Compact input ownership

`CompactJsonDocument.parseBorrowed` and `YJson.parseCompactBorrowed` retain the
caller's `Array<Byte>` without copying. The caller must treat that array as
immutable and must not write it concurrently while the document is reachable.
`parseOwned` and `parseCompactOwned` copy before parsing and isolate the
document from later caller mutation. The existing `parse` and `parseCompact`
entry points remain compatibility aliases for borrowed-input behavior.

## Resource-limit configuration and native ABI

| Surface | Contract | Compatibility disposition |
|---|---|---|
| `JsonReadConfig.maxBytes` | Input document bytes; `0` is unlimited | New for the 1.0 RC; snapshot consumers must rebuild |
| `JsonReadConfig.maxStringBytes` | Decoded UTF-8 bytes per value/key; `0` is unlimited | New for the 1.0 RC; snapshot consumers must rebuild |
| `JsonReadConfig.maxPolymorphicObjectBytes` | Root array/object raw subtree bytes; `0` is unlimited | Existing field; default changed from 16 MiB to unlimited |
| `YJ_JSON_ValidateLimits` | Allocation-free native preflight shared by native backends | Additive C symbol |
| `YJ_Compact_ParseWithLimits` | Limited Custom Native parse | Additive; old parse symbol preserved |
| `YJ_Yyjson_ParseWithLimits` | Limited yyjson parse | Additive; old parse symbol preserved |

See [resource limits](resource-limits.md) for measurement units, errors, and
stream behavior.

## Typed stream backend surface

| Package | Declaration | Contract | Compatibility disposition |
|---|---|---|---|
| `yjson` | `JsonCodec<T>` | Backend-neutral typed read/write codec using `JsonCodecReader` and `JsonCodecWriter` | Intentional breaking rename from `JsonDirectCodec<T>`; no compatibility alias |
| `yjson` | `JsonStreamBackend` and session interfaces | Connect one caller-owned stream to one typed JSON document; backend never closes caller streams | Additive interface family |
| `yjson` | `PureStreamBackend` | Default incremental typed stream backend | Additive stable default |
| `yjson` | `YJson.encodeToStreamWith/decodeFromStreamWith` backend parameter | Explicit backend selection; no silent fallback | Existing entries extended with a named optional parameter; rebuild required |
| `yjson` | `YJson.toStream/fromStream` | Provider convenience family | Additive |
| `yjson` | `JsonWriteConfig.maxBytes` | Output-byte limit; `0` is unlimited; overflow is `output_too_large` | Constructor and field added; rebuild required |
| `yjson_native` | `NativeCompactStreamBackend` | Whole-document Custom Native encode/decode via bulk tape | Additive optional-package API |
| `yjson_yyjson` | `YyjsonStreamBackend` | Whole-document supported yyjson Direct encode/decode via bulk tape | Additive optional-package API |

The shared tape and replay interfaces are matching-version generated/native
bridges, not application persistence formats. Generated polymorphic decode
captures once and replays the subtype directly; it does not serialize an AST
and parse it again. Optional Native packages and macro output must come from the
same checkout and exact commit as core.

## Stable generated-code bridge

| Package | Declaration | Contract | Intended caller |
|---|---|---|---|
| `yjson` | `JsonFastReader.suggestRawCollectionCapacity(): Int64` | Bounded hint (`4..64`) from the unread raw-array window; does not advance or retain input | Generated fast collection codecs |
| `yjson_macros` | Generated call to the bridge | Used only after the empty-array check; changes allocation strategy, not JSON semantics | `@JsonCodec` output |
| `yjson` | `JsonCodecReader.skipValueWithDepth` | Enforces the remaining syntax-depth budget while skipping an unknown subtree | Third-party reader implementations; source-breaking after rc.1, rc.2 rebuild required |
| `yjson` | `JsonDecodeContext.remainingDepth` / `JsonFastReader.skipRawWithDepth` | Connects generated typed depth state to semantic and fast subtree skipping | Matching-version generated code; rc.2 rebuild required |

The reader method is public because macro expansion runs in the consumer's
package. It is a generated-code bridge, not a promise that applications should
depend on the current capacity heuristic.

## Post-rc.1 Schema immutability change

`JsonSchema.document` changes from a public mutable field to a read-only
property returning a detached `JsonNode` copy. Existing source reads keep the
same spelling, but compiled consumers must rebuild and mutations of the returned
tree intentionally no longer change validation. The validator and reference
resolver operate on the private construction-time snapshot. The configured
external `JsonSchemaResolver` remains a documented live dependency:
applications requiring repeatable external resolution must provide an
immutable resolver.

## JSON literal and mutable-node surface

| Package | Declaration | Contract | Compatibility disposition |
|---|---|---|---|
| `yjson_macros` | `@Json({...})` | Direct compact writer; `$()` values and dynamic String keys are evaluated once left-to-right | Additive macro; requires matching core |
| `yjson_macros` | `@JsonValue({...})` | Constructs a mutable `JsonNode` tree with the same literal grammar | Additive macro; reserves the old type name |
| `yjson` | `JsonNode` | Mutable AST root with `[]` access and short scalar/container properties | Breaking rename from `JsonValue` |
| `yjson` | `YJson.nullValue/array/object/value/writeValue` | Macro bridge plus explicit construction and conversion helpers | Additive overload family |
| `yjson` | chainable `JsonArrayValue.add/set`, `JsonObjectValue.put` | Mutates and returns the same container | `put` return type changed from `Unit`; rebuild required |
| `yjson` | `JsonDocumentBackend` / `JsonDocument` | Selectable read-only document facade with deterministic resource lifecycle | Additive interface family |
| `yjson` | `YJson.parseDocument` / `PureCompactBackend` | Unified String/bytes entry; Pure Compact is the portable default | Additive overload family |
| `yjson_native` | `NativeCompactBackend` / `NativeCompactJsonBackend` | Default and configurable Custom Native facade adapters | Additive optional-package API |
| `yjson_yyjson` | `YyjsonBackend` / `YyjsonCompactJsonBackend` | Default Direct and configurable yyjson facade adapters | Additive optional-package API |
| `yjson` | `JsonPointer` / `JsonPointerException` | RFC 6901 string and URI-fragment evaluation | Additive API family |
| `yjson` | `JsonPatch` / `JsonPatchOperation` / `JsonMergePatch` | RFC 6902 and RFC 7386 copy plus atomic in-place application | Additive API family |
| `yjson` | `JsonPath` / `JsonPathMatch` | RFC 9535 parse and multi-result query with normalized paths | Additive API family |
| `yjson` | `JsonSchemaConfig` / `JsonSchemaResolver` / `JsonSchemaRegistry` | Draft 2020-12 resource resolution; core performs no network I/O | Additive API family |
| `yjson` | `JsonSchemaFormat`, `JsonSchemaFormatProvider`, `JsonSchemaFormatRegistry` | Explicit format extension seam; duplicate names reject unless replacement is requested | Additive API family |
| `yjson` | `JsonSchemaFormatMode.StrictAssertion` | Unknown format yields `unsupported_schema_format`; default remains `Annotation` | Additive enum case |
| `yjson_schema_formats` | `StandardInternationalFormats` | Optional IDNA2008, URI/IRI and URI Template provider backed by libidn2 | Additive optional-package API |

Static duplicate keys are rejected during macro expansion. Objects containing
dynamic keys use LastWins; all interpolated expressions still run once, while
only winning fields invoke their codec. `@Json` writes through
`JsonDirectWriter` and does not materialize an intermediate `JsonNode` tree.

## Optional native Float64 surface

| Package | Declaration | Contract |
|---|---|---|
| `yjson` | `JsonNativeFloatParserBackend` | Process-global optional backend interface |
| `yjson` | `installJsonNativeFloatParserBackend` / `uninstallJsonNativeFloatParserBackend` | Install or remove one backend before concurrent decoding |
| `yjson_native` | `enableYJsonNative` | Full activation installs the structural, bulk-numeric, tape, and Float64 backends as one mutually exclusive bundle |
| `yjson_native` | `enableYJsonNativeFloatOnly` / `disableYJsonNativeFloatOnly` | Isolated FloatOnly activation mode; mutually exclusive with Full and NumericOnly |
| C archive | `YJ_JSON_ParseDouble` | Validated number token, max 256 bytes; invalid bounds or declined input return `NaN` |

The native bridge is bounded and non-blocking by contract: it makes no Cangjie
calls and does not perform I/O. A `NaN` result is a decline sentinel, after
which the portable Cangjie parser is used. Install/remove operations are
process-global and must not race with decoding.

## Compatibility disposition

- Source: pre-1.0 snapshot calls that construct `JsonReadConfig` must be rebuilt and may need
  review of the changed polymorphic-object default. `JsonValue` references must
  migrate to `JsonNode`; new macro output needs the matching core release.
- ABI: `JsonReadConfig` is not claimed binary-compatible with pre-1.0 snapshots. The reader
  addition is a non-`open`, non-overriding instance method; native declarations
  are additive and the old C symbols remain available.
- Semantics: resource budgets are opt-in because all three byte limits default
  to zero. Collection preallocation and the optional Float64 parser retain
  fallback paths that preserve decoded values and errors.
- Inventory: this file and the C ABI header are release gates. Update both
  before publishing a future API change.
- Concurrency: backend installation/removal and activation-mode changes require
  exclusive process setup; they are not per-decoder synchronization APIs.

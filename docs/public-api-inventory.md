# 2.0 API/ABI change inventory

This is a release-delta inventory, not a complete yjson API reference. It records
the public surfaces changed or introduced for the 2.0.0 release candidate,
including resource-limited parsing, the reusable fast
collection bridge, and the optional native Float64 parser. The machine-readable source is
[`release/public-api-inventory.toml`](../release/public-api-inventory.toml).

Most entries are additive. `JsonReadConfig.init` and the `JsonValue` to
`JsonNode` AST-root rename are intentional 2.0 breaking changes. The latter is
required because the new unqualified `@JsonValue` macro occupies the same
Cangjie declaration namespace. The API inventory and ABI symbol inventory must
be reviewed whenever a declaration is added, removed, renamed, or changed.

## Package pairing

Generated code is compiled in the application, so `yjson_macros` cannot safely
be mixed with an older `yjson` runtime after the generated reader starts using
`JsonFastReader.suggestRawCollectionCapacity`. Use the aggregate package, or
pin all packages to the same release:

```toml
[dependencies]
yjson = "2.0.0"
yjson_macros = "2.0.0"
# or, for normal applications:
yjson_all = "2.0.0"
```

`yjson_native` and `yjson_yyjson` must use the same `yjson` version because
their public facades and native bindings are compiled against the core package.
Repository manifests use path dependencies for development; release manifests
use the exact versions above.

## Resource-limit configuration and native ABI

| Surface | Contract | Compatibility disposition |
|---|---|---|
| `JsonReadConfig.maxBytes` | Input document bytes; `0` is unlimited | New 2.0 field and constructor parameter; rebuild required |
| `JsonReadConfig.maxStringBytes` | Decoded UTF-8 bytes per value/key; `0` is unlimited | New 2.0 field and constructor parameter; rebuild required |
| `JsonReadConfig.maxPolymorphicObjectBytes` | Root array/object raw subtree bytes; `0` is unlimited | Existing field; default changed from 16 MiB to unlimited |
| `YJ_JSON_ValidateLimits` | Allocation-free native preflight shared by native backends | Additive C symbol |
| `YJ_Compact_ParseWithLimits` | Limited Custom Native parse | Additive; old parse symbol preserved |
| `YJ_Yyjson_ParseWithLimits` | Limited yyjson parse | Additive; old parse symbol preserved |

See [resource limits](resource-limits.md) for measurement units, errors, and
stream behavior.

## Stable generated-code bridge

| Package | Declaration | Contract | Intended caller |
|---|---|---|---|
| `yjson` | `JsonFastReader.suggestRawCollectionCapacity(): Int64` | Bounded hint (`4..64`) from the unread raw-array window; does not advance or retain input | Generated fast collection codecs |
| `yjson_macros` | Generated call to the bridge | Used only after the empty-array check; changes allocation strategy, not JSON semantics | `@JsonCodec` output |

The reader method is public because macro expansion runs in the consumer's
package. It is a generated-code bridge, not a promise that applications should
depend on the current capacity heuristic.

## JSON literal and mutable-node surface

| Package | Declaration | Contract | Compatibility disposition |
|---|---|---|---|
| `yjson_macros` | `@Json({...})` | Direct compact writer; `$()` values and dynamic String keys are evaluated once left-to-right | Additive macro; requires matching core |
| `yjson_macros` | `@JsonValue({...})` | Constructs a mutable `JsonNode` tree with the same literal grammar | Additive macro; reserves the old type name |
| `yjson` | `JsonNode` | Mutable AST root with `[]` access and short scalar/container properties | Breaking rename from `JsonValue` |
| `yjson` | `YJson.nullValue/array/object/value/writeValue` | Macro bridge plus explicit construction and conversion helpers | Additive overload family |
| `yjson` | chainable `JsonArrayValue.add/set`, `JsonObjectValue.put` | Mutates and returns the same container | `put` return type changed from `Unit`; rebuild required |

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

- Source: 1.x calls that construct `JsonReadConfig` must be rebuilt and may need
  review of the changed polymorphic-object default. `JsonValue` references must
  migrate to `JsonNode`; new macro output needs the matching core release.
- ABI: `JsonReadConfig` is not claimed binary-compatible with 1.x. The reader
  addition is a non-`open`, non-overriding instance method; native declarations
  are additive and the old C symbols remain available.
- Semantics: resource budgets are opt-in because all three byte limits default
  to zero. Collection preallocation and the optional Float64 parser retain
  fallback paths that preserve decoded values and errors.
- Inventory: this file and the C ABI header are release gates. Update both
  before publishing a future API change.
- Concurrency: backend installation/removal and activation-mode changes require
  exclusive process setup; they are not per-decoder synchronization APIs.

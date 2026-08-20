# Public API inventory

This inventory records the public surfaces introduced for the 1.0.0 release
candidate by the reusable fast collection bridge and the optional native
Float64 parser. The machine-readable source is
[`release/public-api-inventory.toml`](../release/public-api-inventory.toml).

The entries are additive. They do not remove or change an existing public
signature, but they are still release-surface changes: the API inventory and
ABI symbol inventory must be reviewed whenever one is added, removed, or
renamed.

## Package pairing

Generated code is compiled in the application, so `yjson_macros` cannot safely
be mixed with an older `yjson` runtime after the generated reader starts using
`JsonFastReader.suggestRawCollectionCapacity`. Use the aggregate package, or
pin all packages to the same release:

```toml
[dependencies]
yjson = "1.0.0"
yjson_macros = "1.0.0"
# or, for normal applications:
yjson_all = "1.0.0"
```

`yjson_native` must use the same `yjson` version because its public backend
interface and generated `@FastNative` bindings are compiled against the core
package. Repository manifests use path dependencies for development; release
manifests use the exact versions above.

## Stable generated-code bridge

| Package | Declaration | Contract | Intended caller |
|---|---|---|---|
| `yjson` | `JsonFastReader.suggestRawCollectionCapacity(): Int64` | Bounded hint (`4..64`) from the unread raw-array window; does not advance or retain input | Generated fast collection codecs |
| `yjson_macros` | Generated call to the bridge | Used only after the empty-array check; changes allocation strategy, not JSON semantics | `@JsonCodec` output |

The reader method is public because macro expansion runs in the consumer's
package. It is a generated-code bridge, not a promise that applications should
depend on the current capacity heuristic.

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

- Source: existing consumers remain source-compatible; new macro output needs
  the matching core release.
- ABI: the reader addition is a non-`open`, non-overriding instance method;
  native declarations are additive symbols/interfaces. Existing symbols are
  not removed or retyped.
- Semantics: collection preallocation and the optional Float64 parser have
  fallback paths that preserve decoded values and errors.
- Inventory: this file and the C ABI header are release gates. Update both
  before publishing a future API change.
- Concurrency: backend installation/removal and activation-mode changes require
  exclusive process setup; they are not per-decoder synchronization APIs.

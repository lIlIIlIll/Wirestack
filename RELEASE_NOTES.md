# Release notes — 1.0.0-rc.1

`1.0.0-rc.1` 已创建 annotated tag，尚未发布到 registry 或完成 hosted CI。候选源码提交
`42c79d2f271b756775583a2ce09b2ce64cb6497b` 已通过本地 fresh-checkout gates 与 package
rehearsal。Hosted CI 尚未运行，但 release owner 已在 2026-08-22 明确批准其为
`NON-BLOCKING`。当前 cjpm manifest 只能使用三段数字版本，因此 checked-in manifests
写作 `1.0.0`；这不表示正式版已经发布。候选阶段可使用 `1.0.0-rc.1` tag 的 checkout
path dependency，所有 yjson package 必须来自同一 checkout。

## JSON literal syntax and AST rename

`yjson_macros` now exports expression macros `@Json({...})` for direct compact
writing and `@JsonValue({...})` for mutable-tree construction. Both accept
nested object/array literals, trailing commas, value interpolation with `$()`,
and dynamic String keys. Interpolations run exactly once from left to right;
dynamic collisions use LastWins, and codecs run only for winning fields.

The mutable AST root type is now `JsonNode` instead of `JsonValue`. This is an
intentional source/ABI break: Cangjie macro and type declarations share a name,
so the old type name cannot coexist with the requested unqualified
`@JsonValue` macro. New indexing, short scalar properties, fluent array/object
builders, and `YJson.value` conversion helpers accompany the rename.

## Breaking configuration change

`JsonReadConfig` now exposes `maxBytes` and `maxStringBytes`, and
`maxPolymorphicObjectBytes` applies to public root-container parse paths. All
three byte limits default to `0` (unlimited). Adding constructor parameters and
changing the previous 16 MiB default requires applications and all paired yjson
packages to be rebuilt together for 1.0.0-rc.1.

Pure Cangjie, Custom Native, and yyjson now produce the same public resource
error codes. The native C ABI is additive: old parse symbols remain available,
while the limited entry points validate before DOM allocation.

This candidate provides a portable Pure Cangjie JSON library plus two explicit
native DOM packages:

- Pure Cangjie remains the default for AST, typed codecs, streams, schema, and
  Compact DOM.
- Custom Native Compact is a supported opt-in path for deterministic native
  ownership, lower-memory large-document scenarios, and controlled fallback.
- yyjson Direct is a supported opt-in, vendored yyjson 0.12.0 backend for coarse
  native query, traversal, and serialization.

Native documents require deterministic `close()` and external synchronization.
They do not automatically accelerate `JsonNode.parse`. `yjson_all` now
aggregates only the core and AST macros; it no longer silently builds or enables
Custom Native.

The release candidate adds source-only packaging checks, independent optional
package gates, warning-clean native builds, sanitizer/differential-fuzz entry
points, backend-selection documentation, and complete Apache-2.0 / yyjson MIT
license material.

## Migration quick reference

```cangjie
// pre-1.0 snapshot
let value: JsonValue = ...

// 1.0 release candidate
let value: JsonNode = ...
```

For untrusted input, add explicit byte budgets when rebuilding the new config:

```cangjie
let config = JsonReadConfig(
    maxDepth: 128,
    maxBytes: 8 * 1024 * 1024,
    maxStringBytes: 1024 * 1024,
    maxPolymorphicObjectBytes: 4 * 1024 * 1024
)
```

| Package | Pairing requirement |
| --- | --- |
| `yjson_macros` | exact `yjson` version |
| `yjson_all` | internally matched core + macros |
| `yjson_native` | exact `yjson` version |
| `yjson_yyjson` | exact `yjson` version |

See the complete [pre-1.0 to 1.0 migration guide](docs/migration/pre-1.0-to-1.0.md).
Release validation belongs to the [RC evidence snapshot](release/1.0.0-rc.1/evidence.md),
not to the user migration narrative.

Known limits: Linux x86_64 is the only qualified platform; AArch64 and musl are
not yet qualified. Native resource access is not thread-safe. Error messages and
some parse-error categories are semantically compatible but not identical
between backends.

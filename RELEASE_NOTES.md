# Release notes draft — 2.0.0 release candidate

## Breaking configuration change

`JsonReadConfig` now exposes `maxBytes` and `maxStringBytes`, and
`maxPolymorphicObjectBytes` applies to public root-container parse paths. All
three byte limits default to `0` (unlimited). Adding constructor parameters and
changing the previous 16 MiB default requires applications and all paired yjson
packages to be rebuilt together for 2.0.0.

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
They do not automatically accelerate `JsonValue.parse`. `yjson_all` now
aggregates only the core and AST macros; it no longer silently builds or enables
Custom Native.

The release candidate adds source-only packaging checks, independent optional
package gates, warning-clean native builds, sanitizer/differential-fuzz entry
points, backend-selection documentation, and complete Apache-2.0 / yyjson MIT
license material.

GitCode CI workflows now expose separate core, examples, external macro,
Custom Native, yyjson, Clang/GCC, sanitizer, short-fuzz, and symbol-isolation
gates, with an extended 50k fuzz workflow. They require a self-hosted Linux
x86_64 runner carrying a coherent Cangjie 1.1 SDK. The same job matrix has a
full fresh-source local simulation entry point for release preflight.

The yyjson package now localizes its vendored implementation symbols without
modifying upstream 0.12.0 sources. A pinned yyjson 0.11.1 co-link fixture passes
both shared-library load orders. Registry-style source artifacts with exact
2.0.0 dependencies also passed isolated core, macro, Custom Native, and yyjson
consumer builds before publication.

Known limits: Linux x86_64 is the only qualified platform; AArch64 and musl are
not yet qualified. Native resource access is not thread-safe. Error messages and
some parse-error categories are semantically compatible but not identical
between backends.

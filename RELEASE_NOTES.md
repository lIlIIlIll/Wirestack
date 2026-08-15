# Release notes draft — 1.0.0 release candidate

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
1.0.0 dependencies also passed isolated core, macro, Custom Native, and yyjson
consumer builds before publication.

Known limits: Linux x86_64 is the only qualified platform; AArch64 and musl are
not yet qualified. Native resource access is not thread-safe. Error messages and
some parse-error categories are semantically compatible but not identical
between backends.

# yjson_macros

Build-time `@JsonCodec` macro module for `yjson`. Most applications
should depend on `yjson_all`, which combines the runtime and this macro
module without enabling a native backend.

Generated fast collection codecs call the public
`JsonFastReader.suggestRawCollectionCapacity()` bridge in the runtime. The
macro package is therefore source-version coupled to `yjson`: use matching
versions (currently `yjson_macros = "1.0.0"` with `yjson = "1.0.0"`). The
repository development manifest uses a path dependency because the core
package also uses the macro during its build; release manifests pin the exact
central-repository versions. Prefer `yjson_all = "1.0.0"` for applications so
the pair is selected together.

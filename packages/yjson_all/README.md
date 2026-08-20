# yjson_all

Aggregate import for the `yjson` runtime and `@JsonCodec` macros. This
module does not build, install, or enable either optional native DOM backend.

`yjson_all` is the supported way to keep the runtime and macro versions
aligned. Its 1.0.0 release pins `yjson = "1.0.0"` and
`yjson_macros = "1.0.0"`; do not combine the aggregate package with a different
core or macro release.

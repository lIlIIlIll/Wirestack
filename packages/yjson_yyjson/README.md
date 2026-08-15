# yjson_yyjson

Supported opt-in yyjson Direct Native DOM backend for `yjson`, vendoring
unmodified yyjson 0.12.0 under the MIT License.

The module is source-built and offline. Documents are explicit resources and
are not thread-safe. Its Cangjie shared library localizes the vendored
`yyjson_*` implementation symbols, so an application may independently link a
second yyjson version. The vendored upstream sources remain unmodified.

See the suite-level `docs/backends.md` and `THIRD_PARTY_NOTICES.md`.

# yjson_native

Supported opt-in Custom Native Compact DOM backend for `yjson`.

The module is source-built with a C11 compiler. Documents are explicit
resources: close them deterministically. They are not thread-safe; callers must
provide external synchronization and `close()` requires exclusive ownership.

See the suite-level `docs/backends.md` for the complete contract.

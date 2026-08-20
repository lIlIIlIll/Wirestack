# yjson_native

Supported opt-in Custom Native Compact DOM backend for `yjson`.

The package must use the same `yjson` release as its core dependency (the
current release pair is `yjson_native = "1.0.0"` and `yjson = "1.0.0"`).

The module is source-built with a C11 compiler. Documents are explicit
resources: close them deterministically. They are not thread-safe; callers must
provide external synchronization and `close()` requires exclusive ownership.

See the suite-level `docs/backends.md` for the complete contract.

`enableYJsonNative()` also installs the optional Float64 token parser used by
generated fast codecs. `enableYJsonNativeFloatOnly()` installs only that seam
for isolated deployments and measurements; its matching
`disableYJsonNativeFloatOnly()` returns to the uninstalled state.
`enableYJsonNativeNumericOnly()` and its matching disable function are a
separate mode. Full, FloatOnly, and NumericOnly activation modes are mutually
exclusive, and selecting another mode without disabling the active isolated
mode throws `IllegalStateException`.

The `@FastNative` bridge receives an already validated JSON number, rejects
tokens over 256 bytes, uses a bounded stack buffer, and performs no Cangjie
calls or blocking/I/O work. A missing or declined native result falls back to
the portable parser; the core `yjson` package never installs this backend by
itself. Install or remove the global backend before starting concurrent
decoders; do not race enable/disable calls with decoding. The C symbol and
contract are listed in [`docs/public-api-inventory.md`](../../docs/public-api-inventory.md).

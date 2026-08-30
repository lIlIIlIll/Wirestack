# yjson_native_primitives

Internal, versioned Linux x86_64 primitive provider for `yjson`. Applications
should depend on `yjson_native_accel` instead of importing this package.

The package owns the native scanner archive and the closed provider SPI used
during process startup. It does not expose a second JSON API.

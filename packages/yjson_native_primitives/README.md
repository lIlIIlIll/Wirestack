# yjson_native_primitives

Internal, versioned Linux x86_64 primitive provider for `yjson`. Applications
should depend on `yjson_native_accel` instead of importing this package.

The package owns the native scanner archive and the closed provider SPI used
during process startup. It does not expose a second JSON API.

## Toolchain prerequisites

Building this package requires, on the host:

- Python 3 (runs `scripts/build_native_scanner.py`)
- A C11 compiler (default `clang`; override with `CC`)
- `ar` (override with `AR`)
- Linux x86_64 (`build_native_scanner.py` fails fast on any other host)

`scripts/build_native_scanner.py` checks for all three tools up front and
always rebuilds the scanner archive.

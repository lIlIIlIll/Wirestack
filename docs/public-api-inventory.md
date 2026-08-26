# yjson 2.0 public API inventory

This document explains the 2.0 release boundary. The complete generated declaration list is
[`release/public-api-snapshot.txt`](../release/public-api-snapshot.txt); the reviewed breaking and
additive changes are recorded in
[`release/public-api-inventory.toml`](../release/public-api-inventory.toml). Both files are checked
by `python3 scripts/check_api_inventory.py`.

## Default product surface

Ordinary applications use the GC-managed, cross-platform engine through:

```cangjie
YJson.toJson(value)
YJson.fromJson<T>(text)
YJson.parseDocument(text)
```

`JsonDocument` exposes read-only views, `materialize()` and JSON output. It has no backend
identity, `Resource`, `close()` or `isClosed()`. Default stream entry points are incremental and
have no backend parameter.

`JsonReadConfig` and `JsonWriteConfig` compose `JsonReadLimits` and `JsonWriteLimits`. The same
limits, duplicate-field policy, number rules, paths and errors apply to built-in, generated,
stream and accelerated execution.

## Generated-code protocol

`yjson` and `yjson_macros` are one release unit. Macro output targets `generated_support.v1` and
embeds protocol version 1. A stable v1 SPI permits patch-version runtime updates; a protocol
mismatch fails explicitly instead of relying on exact-checkout matching.

The implementation contains direct reader/writer helpers for the runtime and macro bridge, but
generated codec source refers only to the versioned support names. These helpers are not the
recommended application API.

## Optional packages

| Package | Purpose | Lifecycle |
| --- | --- | --- |
| `yjson_native_accel` | One startup call, `YJsonNativeAccel.initialize()` | Freezes process engine; no uninstall or runtime switching |
| `yjson_algorithms` | Pointer, Patch, Merge Patch, JSONPath and Schema | Finite default work budgets; `.unlimited` is explicit |
| `yjson_backends` | Advanced Custom Native/yyjson DOM and WholeDocument stream adapters | Explicit `BackendJsonDocument` resource ownership |
| `yjson_schema_formats` | Optional international Schema formats | Installed into an explicit registry |

Schema resource URIs resolve only through an injected `UriResolver`; core performs no network
access.

## Compatibility disposition

2.0 is intentionally source- and ABI-breaking. It removes default backend selection and document
resource methods, moves algorithms and advanced backends to separate packages, replaces mutable
runtime backend installation with a one-way startup freeze, and groups resource limits into
limits objects. No compatibility aliases or deprecated shims are provided. See
[`migration/1.x-to-2.0.md`](migration/1.x-to-2.0.md).

Historical 1.0 release evidence remains under `release/1.0.0-*`; it describes immutable historical
artifacts, not the 2.0 API.

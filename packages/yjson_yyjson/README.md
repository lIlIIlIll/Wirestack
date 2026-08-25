# yjson_yyjson

Supported opt-in yyjson Direct Native DOM backend for `yjson`, vendoring
unmodified yyjson 0.12.0 under the MIT License.

The module is source-built and offline. Documents are explicit resources and
are not thread-safe. Its Cangjie shared library localizes the vendored
`yyjson_*` implementation symbols, so an application may independently link a
second yyjson version. The vendored upstream sources remain unmodified.

The package must use the same `yjson` release as its core dependency.

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_yyjson = { path = "../yjson/packages/yjson_yyjson" }
```

```cangjie
import yjson.*
import yjson_yyjson.*

let bytes = unsafe { "{\"n\":42}".rawData() }
try (document = YJson.parseDocument(bytes, backend: YyjsonBackend)) {
    println(document.getRootInt("n").getOrThrow())
}
```

This is the same facade used by the portable `PureCompactBackend` and optional
`NativeCompactBackend`. Use `YyjsonCompactJsonDocument` directly for storage
statistics, traversal checksum, or qualification controls.

The optional package also exposes `YyjsonStreamBackend` for typed caller-owned
streams:

```cangjie
YJson.encodeToStreamWith(UserJson, user, output,
    backend: YyjsonStreamBackend)
let user = YJson.decodeFromStreamWith(UserJson, input,
    backend: YyjsonStreamBackend)
```

This supported Direct-mode backend buffers one whole document, crosses the ABI
only in bulk, preserves Pure `JsonWriteConfig` output bytes, and never closes
caller streams or silently switches to the Pure backend.

Use the same `yjson` version. See the suite-level
[`docs/backends.md`](../../docs/backends.md) and
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

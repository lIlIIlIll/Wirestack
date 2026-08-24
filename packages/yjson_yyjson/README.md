# yjson_yyjson

Supported opt-in yyjson Direct Native DOM backend for `yjson`, vendoring
unmodified yyjson 0.12.0 under the MIT License.

The module is source-built and offline. Documents are explicit resources and
are not thread-safe. Its Cangjie shared library localizes the vendored
`yyjson_*` implementation symbols, so an application may independently link a
second yyjson version. The vendored upstream sources remain unmodified.

`1.0.0-rc.1` has not been published to the registry, and current cjpm manifests
cannot express a prerelease suffix. Use matching checkout path dependencies.

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

Use the same `yjson` version. See the suite-level
[`docs/backends.md`](../../docs/backends.md) and
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

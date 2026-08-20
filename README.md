# yjson

`yjson` 是面向仓颉 1.1.0 的 JSON 库，提供可修改的 `JsonValue` AST、
直接 typed codec、流式 API、JSON Schema 子集和紧凑只读 DOM。纯仓颉 core 是默认
实现；两个 Native DOM 后端均为显式 opt-in。

正式发布使用仓颉中心仓中的精确版本依赖；源码 checkout 仍可按各 package
manifest 中的 path dependency 进行开发构建。

## 安装

普通应用只需加入 core package：

```toml
[dependencies]
yjson = "1.0.0"
```

## 运行要求

Pure Cangjie 只要求仓颉 SDK 1.1.0，且 `cjc`、`cjpm` 位于 `PATH`。Native package
另外要求 Python 3、C11 compiler 和 `ar`。Linux x86_64 是当前唯一 qualified 平台。

## 快速开始

只使用 core 不需要 C 编译器、yyjson 或 native archive：

```cangjie verify=run expect="Alice"
package yjson_examples

import yjson.*

main(): Unit {
    let value = YJson.parse("{\"name\":\"Alice\",\"age\":30}")
    let object = value.asObject()
    object.put("active", JsonBoolValue(true))
    println(object.get("name").getOrThrow().asString().value)
    println(YJson.stringifyPretty(object))
}
```

仓库内的可执行首例不使用 Native：

```bash command-ok
cd packages/examples
cjpm run
```

## Typed codec 与宏

内置 codec 可以直接使用：

```cangjie noverify=usage-fragment
let encoded = YJson.encodeStringWith(StringJson, "仓颉 JSON")
let decoded = YJson.decodeStringWith(StringJson, encoded)
```

调用方需要 `@JsonCodec` 时，依赖 runtime+macros 聚合包。该聚合包不再隐式安装
或启用 Native：

```toml
[dependencies]
yjson_all = "1.0.0"
```

```cangjie noverify=usage-fragment
import yjson_all.*

@JsonCodec
class User {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}

let text = YJson.toJson(User(7, "Alice"))
let user = YJson.fromJson<User>(text)
```

同一个支持 compact fast reader 的生成对象 codec 被高频重复解码时，可以在循环外
解析一次 fast decoder，避免每次泛型调用的运行时类型解析：

```cangjie noverify=usage-fragment
let decoder = YJson.fastDecoder(UserJson)
let userFromString = decoder.decodeString(text)
let userFromBytes = decoder.decodeBytes(unsafe { text.rawData() })
```

无配置重载使用生成的 compact fast reader；传入显式 `JsonReadConfig` 时保持普通
codec 的完整配置语义。不提供生成式 fast-decoder 合同的自定义 codec 会抛出
`JsonException`，其错误码为 `codec_contract`。

`@JsonCodec` 在调用方编译期间处理调用方 `src/` 中的类型，不依赖运行时反射。
泛型实参必须有内置 codec 或同样可生成的 codec；参与生成的实例字段必须显式声明
类型，不可变字段需要由可用构造函数接收。完整下游 fixture 位于
[`packages/codec_integration`](packages/codec_integration)。

### Public fast bridges and package pairing

生成的 fast collection codec 会调用 `JsonFastReader` 的公开容量提示
bridge；该方法只服务于宏生成代码，不是应用层的容量保证。可选的
`JsonNativeFloatParserBackend` 和 `yjson_native` 的 Float64 `@FastNative`
bridge 也属于显式、进程级 backend API。它们的稳定契约、并发边界、C ABI
和兼容性清单见 [Public API inventory](docs/public-api-inventory.md)。

由于宏代码在调用方编译，`yjson`、`yjson_macros`、`yjson_all` 和
`yjson_native` 必须使用同一发布版本；当前版本是 `1.0.0`。普通应用优先使用
`yjson_all = "1.0.0"`，直接组合 runtime 与 macro 时也要分别固定为
`yjson = "1.0.0"` 和 `yjson_macros = "1.0.0"`。

## 选择 JSON representation

| Backend | 默认 | 内存与生命周期 | 适用场景 | 不适用场景 |
|---|---|---|---|---|
| Pure Cangjie | 是 | GC 管理，无显式关闭 | typed codec、AST、可移植默认、语义 oracle | 受 GC large-object geometry 限制的超大 DOM |
| Custom Native Compact | 否，受支持 opt-in | C-owned，必须 `close()` | 较低内存、受控语义 fallback、超大对象 lookup | 希望完全 GC 管理的 API |
| yyjson Direct Native DOM | 否，受支持 opt-in | C-owned，必须 `close()`；部分 workload 以空间换速度 | 实测通用 Native DOM 最快路径、coarse query、bulk traversal、serialize | 自动加速 `JsonValue.parse`，或百万节点逐节点 FFI 遍历 |

详细合同见 [Backend 指南](docs/backends.md)。选择 backend 是显式 API 决策；库不按
输入大小或文件名自动切换。

### Pure Cangjie Compact

```cangjie noverify=usage-fragment
let bytes = unsafe { "{\"name\":\"Alice\"}".rawData() }
let document = YJson.parseCompact(bytes)
println(document.root().get("name").getOrThrow().asString())
```

### Custom Native Compact

额外依赖 `packages/yjson_native`。它从源码构建 C11 archive，不依赖 yyjson：

```cangjie noverify=requires-native-package
import yjson.*
import yjson_native.*

let bytes = unsafe { "{\"name\":\"Alice\"}".rawData() }
try (document = NativeCompactJsonDocument.parse(bytes)) {
    println(document.root().get("name").getOrThrow().asString())
}
```

### yyjson Direct Native DOM

额外依赖 `packages/yjson_yyjson`。包内固定 vendored yyjson 0.12.0，构建无需
网络：

```cangjie noverify=requires-yyjson-package
import yjson.*
import yjson_yyjson.*

let bytes = unsafe { "{\"count\":42}".rawData() }
try (document = YyjsonCompactJsonDocument.parse(bytes)) {
    println(document.getRootInt("count").getOrThrow())
    println(document.toString())
}
```

Native document 是显式 `Resource`。正常路径必须确定性 `close()`；析构器只用于
泄漏兜底。它们不是线程安全对象：调用方必须外部同步，`close()` 需要独占所有权，
不得与 lookup、traversal 或 serialization 并发。value view 会持有 owner，但 owner
关闭后所有操作确定失败。

## 读取、输出与错误

默认读取忽略未知字段、重复键 LastWins，并尽量把整数保留为精确 `Int64`。
`JsonReadConfig` 可选择 Reject duplicate、Reject unknown field 或
`PreserveLiteral`。decoded key 参与重复判断，所以 `"a"` 与 `"\u0061"` 是同一个键。

`JsonException` 提供 `code`、`byteOffset`、`line`、`column` 和 `path`。三个 backend
都拒绝 malformed JSON，但 Native adapter 的部分语法错误类别比 Pure 粗；不要依赖
底层 yyjson 数字错误码。精确矩阵见 [Backend 指南](docs/backends.md)。

`JsonWriteConfig.compact` 生成紧凑输出，`JsonWriteConfig.pretty` 生成格式化输出。
`encodeToStreamWith` / `decodeFromStreamWith` 不关闭调用方 stream；当前 stream decode
会先读完剩余输入，并非恒定内存增量 parser。

## JSON Schema

`JsonSchema.parse` 读取 Schema；`validate` 返回错误列表，`validateOrThrow` 抛出
`JsonValidationError`。当前覆盖 boolean schema、本地 `$ref`、`type`、`enum`、
`const`、数值/字符串边界、`required`、`properties`、`items`、`allOf`、`anyOf`、
`oneOf` 和 `not`，不是完整 draft 2020-12 实现。

## 构建与验证

要求仓颉 SDK 1.1.0。纯 core 只要求 `cjc`/`cjpm`。Native package 另外要求 Python 3、
C11 编译器和 `ar`；构建脚本尊重 `CC` 与 `AR`。

```bash command-ok
cjpm test
(cd packages/yjson_native && cjpm test)
(cd packages/yjson_yyjson && cjpm test)
YJSON_FUZZ_CASES=5000 scripts/release_native_checks.sh
```

仓库的 GitCode CI 将这些 gate 拆成 core、examples、外部 macro consumer、Custom
Native、yyjson、Clang/GCC、sanitizer、短 fuzz 和 yyjson 双版本符号隔离 job；50k
fuzz 为定时/手动扩展 gate。CI runner 必须预装一套一致的仓颉 1.1 SDK。yyjson
implementation symbols 在最终 shared library 中被 localize，不会导出给宿主应用。

Linux x86_64 是当前唯一 qualified 平台。production Native DOM 不要求 AVX2；scanner
的可选 SIMD path 有 scalar fallback。AArch64 仅为 source-portable candidate，尚未实际
qualification；musl 未验证。

## 发布与许可证

- 项目许可：[Apache License 2.0](LICENSE)
- 可选 yyjson 许可与来源：[Third-party notices](THIRD_PARTY_NOTICES.md)
- Release checklist：[docs/release-checklist.md](docs/release-checklist.md)
- 性能方法与限制：[docs/performance.md](docs/performance.md)
- 实现边界：[docs/architecture.md](docs/architecture.md)

历史 benchmark、competitor 和 `target/perf-results` 不属于 runtime package。性能数字只
能在 representation、语义、机器、SDK 和构建参数一致时比较。

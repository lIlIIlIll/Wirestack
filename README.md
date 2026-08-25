<!-- BEAUTIFIED -->

<h1 align="center">yjson</h1>

<p align="center">
  <strong>面向仓颉的高性能 JSON 库，提供编译期生成的类型安全 Codec、JSON 字面量、可修改 AST 与流式 API。</strong>
  <br />
  <em>Pure Cangjie by default · Compile-time generated codecs · Explicit native opt-ins</em>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-yellow?style=flat" alt="Apache License 2.0" /></a>
  <img src="https://img.shields.io/badge/Cangjie-1.1.0-3B82F6?style=flat" alt="Cangjie 1.1.0" />
  <img src="https://img.shields.io/badge/version-1.0.0--rc.1-10B981?style=flat" alt="Version 1.0.0-rc.1" />
</p>

yjson 默认使用纯仓颉实现。Native backend 是面向特定内存与遍历场景的显式可选项，
不会被 core 或宏包隐式启用。

## Why yjson?

- **编译期生成 Codec** — `@JsonCodec` 在调用方生成类型安全的编解码代码，不依赖运行时反射。
- **直接输出的 JSON 字面量** — `@Json({...})` 支持运行时插值，并直接驱动 writer 生成紧凑 JSON。
- **统一的数据模型** — 同一套库覆盖 typed codec、可修改 `JsonNode` 与低内存只读 `CompactJsonDocument`。
- **Pure Cangjie 默认实现** — core 不包含隐式 native 依赖；Custom Native 与 yyjson backend 均需显式选择。
- **可切换 typed Stream backend** — 同一 `JsonCodec<T>` 可使用默认 Pure incremental，或显式选择 whole-document Native backend。
- **明确的输入 contract** — 未知字段、重复 key、数字保留和资源预算都由公开配置控制。

## 安装

要求仓颉 SDK 1.1.0，且 `cjc`、`cjpm` 位于 `PATH`。

`1.0.0-rc.1` 当前尚未发布到 registry。当前 cjpm manifest 只接受三段数字版本，无法
表达 `-rc.1`；因此候选阶段只支持 checkout path dependency，正式发布坐标将是 `1.0.0`。

普通应用推荐使用聚合包，它同时提供 runtime、`@JsonCodec`、`@Json` 和
`@JsonValue`：

```toml
[dependencies]
yjson_all = { path = "../yjson/packages/yjson_all" }
```

只需要 parser、AST 或内置 codec 时，可以仅依赖 core：

```toml
[dependencies]
yjson = { path = "../yjson" }
```

候选阶段应使用 `1.0.0-rc.1` tag，并确保所有 yjson package 来自同一版本。发布身份与
验证状态见 [release evidence](release/1.0.0-rc.1/evidence.md)。

## 快速开始

```cangjie
package yjson_demo

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

main(): Unit {
    let text = YJson.toJson(User(7, "Alice"))
    let user = YJson.fromJson<User>(text)
    println(user.name)
}
```

## 核心 API

| 需求 | 推荐入口 | 返回值 |
|---|---|---|
| 类型安全编解码 | `YJson.toJson` / `YJson.fromJson<T>` | typed value / `String` |
| 直接构造 JSON 文本 | `@Json({...})` | `String` |
| 构造并修改 JSON 树 | `@JsonValue({...})` | `JsonNode` |
| 解析或输出 JSON 树 | `YJson.parse` / `YJson.stringify` | `JsonNode` / `String` |
| 可切换后端的只读查询 | `YJson.parseDocument` | `JsonDocument`（默认 Pure Compact） |
| 自定义或内置 codec | `encode*With` / `decode*With` | typed value / JSON |
| Stream I/O | `encodeToStreamWith` / `decodeFromStreamWith` | caller-owned stream；默认 Pure，可显式选择 backend |

### Parser 与 AST

```cangjie
let value = YJson.parse("{\"name\":\"Alice\",\"age\":30}")
let object = value.asObject()
object.put("active", JsonBoolValue(true))

println(object.get("name").getOrThrow().asString().value)
println(YJson.stringifyPretty(object))
```

### 重复 typed decode

高频复用同一个 generated codec 时，可以缓存 fast decoder：

```cangjie
let decoder = YJson.fastDecoder(UserJson)
let fromString = decoder.decodeString(text)
let fromBytes = decoder.decodeBytes(unsafe { text.rawData() })
```

无配置重载使用 compact fast reader；显式传入 `JsonReadConfig` 时保留完整配置语义。

## JSON 字面量

`@Json` 直接驱动 `JsonDirectWriter`。`$()` 可以插入运行时值，并按从左到右的顺序各
求值一次：

```cangjie
let key = "user"
let id: Int64 = 7

let text = @Json({
    "ok": true,
    "items": [1, null, $(id)],
    $(key): $(User(id, "Alice")),
})
```

`@JsonValue` 返回可修改的 `JsonNode`：

```cangjie
let root = @JsonValue({"name": "Alice", "items": [1, 2]})
root["name"] = "Bob"
root["items"][0] = 9
println(YJson.stringify(root))
```

静态重复 key 是编译错误。对象包含动态 key 时，运行时冲突采用 LastWins。

## 库能力对比

下表比较公开文档可确认的主要能力，不代表性能排名。`◐` 表示部分或间接支持，`—` 表示
本次查阅的公开资料未确认该能力，并非断言任何扩展都无法实现。

| 能力 | yjson | stdx.json | cjfast_json | fastjson2 | Go yyjson |
| --- | --- | --- | --- | --- | --- |
| Generated typed mapping | ✅ `@JsonCodec` | — | ✅ `@JsonAdapter` | ✅ ASM / `@JSONCompiler` | ◐ typed 入口委托 `encoding/json` |
| Mutable / compact DOM | ✅ / ✅ | ✅ / — | — / — | ✅ / ◐ | ✅ / ✅ |
| Stream/token I/O | ✅ backend 可选 | ✅ | ✅ | ✅ | ◐ incremental DOM |
| Polymorphism / custom codec | ✅ / ✅ | — / ✅ | — / ✅ | ✅ / ✅ | — / ◐ |
| Schema / standard path-patch | ✅ 2020-12 required + optional suites / ✅ Pointer, Patch, Merge, JSONPath | — / ◐ | — / — | ✅ / ✅ JSONPath | — / ✅ Pointer/Patch |
| Cangjie 直接依赖 | ✅ | ✅ SDK | ✅ | N/A（Java/JVM） | N/A（Go） |

完整矩阵、符号含义、跨 runtime 边界与来源见[库能力对比](docs/library-comparison.md)。性能
数据仍以独立测量批次为准，不能由这张能力表推导。

标准文档操作入口包括 `JsonPointer`（RFC 6901）、`JsonPatch`（RFC 6902）、
`JsonMergePatch`（RFC 7386）和 `JsonPath`（RFC 9535）；Schema 只接受 draft 2020-12，
外部 `$ref` 由应用注入 `JsonSchemaResolver`，core 不执行网络访问。用法与边界见
[Schema](docs/schema.md)和[标准路径与 Patch](docs/path-and-patch.md)。

## 性能

在 37 项同语义测量中，yjson 有 29 项 paired median 低于 `cjfast_json`。下表选择
通过稳定性门槛的代表 workload，并保留领先与落后方向：

| Workload | yjson | cjfast_json | Latency ratio Y/C | Direction |
|---|---:|---:|---:|---|
| Large Map encode / string¹ | 119.887 µs | 132.802 µs | **0.903x** | yjson faster 11/11 |
| Large Array encode / string | 101.547 µs | 75.899 µs | 1.338x | cjfast_json faster 11/11 |
| `TemporalStats` encode / string | 20.879 µs | 21.824 µs | **0.957x** | yjson faster 11/11 |

`Latency ratio Y/C` 按 `yjson median / cjfast_json median` 计算，小于 1 表示 yjson
耗时更低。¹ Large Map 来自独立稳定复测。绝对时间只代表对应 workload，不应外推为
所有输入或平台上的性能排名。

更多结果和适用边界见[性能说明](docs/performance/README.md)。不同 runtime 或不同批次的
数字不能拼接为统一排名。

跨 runtime 的 DOM 测量中，Go `dwisiswant0/yyjson` 在全部 12 项 paired median 中更低；
稳定行的 `yjson / Go yyjson` latency ratio 几何均值为 **5.45x**。这不是 typed codec
对比，详见 [Go yyjson DOM 结果](docs/performance/results/2026-08-22-go-yyjson.md)。

## 兼容性与限制

- **当前资格平台** — 1.0 RC 的阻断 build、tests、standards、sanitizer、fuzz 和 external consumer 以 Linux x86_64 为准。
- **其他平台** — Pure Cangjie 源码因语言跨平台能力可能可用于 Windows、macOS 与 ARM64，但当前均为 `unverified / potentially supported`，不是 1.0 RC 的已验证支持声明；后续按平台逐项 qualification。
- **版本配套** — `yjson`、宏包、聚合包和 Native package 必须来自同一 checkout、同一 exact commit 并重新编译。
- **Stream decode** — 当前会读取全部剩余输入，并非恒定内存的增量 parser；Stream 的所有权仍归调用方。
- **Native backend** — 需要显式依赖，document 必须 `close()`，且不是线程安全对象；当前仅 qualification Linux x86_64。
- **资源预算** — byte budget 默认不限制，`maxDepth` 默认 256；处理不可信输入时应显式收紧。
- **JSON Schema format assertion** — 默认 `Annotation`；core 提供基础 format，国际化
  hostname/email、URI/IRI 与 URI Template 由可选 `yjson_schema_formats` provider 提供。
  required 1299/1299、适用 optional 964/964 均通过固定 revision 官方 suite。
- **预发布状态** — `1.0.0-rc.1` 尚未发布到 registry；状态以 release evidence 为准。

## 文档

- [文档导航与用户指南](docs/README.md)
- [API 选择与使用场景](docs/choosing-an-api.md)
- [yjson、stdx.json、cjfast_json、fastjson2 与 Go yyjson 能力对比](docs/library-comparison.md)
- [`@JsonCodec` 生成规则](docs/codec-generation.md)
- [Backend 选择与生命周期](docs/backends.md)
- [性能结论、方法与结果](docs/performance/README.md)
- [不可信输入资源边界](docs/resource-limits.md)
- [当前架构与调用链](docs/architecture.md)
- [预发布迁移指南](docs/migration/pre-1.0-to-1.0.md) · [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)
- [第三方组件与许可](THIRD_PARTY_NOTICES.md)

## 许可证

[Apache License 2.0](LICENSE)

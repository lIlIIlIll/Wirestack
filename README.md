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

所有 yjson package 必须来自同一个 checkout 和同一个 exact commit；仅比较 manifest
中的 `1.0.0` 版本字符串不足以证明候选代码配套。冻结候选后使用 annotated tag 或 SHA：

```bash
git fetch --tags origin
git checkout --detach 1.0.0-rc.1
```

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

从仓库根目录运行纯仓颉示例：

```bash
scripts/run_cjpm_executable.sh packages/examples
```

## 核心 API

| 需求 | 推荐入口 | 返回值 |
|---|---|---|
| 类型安全编解码 | `YJson.toJson` / `YJson.fromJson<T>` | typed value / `String` |
| 直接构造 JSON 文本 | `@Json({...})` | `String` |
| 构造并修改 JSON 树 | `@JsonValue({...})` | `JsonNode` |
| 解析或输出 JSON 树 | `YJson.parse` / `YJson.stringify` | `JsonNode` / `String` |
| 低内存只读查询 | `YJson.parseCompact` | `CompactJsonDocument` |
| 自定义或内置 codec | `encode*With` / `decode*With` | typed value / JSON |
| Stream I/O | `encodeToStreamWith` / `decodeFromStreamWith` | caller-owned stream |

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

## 性能

在固定 CPU、相同 SDK 与构建参数、交替执行的 37 项同语义 Server 测量中，yjson 有
29 项 paired median 低于 `cjfast_json`。下表选择同时通过两侧 CV ≤ 5% 门槛的代表
workload，并保留领先与落后方向：

| Workload | yjson | cjfast_json | Latency ratio Y/C | Direction |
|---|---:|---:|---:|---|
| Large Map encode / string¹ | 119.887 µs | 132.802 µs | **0.903x** | yjson faster 11/11 |
| Large Array decode / string | 43.340 µs | 77.940 µs | **0.556x** | yjson faster |
| Large Array encode / string | 101.547 µs | 75.899 µs | 1.338x | cjfast_json faster 11/11 |
| `TemporalStats` encode / string | 20.879 µs | 21.824 µs | **0.957x** | yjson faster 11/11 |
| Deep nested decode / string | 76.070 µs | 95.808 µs | **0.794x** | yjson faster |

`Latency ratio Y/C` 统一按 `yjson median / cjfast_json median` 计算，小于 1 表示 yjson
耗时更低。¹ Large
Map 来自同环境的独立稳定复测；其余行来自 37-workload 正式测量。绝对时间是特定 Server、
SDK 与 workload 的快照，不代表其他环境。

当前公开摘要、稳定行、方法和实验限制见[性能方法与结果](docs/performance/README.md)；
复现入口见 [benchmark 指南](benchmarks/README.md)。完整历史 raw samples、p95、MAD 与
machine-readable summaries 尚未全部随仓库发布。stdx.json、fastjson2 与 cjfast_json
数据来自不同批次，不能解读为一次同步四库排名。

另一次独立的跨 runtime DOM 测量使用纯 Go 的 `dwisiswant0/yyjson`。在相同 fixture 的
Read、Write 与 RoundTrip 共 12 项中，Go yyjson 的 paired median 均较低；11 个两侧
CV ≤ 5% 的稳定行中，`yjson / Go yyjson` latency ratio 几何均值为 **5.45x**。这不是
typed codec 对比，且 16 MiB Read 因 yjson CV 9.60% 只作为方向证据。完整表格与边界见
[2026-08-22 Go yyjson DOM 结果](docs/performance/results/2026-08-22-go-yyjson.md)。

## 兼容性与限制

- **版本配套** — `yjson`、宏包、聚合包和 Native package 必须来自同一 checkout、同一 exact commit 并重新编译。
- **Stream decode** — 当前会读取全部剩余输入，并非恒定内存的增量 parser；Stream 的所有权仍归调用方。
- **Native backend** — 需要显式依赖，document 必须 `close()`，且不是线程安全对象；当前仅 qualification Linux x86_64。
- **资源预算** — byte budget 默认不限制，`maxDepth` 默认 256；处理不可信输入时应显式收紧。
- **JSON Schema** — 支持常用类型、组合、本地引用和边界校验，但不是完整的 draft 2020-12 实现。
- **预发布状态** — `1.0.0-rc.1` 只有在 exact commit、blocking gates、evidence 与 annotated tag 全部冻结后才是可复现 RC；registry publish 与 hosted CI 状态以 release evidence 为准。

## 文档

- [文档导航与用户指南](docs/README.md)
- [API 选择与使用场景](docs/choosing-an-api.md)
- [`@JsonCodec` 生成规则](docs/codec-generation.md)
- [Backend 选择与生命周期](docs/backends.md)
- [性能结论、方法与结果](docs/performance/README.md)
- [不可信输入资源边界](docs/resource-limits.md)
- [当前架构与调用链](docs/architecture.md)
- [预发布迁移指南](docs/migration/pre-1.0-to-1.0.md) · [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)
- [第三方组件与许可](THIRD_PARTY_NOTICES.md)

## 构建与贡献

```bash
cjpm test
(cd packages/yjson_native && cjpm test)
(cd packages/yjson_yyjson && cjpm test)
YJSON_FUZZ_CASES=5000 scripts/release_native_checks.sh
```

Native 构建脚本尊重 `CC` 与 `AR`。提交修改前请运行与变更范围对应的 core、consumer
或 Native 验证；性能变更还应附带同环境 baseline/candidate 原始样本。

## 许可证

[Apache License 2.0](LICENSE)

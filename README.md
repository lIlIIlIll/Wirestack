<!-- BEAUTIFIED -->

<h1 align="center">yjson</h1>

<p align="center">
  <strong>面向仓颉的类型安全 JSON 库</strong>
  <br />
  <em>编译期 Codec · Mutable AST · Read-only Document · Stream I/O</em>
</p>

<p align="center">
  <a href="https://github.com/lIlIIlIll/yjson/actions/workflows/ci.yml"><img src="https://github.com/lIlIIlIll/yjson/actions/workflows/ci.yml/badge.svg?branch=main" alt="Tests" /></a>
  <a href="https://codecov.io/gh/lIlIIlIll/yjson"><img src="https://codecov.io/gh/lIlIIlIll/yjson/branch/main/graph/badge.svg?flag=core" alt="Core Coverage" /></a>
  <a href="https://github.com/lIlIIlIll/yjson/releases/latest"><img src="https://img.shields.io/github/v/release/lIlIIlIll/yjson?display_name=tag&sort=semver&label=historical%20release" alt="Latest historical GitHub release" /></a>
  <img src="https://img.shields.io/badge/current%20line-0.1.0-F59E0B" alt="Current development line 0.1.0" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-yellow" alt="Apache License 2.0" /></a>
</p>

yjson 从 `0.1.0` 重新开始成熟度版本线。`0.1.0` 允许 breaking change，不提供旧 API alias。
普通应用使用 GC 管理的 Pure 引擎和三组入口：typed codec、可修改 `JsonNode`、只读
`JsonDocument`。默认 API 没有 backend 参数，也没有 `close()`。

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#按任务选择-api">API 选择</a> ·
  <a href="#可选包">可选包</a> ·
  <a href="docs/README.md">完整文档</a>
</p>

## 适合什么场景

- class、struct、enum 与 JSON 之间的类型安全转换；
- 不使用运行时反射的编译期 codec；
- 可修改 AST、只读文档和 caller-owned stream；
- 对不可信输入设置明确的 byte、string、buffer 和 depth 预算；
- JSON Schema draft 2020-12、JSON Pointer、JSON Patch、Merge Patch 和 JSONPath。

如果只需要 SDK 自带的基础 JSON 能力，先阅读[库能力对比](docs/library-comparison.md)。

## 安装

Hosted CI 每七天选择一次最新的完整 dated nightly。该窗口内的 Linux、Windows、macOS、
coverage、cjdoc 和 package gate 使用同一个精确 SDK，并记录 SDK archive checksum。手工运行
workflow 时可以显式指定一个完整 nightly。某个版本的已验证范围以对应 release evidence 中
记录的 SDK 为准。

当前仓库使用 path dependency，不假定 registry 中已经存在发布包。

使用 generated codec 时，应用直接依赖 runtime 和 macro package：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_macros = { path = "../yjson/packages/yjson_macros" }
```

只使用 parser、AST、只读文档或手写 codec 时，仅依赖 `yjson`。九个发布包使用相同版本；
发布顺序和依赖闭包由
[`release/release-graph.toml`](release/release-graph.toml) 定义。

## 快速开始

```cangjie
package yjson_demo

import yjson.*
import yjson_macros.*

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

输出：

```text
Alice
```

`@JsonCodec` 在调用方编译时生成 `UserJson: JsonCodec<User>`，并让该类型支持最短
`YJson` 入口。它不扫描目录，不写入 generated source，也不使用运行时反射。可运行示例见
[`packages/examples`](packages/examples/README.md)。

## 按任务选择 API

| 任务 | 首选入口 | 结果或约束 |
| --- | --- | --- |
| typed value 与 JSON 互转 | `YJson.toJson` / `YJson.fromJson<T>` | 类型提供 generated codec |
| 使用 built-in 或 custom codec | 同一入口并传 `codec:` | 不要求类型实现 generated provider |
| 构造或修改 JSON 树 | `JsonNode.parse` / `JsonNode.object` / `JsonNode.array` | 返回可修改 `JsonNode` |
| 只读查询文档 | `YJson.parseDocument` | 返回 GC 管理的 `JsonDocument` |
| 读写 caller-owned stream | `YJson.fromJson(InputStream)` / `YJson.writeJson` | 不关闭调用方 stream |
| 校验 JSON | `yjson_algorithms.JsonSchema` | draft 2020-12；默认有限预算 |
| 定位、查询或更新节点 | `JsonPointer` / `JsonPath` / `JsonPatch` | 操作统一的 `JsonValueView` |

显式 codec 仍使用相同 API：

```cangjie
let text = YJson.toJson("仓颉 JSON", codec: JsonCodecs.string)
let value = YJson.fromJson(text, codec: JsonCodecs.string)
```

完整选择说明见 [API 选择指南](docs/choosing-an-api.md)。

## 数据模型

```cangjie
let node = JsonNode.parse("{\"name\":\"Alice\"}").asObject()
node.put("active", JsonNode.boolean(true))
println(node.toJson(options: JsonWriteOptions.pretty()))

let document = YJson.parseDocument("{\"name\":\"Alice\"}")
let name = document.root().member("name").getOrThrow().asString()
```

`JsonValueView` 是 AST、managed document 和高级 backend 的统一只读接口。默认
`materialize()` 最多复制 100,000 个节点并限制为 256 层；需要不同 node budget 时传入
`materialize(maxNodes)`。AST 与只读文档的选择见
[AST 与只读 Document](docs/ast-and-compact.md)。

## 可选包

| Package | 用途 |
| --- | --- |
| `yjson_macros` | `@JsonCodec`、`@JsonSubtype` 和 `@JsonUsing` 编译期宏 |
| `yjson_algorithms` | Pointer、Path、Patch、Merge Patch 和 Schema |
| `yjson_schema_formats` | 国际化 Schema format provider |
| `yjson_native_accel` | 启动时为普通 `YJson` API 启用 Native primitive |
| `yjson_backends` + `yjson_native` | 显式 Custom Native document/whole-document I/O |
| `yjson_backends` + `yjson_yyjson` | 显式 yyjson document/whole-document I/O |

高级 backend 只通过命名 façade 暴露：`NativeBackends.customNative` 和
`YyjsonBackends.yyjson`。返回的 `BackendJsonDocument` 是显式资源；普通
`JsonDocument` 不是。详见 [Backend 使用指南](docs/backends.md)。

## 安全与并发边界

- `JsonReadOptions.defaults` 拒绝重复 key，忽略 typed decode 的未知字段，并设置 64 MiB
  输入、16 MiB string、8 MiB buffered value 和 256 层深度上限；读取预算必须为正数。
- `JsonWriteOptions.defaults` 使用紧凑输出和 256 层深度；`maxOutputBytes = 0` 表示不设
  输出 byte 上限。
- JSON 失败统一使用 `JsonException`。调用方匹配稳定的 `error.code`，不要解析 message。
- immutable `JsonDocument`、`JsonValueView` 和编译后的 `JsonSchema` 支持并发读取。
  `JsonPathCursor` 是有状态惰性迭代器，只能由一个线程消费。
- caller-owned stream 不会被 yjson 关闭。一次调用处理一个 JSON document，并拒绝 trailing
  content；它不是多文档 framing protocol。
- Pure 跨平台资格由 GitHub runners 验证；Native `0.1.0` 的资格范围是 Linux x86_64。

配置和预算见[配置与错误](docs/configuration-and-errors.md)及
[资源限制](docs/resource-limits.md)。

## 性能

`0.1.0` 的 API 以短路径和可优化边界为目标：generated codec 直接进入统一 reader/writer，
只读 view 避免强制 materialization，JSONPath 按需产出匹配，Native 能力保持显式 opt-in。

仓库中的历史测量只适用于其记录的源码、SDK、CPU、workload 和 checksum。`0.1.0` 在完成
固定 CPU、交替/反转 A/B、RSS、checksum 和跨 profile 资格测试前不发布新的性能倍数声明。
方法与证据入口见[性能文档](docs/performance/README.md)。

## 文档

- [文档导航](docs/README.md)
- [`@JsonCodec` 生成规则](docs/codec-generation.md)
- [自定义 Codec](docs/custom-codecs.md)
- [Stream I/O](docs/streams.md)
- [Backend 使用指南](docs/backends.md)
- [JSON Schema](docs/schema.md)
- [JSON Pointer、JSONPath 与 Patch](docs/path-and-patch.md)
- [公开 API 清单](docs/public-api-inventory.md)
- [Release notes](RELEASE_NOTES.md) · [Changelog](CHANGELOG.md)

维护者从[测试策略](docs/maintainers/testing.md)、
[发布流程](docs/maintainers/releasing.md)和
[仓库布局](docs/maintainers/repository-layout.md)开始。API reference 由固定版本的 cjdoc 从九个
package 生成；生成和已知限制见[文档导航](docs/README.md)。

## 参与项目

提交代码前阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题按
[SECURITY.md](SECURITY.md) 报告，不要在公开 issue 中提交未修复漏洞的利用细节。

## 许可证

[Apache License 2.0](LICENSE)。可选 yyjson backend 的第三方许可见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

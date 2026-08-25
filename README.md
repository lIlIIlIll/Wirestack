<!-- BEAUTIFIED -->

<h1 align="center">yjson</h1>

<p align="center">
  <strong>面向仓颉的类型安全 JSON 库</strong>
  <br />
  <em>编译期 Codec · JSON 字面量 · Mutable AST · Compact DOM · Stream I/O</em>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-yellow?style=flat" alt="Apache License 2.0" /></a>
  <img src="https://img.shields.io/badge/Cangjie-1.1.0-3B82F6?style=flat" alt="Cangjie 1.1.0" />
  <img src="https://img.shields.io/badge/manifest-1.0.0-10B981?style=flat" alt="Manifest version 1.0.0" />
</p>

yjson 默认只使用仓颉实现。普通应用通过 `@JsonCodec` 获得类型安全的 JSON
编解码；需要 Native DOM 或 Native typed stream backend 时，再显式添加对应 package。

## 适合什么场景

- class、struct、enum 与 JSON 之间的类型安全转换；
- 需要编译期生成代码、但不希望依赖运行时反射的应用；
- 同时需要 typed codec、可修改 `JsonNode`、只读 Compact DOM 或 Stream I/O 的项目；
- 需要明确控制未知字段、重复 key、数字策略、嵌套深度和 byte budget 的服务端程序；
- 需要 JSON Schema draft 2020-12、JSON Pointer、Patch、Merge Patch 或 JSONPath 的工具。

如果只需要 SDK 自带的基础 JSON 能力，或不需要 generated typed mapping，先阅读
[库能力对比](docs/library-comparison.md)，再决定是否引入 yjson。

## 安装

要求仓颉 SDK 1.1.0，且 `cjc`、`cjpm` 位于 `PATH`。当前仓库示例使用 path
dependency，不假定任何 registry 包已经发布。

普通应用推荐依赖聚合包：

```toml
[dependencies]
yjson_all = { path = "../yjson/packages/yjson_all" }
```

`yjson_all` 同时导出 runtime 与 `@JsonCodec`、`@Json`、`@JsonValue`。它不会隐式启用
Native backend。只使用 parser、AST 或内置 codec 时，可以仅依赖 core：

```toml
[dependencies]
yjson = { path = "../yjson" }
```

所有 yjson package 必须来自同一 checkout 或同一 release，并一起重新编译。Native
package 的依赖和构建要求见 [Backend 使用指南](docs/backends.md)。

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

`@JsonCodec` 在调用方编译时生成 `UserJson: JsonCodec<User>` 和
`JsonCodecProvider` 实现。它不扫描源码目录，也不依赖运行时反射。可运行的完整示例位于
[`packages/examples`](packages/examples/README.md)。

## 按任务选择 API

| 你要做什么 | 使用什么 | 结果或约束 |
| --- | --- | --- |
| typed value 与 JSON 互转 | `YJson.toJson` / `YJson.fromJson<T>` | 类型安全；类型需提供 codec |
| 使用显式或自定义 codec | `encode*With` / `decode*With` | 不要求类型实现 provider |
| 直接构造 JSON 文本 | `@Json({...})` | 返回 `String`；不先创建 AST |
| 构造并修改 JSON 树 | `@JsonValue({...})` / `YJson.parse` | 返回 `JsonNode` |
| 只读查询文档 | `YJson.parseDocument` | 默认 Pure Compact；backend 可切换 |
| 读写 caller-owned stream | `toStream` / `fromStream` 或 `*StreamWith` | 不关闭调用方 stream |
| 校验 JSON | `JsonSchema` | draft 2020-12 |
| 定位、查询或更新节点 | `JsonPointer` / `JsonPath` / `JsonPatch` | 标准化路径与变更语义 |

不知道从哪里开始时，阅读 [API 选择指南](docs/choosing-an-api.md)。

## 两种 JSON 字面量

`@Json` 直接生成紧凑 JSON 文本；`@JsonValue` 构造可修改树。`$()` 插值表达式从左到右
各求值一次。

```cangjie
let id: Int64 = 7
let text = @Json({"ok": true, "user": $(User(id, "Alice"))})

let node = @JsonValue({"name": "Alice", "items": [1, 2]})
node["name"] = "Bob"
println(YJson.stringify(node))
```

静态重复 key 是编译错误；动态 key 冲突采用 LastWins。完整语法和求值规则见
[JSON 字面量](docs/json-literals.md)。

## 组件关系

```mermaid
flowchart LR
    App[应用代码] --> All[yjson_all]
    All --> Core[yjson runtime]
    All --> Macros[yjson_macros]
    Macros --> Codec[generated JsonCodec]
    Codec --> Core
    Core --> Pure[Pure Cangjie parser / AST / Compact / Stream]
    App -. 显式依赖 .-> Native[yjson_native / yjson_yyjson]
    Native --> Core
```

普通 typed 调用从 generated 或 built-in `JsonCodec<T>` 进入 backend-neutral reader/writer。
Native package 是可选边界，不会自动替换 core 行为。更完整的调用链见
[架构说明](docs/architecture.md)。

## 重要边界

- `JsonReadConfig` 的 byte limit 默认 `0 = unlimited`，`maxDepth` 默认 256；处理不可信
  输入时应显式设置预算。
- 默认 Pure stream backend 增量读取单个完整 JSON document；它不是多文档 framing
  protocol。decode 失败后，不保证 stream 停在可恢复边界。
- Native document 是显式资源，必须 `close()`，并且不是线程安全对象。
- `yjson`、`yjson_macros`、`yjson_all` 与可选 Native package 必须版本匹配。
- 当前 release qualification 以 Linux x86_64 为阻断平台；其他平台不得从源码可移植性
  推断为已验证支持。
- 性能结果只适用于对应源码、SDK、主机、workload 和测量方法，不代表普遍排名。

配置、安全边界和错误码分别见[配置与错误](docs/configuration-and-errors.md)与
[资源限制](docs/resource-limits.md)。

## 文档

- [从安装到进阶的文档导航](docs/README.md)
- [API 选择指南](docs/choosing-an-api.md)
- [`@JsonCodec` 生成规则](docs/codec-generation.md)
- [AST 与 Compact DOM](docs/ast-and-compact.md)
- [Stream I/O](docs/streams.md)
- [Backend 使用指南](docs/backends.md)
- [JSON Schema](docs/schema.md)
- [性能方法与结果](docs/performance/README.md)
- [pre-1.0 → 1.0 迁移](docs/migration/pre-1.0-to-1.0.md)
- [Release notes](RELEASE_NOTES.md) · [Changelog](CHANGELOG.md)

维护者请从[测试策略](docs/maintainers/testing.md)、
[发布流程](docs/maintainers/releasing.md)和[仓库布局](docs/maintainers/repository-layout.md)
开始。单次 RC 验收结果保存在 `release/`，不作为通用使用文档。

## 参与项目

提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题的报告边界与当前渠道见
[SECURITY.md](SECURITY.md)；不要在公开 issue 中提交未修复漏洞的利用细节。

## 许可证

[Apache License 2.0](LICENSE)。可选 yyjson backend 的第三方许可见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

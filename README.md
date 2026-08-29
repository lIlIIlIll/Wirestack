<!-- BEAUTIFIED -->

<h1 align="center">yjson</h1>

<p align="center">
  <strong>面向仓颉的类型安全 JSON 库</strong>
  <br />
  <em>编译期 Codec · JSON 字面量 · Mutable AST · Compact DOM · Stream I/O</em>
</p>

<p align="center">
  <a href="https://github.com/lIlIIlIll/yjson/actions/workflows/ci.yml"><img src="https://github.com/lIlIIlIll/yjson/actions/workflows/ci.yml/badge.svg?branch=main" alt="Tests" /></a>
  <a href="https://codecov.io/gh/lIlIIlIll/yjson"><img src="https://codecov.io/gh/lIlIIlIll/yjson/branch/main/graph/badge.svg?flag=core" alt="Core Coverage" /></a>
  <a href="https://github.com/lIlIIlIll/yjson/releases/latest"><img src="https://img.shields.io/github/v/release/lIlIIlIll/yjson?display_name=tag&sort=semver" alt="Release" /></a>
  <a href="docs/performance/results/2026-08-27-yjson-2.0.0.md"><img src="https://img.shields.io/badge/Performance-qualified-10B981" alt="Performance qualified" /></a>
  <a href="docs/performance/results/2026-08-30-current-dev-seven-library.md"><img src="https://img.shields.io/badge/dev%20benchmark-current%20%7C%20noisy-F59E0B" alt="Current dev benchmark is noisy" /></a>
  <a href="docs/performance/results/2026-08-28-stream-protocol-v1.md"><img src="https://img.shields.io/badge/Stream%20protocol-v1%20incomplete-F59E0B" alt="Stream protocol v1 incomplete" /></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Cangjie-%3E%3D1.1.0-3B82F6" alt="Cangjie 1.1.0 or later" />
  <a href="release/2.0.0/evidence.md"><img src="https://img.shields.io/badge/Linux%20x86__64-qualified-10B981" alt="Linux x86_64 qualified" /></a>
  <a href="docs/architecture.md"><img src="https://img.shields.io/badge/engine-Pure%20default-8B5CF6" alt="Pure engine by default" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-yellow" alt="Apache License 2.0" /></a>
</p>

yjson 2.0 默认使用跨平台、GC 管理的 Pure 引擎。普通应用只需要
`YJson.toJson`、`YJson.fromJson<T>` 与 `YJson.parseDocument`；不需要选择 backend，
也不需要管理 scanner、whole-document 资源或 `close()`。

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#按任务选择-api">API 选择</a> ·
  <a href="#性能">性能</a> ·
  <a href="docs/README.md">完整文档</a>
</p>

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

`yjson` 与 `yjson_macros` 作为一个发行单元升级；generated codec 通过 v1 protocol
检查兼容性，不要求应用人工匹配 exact commit。Native 加速与高级 backend 的依赖和
构建要求见 [Backend 使用指南](docs/backends.md)。

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

运行后输出：

```text
Alice
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
| 只读查询文档 | `YJson.parseDocument` | GC 管理的 Compact document，无 `close()` |
| 读写 caller-owned stream | `toStream` / `fromStream` 或 `*StreamWith` | 不关闭调用方 stream |
| 校验 JSON | `yjson_algorithms.JsonSchema` | draft 2020-12；默认有限预算 |
| 定位、查询或更新节点 | `yjson_algorithms` 的 Pointer / Path / Patch | 默认有限预算 |

不知道从哪里开始时，阅读 [API 选择指南](docs/choosing-an-api.md)。

## 性能

当前开发数据绑定 `dev` 提交 `1dedf2a`。下表是第二批 11 轮完整重跑的中位数，单位为 µs/op。
每个 workload 都至少有一个实现的 CV 超过 5%，因此所有行标记 noisy，只表示本次观察值。

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.564 | 92.127 | 2.836 | 3.398 | 2.946 | 0.170 | 0.064 |
| Address decode | 0.944 | 37.182 | 3.098 | 3.449 | 2.042 | 0.304 | 0.067 |
| Person encode | 3.836 | 123.469 | 16.211 | 5.465 | 10.058 | 0.584 | 0.264 |
| Person decode | 10.356 | 124.353 | 24.933 | 19.891 | 15.228 | 1.134 | 0.427 |
| Large Array encode | 72.185 | 633.995 | 265.352 | 92.306 | 76.370 | 8.927 | 3.961 |
| Large Array decode | 66.086 | 1100.139 | 316.129 | 211.037 | 80.198 | 18.932 | 5.107 |
| Large Map encode | 7.733 | 370.841 | 169.543 | 121.402 | 117.848 | 1.781 | 1.752 |
| Large Map decode | 33.637 | 716.636 | 293.737 | 222.504 | 202.004 | 5.277 | 3.933 |
| Deep Nested encode | 84.492 | 426.165 | 172.341 | 84.366 | 72.480 | 4.520 | 2.508 |
| Deep Nested decode | 94.873 | 784.964 | 222.617 | 144.320 | 93.575 | 10.533 | 3.395 |

完整两批数据、各库 CV、API 路径、metadata、raw report 和 checksum 见
[2026-08-30 当前 dev 七库完整对比](docs/performance/results/2026-08-30-current-dev-seven-library.md)。
这份开发快照没有通过稳定性门槛，不能发布精确倍数。最近一次通过完整门禁的结果仍是
[2.0.0 性能报告](docs/performance/results/2026-08-27-yjson-2.0.0.md)。

Stream protocol v1 的当前开发批次包含稳定提升行，但没有通过完整稳定性和内部 scratch
生命周期门槛，因此不能作为发布性能声明。完整矩阵、workload JSON 和原始证据见
[2026-08-28 Stream protocol v1 结果](docs/performance/results/2026-08-28-stream-protocol-v1.md)。

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
    Core --> Pure[单一 reader / writer semantic engine]
    App -. 启动时一次 initialize .-> Accel[yjson_native_accel]
    Accel --> Core
    App -. 高级显式资源 .-> Backends[yjson_backends]
```

普通 typed 调用从 generated 或 built-in `JsonCodec<T>` 进入同一 reader/writer。
`YJsonNativeAccel.initialize()` 只在首次 `YJson` 调用前冻结一次 Native profile；之后仍使用
相同 `YJson` API，初始化失败不会静默回退。更完整的调用链见
[架构说明](docs/architecture.md)。

## 重要边界

- `JsonReadConfig` 组合 `JsonReadLimits`，`JsonWriteConfig` 组合 `JsonWriteLimits`；
  byte limit 的 `0` 表示 unlimited，默认深度为 256。
- 默认 stream API 真正增量读取单个完整 JSON document；它不是多文档 framing
  protocol。decode 失败后，不保证 stream 停在可恢复边界。
- 默认 `JsonDocument` 由 GC 管理。只有 `yjson_backends.BackendJsonDocument` 是显式资源。
- JSONPath、Patch/Merge Patch 与 Schema 位于 `yjson_algorithms`，默认预算耗尽统一抛出
  `JsonWorkLimitException(code: "work_limit_exceeded")`；可信离线任务可显式使用 `.unlimited`。
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
- [1.x → 2.0 迁移](docs/migration/1.x-to-2.0.md)
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

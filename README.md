<!-- BEAUTIFIED -->

<h1 align="center">yjson</h1>

<p align="center">
  <strong>面向仓颉的类型安全 JSON 库</strong>
  <br />
  <em>编译期编解码 · 可修改 JSON 树 · 只读文档 · 流式读写</em>
</p>

<p align="center">
  <a href="https://github.com/lIlIIlIll/yjson/actions/workflows/ci.yml"><img src="https://github.com/lIlIIlIll/yjson/actions/workflows/ci.yml/badge.svg?branch=main" alt="Tests" /></a>
  <a href="https://codecov.io/gh/lIlIIlIll/yjson"><img src="https://codecov.io/gh/lIlIIlIll/yjson/branch/main/graph/badge.svg?flag=core" alt="Core Coverage" /></a>
  <a href="https://github.com/lIlIIlIll/yjson/releases/latest"><img src="https://img.shields.io/github/v/release/lIlIIlIll/yjson?display_name=tag&sort=semver&label=historical%20release" alt="Latest historical GitHub release" /></a>
  <img src="https://img.shields.io/badge/current%20line-0.1.0-F59E0B" alt="Current development line 0.1.0" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-yellow" alt="Apache License 2.0" /></a>
</p>

yjson 是仓颉 JSON 库，支持类型与 JSON 互转、构造和修改 JSON 树、只读查询以及流式读写。
默认使用纯仓颉实现，由 GC 管理内存。

当前开发版本为 `0.1.0`，API 仍可能发生不兼容变更，不提供旧 API 别名。
历史 `1.x`、`2.0` 版本的接口不适用于当前版本。

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#按任务选择-api">API 选择</a> ·
  <a href="#可选包">可选包</a> ·
  <a href="docs/README.md">完整文档</a>
</p>

## 适合什么场景

- class、struct、enum 与 JSON 之间的类型安全转换；
- 不依赖运行时反射的编译期编解码；
- 修改 JSON 树、查询只读文档、读写调用方提供的流；
- 限制输入字节数、字符串大小、缓冲区大小和嵌套深度；
- JSON Schema draft 2020-12、JSON Pointer、JSON Patch、Merge Patch 和 JSONPath。

如果只需要 SDK 自带的基础 JSON 能力，先阅读[库能力对比](docs/library-comparison.md)。

## 安装

当前使用本地路径依赖。将 yjson 仓库放在应用目录旁边，再把下面的配置加入应用的
`cjpm.toml`；如果目录位置不同，请调整 `path`。

使用 `@JsonCodec` 时，同时添加运行库和宏包：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_macros = { path = "../yjson/packages/yjson_macros" }
```

只做 JSON 解析、节点操作、只读查询或使用手写编解码器时，添加 `yjson` 即可。
这份安装说明使用本地源码，不依赖包仓库中的发布状态。SDK 的测试范围见[发布记录](release/0.1.0/evidence.md)。

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

`@JsonCodec` 在编译应用时生成 `UserJson: JsonCodec<User>`，供 `YJson` 完成编解码，
不需要运行时反射。完整示例见
[`packages/examples`](packages/examples/README.md)。

## 按任务选择 API

| 任务 | 首选入口 | 结果或约束 |
| --- | --- | --- |
| 类型与 JSON 互转 | `YJson.toJson` / `YJson.fromJson<T>` | 类型使用 `@JsonCodec` |
| 使用内置或自定义编解码器 | 同一入口并传 `codec:` | 不要求类型使用宏 |
| 构造或修改 JSON 树 | `JsonNode.parse` / `JsonNode.object` / `JsonNode.array` | 返回可修改 `JsonNode` |
| 只读查询文档 | `YJson.parseDocument` | 返回 GC 管理的 `JsonDocument` |
| 读写调用方提供的流 | `YJson.fromJson(InputStream)` / `YJson.writeJson` | 不关闭调用方的流 |
| 校验 JSON | `yjson_algorithms.JsonSchema` | draft 2020-12；默认有限预算 |
| 定位、查询或更新节点 | `JsonPointer` / `JsonPath` / `JsonPatch` | 操作统一的 `JsonValueView` |

传入编解码器时，仍使用同一组 API：

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

`JsonValueView` 用同一套只读接口访问 `JsonNode`、`JsonDocument` 和可选后端的文档。
调用 `materialize()` 可以复制成可修改的树，默认最多复制 100,000 个节点，深度不超过 256 层。
需要调整节点数量上限时，传入
`materialize(maxNodes)`。AST 与只读文档的选择见
[AST 与只读 Document](docs/ast-and-compact.md)。

## 可选包

| 包 | 用途 |
| --- | --- |
| `yjson_macros` | `@JsonCodec`、`@JsonSubtype` 和 `@JsonUsing` 编译期宏 |
| `yjson_algorithms` | Pointer、Path、Patch、Merge Patch 和 Schema |
| `yjson_schema_formats` | Schema 国际化格式校验 |
| `yjson_native_accel` | 启动时为 `YJson` 启用原生加速 |
| `yjson_backends` + `yjson_native` | Custom Native 文档和整篇文档读写 |
| `yjson_backends` + `yjson_yyjson` | yyjson 文档和整篇文档读写 |

通过 `NativeBackends.customNative` 和 `YyjsonBackends.yyjson` 使用可选后端。
它们返回的 `BackendJsonDocument` 需要调用 `close()` 显式关闭，默认的 `JsonDocument` 由 GC 管理。详见 [Backend 使用指南](docs/backends.md)。

## 读写限制与并发

- `JsonReadOptions.defaults` 拒绝重复键，忽略类型解码时的未知字段，并设置 64 MiB
  输入、16 MiB 字符串、8 MiB 值缓冲区和 256 层深度上限；读取预算必须为正数。
- `JsonWriteOptions.defaults` 使用紧凑输出和 256 层深度；`maxOutputBytes = 0` 表示不设
  输出字节数上限。
- JSON 解析和校验错误使用 `JsonException`，处理时匹配 `error.code`。调用方的流或自定义
  编解码器抛出的异常也可能直接传出。
- 不可变的 `JsonDocument` 及其视图、编译后的 `JsonSchema` 支持并发读取。
  `JsonNode` 可以修改，仅通过 `JsonValueView` 访问它不会使底层数据不可变。
  `JsonPathCursor` 是有状态惰性迭代器，只能由一个线程消费。
- yjson 不关闭调用方提供的流。一次调用只处理一份 JSON 文档，文档后仍有非空白内容时会报错。
- Pure 的跨平台测试在 GitHub runners 上运行，结果见
  [发布记录](release/0.1.0/evidence.md)。Native `0.1.0` 的验证范围限于 Linux x86_64。

配置和预算见[配置与错误](docs/configuration-and-errors.md)及
[资源限制](docs/resource-limits.md)。

## 性能

下面是 2026-09-07 七库对比第二批的 11 轮中位数，单位为 µs/op，越小越好。
测量使用提交 `3df280151b3a3a818c6ad75c254750a19d25e5a1`。
**两批结果的每一行都至少有一个库的变异系数（CV）超过 5%，因此这些数字仅供查看，不能作为稳定的性能排名。**

完整样本、波动情况和环境见[2026-09-07 main 七库对比](docs/performance/results/2026-09-07-main-seven-library.md)。
测试方法见[性能文档](docs/performance/README.md)。结果只适用于记录中的源码、SDK、CPU 和测试数据。

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.352 | 3.328 | 3.012 | 3.439 | 2.993 | 0.171 | 0.064 |
| Address decode | 1.441 | 2.272 | 3.141 | 3.463 | 2.041 | 0.303 | 0.068 |
| Person encode | 2.790 | 12.451 | 16.228 | 5.522 | 10.807 | 0.576 | 0.268 |
| Person decode | 8.787 | 21.528 | 23.434 | 19.803 | 15.000 | 1.132 | 0.428 |
| Large Array encode | 29.947 | 110.982 | 266.532 | 92.128 | 75.797 | 8.948 | 4.195 |
| Large Array decode | 128.124 | 205.158 | 311.836 | 222.162 | 84.072 | 18.560 | 5.028 |
| Large Map encode | 6.865 | 140.355 | 159.085 | 125.937 | 105.971 | 1.809 | 1.732 |
| Large Map decode | 50.537 | 306.371 | 297.182 | 220.016 | 211.071 | 5.054 | 4.013 |
| Deep Nested encode | 48.196 | 100.192 | 173.245 | 80.522 | 68.255 | 4.486 | 2.654 |
| Deep Nested decode | 371.596 | 197.669 | 242.864 | 141.084 | 96.716 | 10.453 | 3.377 |

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
[仓库布局](docs/maintainers/repository-layout.md)开始。API 参考由固定版本的 cjdoc 从九个包生成；生成和已知限制见[文档导航](docs/README.md)。

## 参与项目

提交代码前阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题按
[SECURITY.md](SECURITY.md) 报告，不要在公开 issue 中提交未修复漏洞的利用细节。

## 许可证

[Apache License 2.0](LICENSE)。可选 yyjson 后端的第三方许可见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

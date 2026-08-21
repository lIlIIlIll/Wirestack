# yjson 当前架构

本文描述 yjson 1.0 RC 当前源码与发布包的边界。API/type 名称保留英文；仓库维护细节见
[Repository layout](maintainers/repository-layout.md)。

## Package graph

普通应用只需要依赖 `yjson_all`：

```text
application
└── yjson_all
    ├── yjson          # runtime、typed API、AST、Compact DOM、Schema
    └── yjson_macros   # @JsonCodec、@Json、@JsonValue

optional native packages:
application
├── yjson_native       # Custom Native Compact + optional scanner activation
└── yjson_yyjson       # yyjson Direct Native DOM
```

`yjson_all` 是 macro package，通过 `public import` 同时导出 runtime 与 macros。它不依赖、
构建或启用任何 Native package。`yjson_native` 和 `yjson_yyjson` 都显式依赖同版本
`yjson`，应用只有声明相应依赖时才会进入 Native 构建路径。

仓库开发 manifest 中，根 `yjson` 临时依赖 `yjson_macros`，因为 `src/` 内的 fixture 与
white-box tests 也使用 `@JsonCodec`。发布 staging 只复制 `src/lib_*.cj`；发布态 `yjson`
manifest 没有该依赖。这是仓库测试布局，不是下游 package graph 中的运行时反向依赖。

## 编译期数据流

```text
@JsonCodec declaration in consumer source
        │
        ▼
yjson_macros declaration-macro expansion
        │
        ├── generated JsonDirectCodec<T>
        ├── generated <Type>Json value/function
        └── JsonCodecProvider conformance
        │
        ▼
consumer package compiles generated code against matching yjson runtime
```

`@JsonCodec` 支持 class、struct 和 enum。宏直接在声明所在的 consumer package 中展开，
不会扫描项目目录，也不会写入 `src/generated_json_codecs.cj`。非泛型 public 类型生成
public `<Type>Json` codec；泛型类型生成带约束的 codec function。

`@Json` 与 `@JsonValue` 是 expression macros。前者展开为直接驱动
`JsonDirectWriter` 的代码并返回 compact `String`；后者构造可修改 `JsonNode`。两者
都不是运行时 parser 或 annotation processor。

宏生成代码会调用 runtime 的 public bridge，因此 `yjson_macros` 与 `yjson` 必须使用
相同版本。推荐依赖 `yjson_all`；单独选包时应显式锁定同一 release。

## 运行时数据流

### Typed encode/decode

```text
YJson.toJson / fromJson<T>
YJson.encode*With / decode*With
        │
        ▼
generated or built-in JsonDirectCodec<T>
        ├── encode ──> JsonDirectWriter ──> String / bytes / OutputStream
        └── decode
            ├── default compatible config ──> JsonFastReader
            └── explicit policy/limits ─────> JsonDirectReader
```

`YJson.fastDecoder(codec)` 缓存同一个 codec 的 reusable decoder facade；每次调用仍创建
本次输入的 reader。默认兼容配置可以选择 compact fast reader；显式 `JsonReadConfig`
保留 unknown-field、duplicate-key、number 与 resource-limit 语义。

### Mutable AST

```text
YJson.parse(String/bytes)
        ▼
JsonParserCore
        ▼
JsonNode tree
        ├── mutation / indexing
        └── YJson.stringify / stringifyPretty
```

`JsonNode` 及其 scalar、array、object subclasses 是 GC 管理的可修改 DOM。Stream parse
通过缓冲 `JsonByteSource` 消费输入，但结果仍是完整 AST。

### Pure Cangjie Compact DOM

```text
YJson.parseCompact(bytes)
        ▼
CompactJsonDocument
        ▼
CompactJsonValue views ──> lookup / traversal / materialize
```

Pure Compact 是 core 内的只读表示，由 GC 管理，不要求 `close()`。它与可修改
`JsonNode` 是不同的数据模型。

### Optional Native DOM

```text
bytes
├── NativeCompactJsonDocument.parse  ──> Custom Native Compact
└── YyjsonCompactJsonDocument.parse  ──> yyjson Direct Native DOM
                                             │
                                             └── explicit close()
```

Native document 跨 Cangjie/C 边界进行整文档 parse，适合 coarse lookup、bulk traversal
与 serialization。它们不会自动加速 `JsonNode.parse`，也不会被 `yjson_all` 启用。
生命周期、线程安全和 backend 选择见 [Backend 使用指南](backends.md)。

## Native scanner seam

core 中的 `JsonNativeScannerBackend`、`JsonNativeNumericScannerBackend`、
`JsonNativeNumericTapeBackend` 与 `JsonNativeFloatParserBackend` 是可选 backend seam。
core 文件没有 C foreign declaration；backend 未安装时返回 portable fallback。

`yjson_native` 的 `enableYJsonNative*` 函数才会安装相应 process-global backend。安装与
移除必须发生在并发 decode 之前，且不同 activation mode 互斥。这一 seam 与 Native
DOM document 是两个相关但独立的入口：使用 `NativeCompactJsonDocument` 不要求先调用
`enableYJsonNative()`。

## 源码仓库构建路径

| 构建目标 | build hook | Native link | 说明 |
|---|---|---|---|
| 根 `yjson` 开发包 | 无 | 无 | 编译 runtime、fixture 与 white-box tests；开发 manifest 依赖 macros |
| 发布态 `yjson` | 无 | 无 | 只包含 `src/lib_*.cj`，dependencies 为空 |
| `yjson_macros` | 无 | 无 | consumer 编译期 macro package |
| `yjson_all` | 无 | 无 | 聚合并锁定 core + macros |
| `yjson_native` | `build.cj` pre-build | `libyjson_scanner.a` | 显式可选 Custom Native package |
| `yjson_yyjson` | `build.cj` pre-build | `libyjson_yyjson.a` + scanner | 显式可选 vendored yyjson package |

Native build script 在 invoking project 的 `target/native` 下生成 archive。下游普通
`yjson`/`yjson_all` consumer 不运行这些 build hooks，也不需要 C compiler。

## 稳定边界

- Public application API 从 `YJson`、generated/built-in codec、`JsonNode`、
  `CompactJsonDocument` 和显式 Native document 开始。
- `JsonFastReader` 的部分 public 方法是 macro-generated code bridge，不是推荐的应用入口。
- `src/example_support.cj`、`src/test_*.cj` 和 benchmark fixtures 不进入发布态 core artifact。
- Native C ABI、symbol isolation、scanner internals 与 release staging 属于维护者边界。

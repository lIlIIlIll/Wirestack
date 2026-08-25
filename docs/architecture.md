# yjson 架构

本页解释 public package、宏展开和运行时数据流。仓库文件如何进入发布包见
[Repository layout](maintainers/repository-layout.md)。

## Package graph

```text
application
└── yjson_all
    ├── yjson          # runtime、typed API、AST、Compact、Schema、Path/Patch
    └── yjson_macros   # @JsonCodec、@Json、@JsonValue

explicit optional packages
├── yjson_native         # Custom Native DOM / stream / scanner seams
├── yjson_yyjson         # vendored yyjson DOM / stream
└── yjson_schema_formats # libidn2-backed Schema formats
```

`yjson_all` 只聚合 runtime 和 macros，不构建或启用 Native。optional package 显式依赖同
版本 core，应用声明它们后才进入对应 build hook。

根 development manifest 因 white-box fixture 使用 `@JsonCodec` 而依赖 macros；发布态
core 只包含 `src/lib_*.cj`，没有 runtime → macro 依赖。

## 编译期路径

```text
consumer declaration
        │ @JsonCodec
        ▼
yjson_macros expansion
        ├── generated JsonCodec<T>
        ├── generated <Type>Json value/function
        └── JsonCodecProvider conformance
        ▼
consumer compiles generated code against matching yjson runtime
```

macro 在声明所在 package 展开，不扫描目录，也不创建 checked-in generated 文件。
`@Json` 与 `@JsonValue` 是 expression macro：前者生成 direct writer 调用并返回 `String`，
后者构造 `JsonNode`。

## Typed runtime

```text
YJson.toJson / fromJson<T> / *With / stream APIs
                    │
                    ▼
        generated, built-in or custom JsonCodec<T>
             ┌──────────────┴──────────────┐
             ▼                             ▼
      JsonCodecWriter                JsonCodecReader
       ├─ DirectWriter                ├─ Fast/DirectReader
       └─ StreamTapeWriter            └─ StreamTapeReader
```

默认兼容配置可以进入 compact fast reader；显式 `JsonReadConfig` 保留 unknown field、
duplicate key、number 和 resource-limit 语义。`YJson.fastDecoder(codec)` 复用 codec 选择，
每次调用仍创建本次输入的 reader，不持有调用方输入。

Native stream backend 处理整个 document，再通过 matching-version bulk tape 驱动同一
`JsonCodec<T>`。它不是 SAX/framing API，也不会逐字段跨 FFI。

## 三种文档路径

```text
YJson.parse          ──> JsonNode                    mutable, GC-managed
YJson.parseDocument  ──> Pure Compact facade         read-only, GC-managed
                     └─> optional Native facade       read-only, explicit close
```

Native DOM 不会自动加速 `YJson.parse`。`materialize()` 可以把 read-only document 转成
`JsonNode`，但会创建完整 AST。

## Native scanner seam

core 暴露 optional scanner、numeric scanner/tape 和 Float64 parser interface，但 core
没有 C foreign declaration。`yjson_native` 的 activation 函数安装 process-global backend；
未安装时使用 portable path。

activation 与 Native DOM 是两个独立入口。安装、移除和模式切换必须发生在并发 decode
之前。底层 contract 见 [Native internals](maintainers/native-internals.md)。

## 稳定边界

- 应用入口：`YJson`、`JsonCodec<T>`、`JsonNode`、document facade、Schema、Path/Patch。
- Generated-code bridge：public 但由 matching macro/runtime 使用，不是普通应用入口。
- Repository-only：fixtures、tests、benchmarks、release staging scripts。
- Maintainer-only：C ABI、scanner activation、symbol isolation、qualification knobs。

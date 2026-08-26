# yjson 架构

本页解释 public package、宏展开和运行时数据流。仓库文件如何进入发布包见
[Repository layout](maintainers/repository-layout.md)。

## Package graph

```text
application
└── yjson_all
    ├── yjson          # runtime、typed API、AST、Compact、generated support v1
    └── yjson_macros   # @JsonCodec、@Json、@JsonValue

explicit optional packages
├── yjson_native_accel   # 启动时一次初始化，同一 YJson API
├── yjson_algorithms     # Schema、Pointer、Path、Patch 与有限预算
├── yjson_backends       # 显式 resource-owning 高级 API
├── yjson_native         # Custom Native primitives / advanced backend
├── yjson_yyjson         # vendored yyjson advanced backend
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
consumer compiles generated code against generated_support.v1
```

macro 在声明所在 package 展开，不扫描目录，也不创建 checked-in generated 文件。生成结果
嵌入 protocol version；v1 SPI 不变时允许跨 patch 版本，版本不匹配会明确失败。
`@Json` 与 `@JsonValue` 是 expression macro：前者通过 `GeneratedSupportV1.newWriter()` 获取
窄 writer SPI 并返回 `String`，后者构造 `JsonNode`。生成源码不命名 runtime 的具体
reader/writer class。

## Typed runtime

```text
YJson.toJson / fromJson<T> / *With / stream APIs
                    │
                    ▼
        generated, built-in or custom JsonCodec<T>
                         │
                         ▼
                 one semantic engine
          ┌──────────────┴──────────────┐
          ▼                             ▼
 shared grammar + InputCursor    one writer state machine
   ┌──────┴──────┐                ┌─────┴─────────┐
   ▼             ▼                ▼               ▼
Utf8Cursor  StreamInputCursor  String/bytes   stream target
          optional Native read/write primitives
```

连续 String/bytes 输入由 `Utf8Cursor` 消费，stream 由 `StreamInputCursor` 增量补充窗口；两者
共享 string、number、whitespace 与 structural grammar，以及 normalized error mapper。
默认兼容配置可以进入 compact fast reader；显式 `JsonReadConfig` 保留 unknown field、
duplicate key、number 和 resource-limit 语义。`YJson.fastDecoder(codec)` 复用 codec 选择，
每次调用仍创建本次输入的 reader，不持有调用方输入。

writer 结构状态只存在于 core direct writer：separator、object/array 顺序、path、depth、
cycle、`maxBytes` 和 NaN/Infinity 在选择 target 前后含义不变。stream writer 只适配输出
target，不再维护另一套结构控制。

默认 stream API 真正增量读取并由同一 reader/writer 驱动，不读取到 EOF。高级
WholeDocument backend 只通过 `YJsonAdvanced.*WithBackend` 显式使用。

## 三种文档路径

```text
YJson.parse          ──> JsonNode                    mutable, GC-managed
YJson.parseDocument  ──> managed Compact facade      read-only, GC-managed
```

Native primitive 可直接驱动 managed Compact builder；临时 Native 资源在返回前释放。
`materialize()` 会把 read-only document 转成完整 `JsonNode`。

## Native scanner seam

core 没有 C foreign declaration。`YJsonNativeAccel.initialize()` 在首次普通调用前验证
ABI/protocol 与 CPU capability，安装版本化 provider，并把进程状态从 `Unconfigured` 冻结
为 `NativeFrozen`；否则首次普通调用冻结为 `PureFrozen`。相同 provider 初始化可幂等重复，
不支持卸载或运行期切换。

Native read primitive 覆盖 structural scan、string validation/unescape 与 number
scan/conversion；write primitive 覆盖 escaping、数字格式化和 buffer copy。它们只替换当前
连续窗口或 target 的 primitive，配置、错误和 writer 状态仍由 core 解释。底层 contract 见
[Native internals](maintainers/native-internals.md)。

## 稳定边界

- 默认应用入口：`YJson`、`JsonCodec<T>`、`JsonNode`、managed document facade。
- 可选算法入口：`yjson_algorithms`；默认预算可显式替换为 `.unlimited`。
- Generated-code bridge：public 但由 matching macro/runtime 使用，不是普通应用入口。
- Repository-only：fixtures、tests、benchmarks、release staging scripts。
- Maintainer-only：C ABI、scanner activation、symbol isolation、qualification knobs。

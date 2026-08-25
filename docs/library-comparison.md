# JSON 库能力对比

这张表比较固定源码/API 快照中的公开能力，不比较性能，也不把不同语言/runtime 的库解释为
可直接替换的依赖。性能数字、测量批次和稳定性门槛见[性能文档](performance/README.md)。

## 如何阅读

- ✅：审计快照存在对应的公开 API 或实现。
- ◐：只覆盖部分场景、需要间接组合，或兼容入口委托给另一套实现。
- ❌：审计快照没有对应的公开 API；这是版本结论，不代表未来版本永远不会提供。
- N/A：受语言或 runtime 边界影响，不能按同一种集成方式比较。

| 能力 | yjson | stdx.json | cjfast_json | fastjson2 | Go yyjson |
| --- | --- | --- | --- | --- | --- |
| 语言/runtime | Cangjie；默认 Pure，可选 C backend | Cangjie stdx | Cangjie | Java/JVM | Go；Pure Go、无 CGo |
| Typed object mapping | ✅ generated `JsonCodec<T>` | ✅ `DataModel` / `JsonSerializable` | ✅ `@JsonAdapter` | ✅ Java object mapping | ◐ `Marshal` / `Unmarshal` 当前委托 `encoding/json` |
| 映射代码生成 | ✅ 消费方编译期宏 | ❌ 显式 interface，无 JSON 映射宏 | ✅ `@JsonAdapter` 宏 | ✅ ASM/runtime；另有 `@JSONCompiler` | ❌ typed 入口委托 `encoding/json` |
| Mutable DOM | ✅ `JsonNode` | ✅ `JsonValue` / `JsonObject` / `JsonArray` | ◐ `Any` + `HashMap` / `ArrayList` 通用树，无专用节点 API | ✅ `JSONObject` / `JSONArray` | ✅ `MutDoc` |
| Compact/read-only DOM | ✅ Pure Compact、Custom Native、yyjson | ❌ | ❌ | ❌ 无独立 document-owned compact DOM | ✅ document-owned read-only DOM |
| Stream/token I/O | ✅ caller-owned stream，可选择 typed backend | ✅ `JsonReader` / `JsonWriter` | ✅ `JsonStreamReader` / `JsonStreamWriter` | ✅ `JSONReader` / `JSONWriter` | ◐ incremental reader；Encoder/Decoder 兼容入口委托标准库 |
| Custom codec/adapter | ✅ `JsonCodec<T>` | ✅ serializable/deserializable interfaces | ✅ `IStreamJsonAdapter<T>` | ✅ `ObjectReader` / `ObjectWriter` | ◐ 标准库兼容接口 |
| 字段映射声明 | ✅ 字段名、忽略、默认值等宏配置 | ❌ 无 JSON 字段 annotation | ✅ name/ignore/null/default annotations | ✅ annotations | ◐ Go tags，经 `encoding/json` 兼容路径 |
| Typed polymorphism | ✅ 显式 discriminator/subtype | ❌ | ❌ | ✅ opt-in AutoType | ❌ |
| JSON literal DSL | ✅ `@Json` / `@JsonValue` | ❌ | ❌ | ❌ | ❌ |
| JSON Schema | ✅ draft 2020-12 required + optional suites；可选国际化 format provider | ❌ | ❌ | ✅ 内置 `JSONSchema` | ❌ |
| 标准 path/patch | ✅ RFC 6901/6902/7386 与 RFC 9535；官方 suites 全部通过 | ❌ | ❌ | ◐ SQL:2016 JSONPath；无 RFC 6901/6902/7386 API | ✅ JSON Pointer/Patch/Merge Patch |
| 显式输入资源预算 | ✅ depth 与 byte budgets | ❌ | ❌ | ◐ `JSONReader.Context.setMaxLevel`；无统一 byte budgets | ◐ incremental reader 要求最大输入大小 |
| Native 加速 | ✅ 显式可选 Custom Native/yyjson packages | ❌ 无公开 backend 选择 | ❌ 固定提交源码无 Native/FFI backend | N/A；JVM/ASM 优化路径 | N/A；Pure Go 转译实现、无 CGo |
| Binary JSON | ❌ 仅 JSON text | ❌ | ❌ | ✅ JSONB | ❌ |

## 选型边界

- 在 Cangjie 应用中，需要编译期 typed mapping、literal DSL、mutable/compact DOM 和显式
  资源预算的一体化入口时，yjson 覆盖面最完整。
- stdx.json 是 SDK 自带的数据模型与 stream API；typed mapping 采用显式 interface，当前
  公开 API index 未显示与 `@JsonCodec` 等价的生成宏。
- cjfast_json 聚焦宏生成的 typed streaming codec，支持字段映射、自定义 adapter，以及
  `Any`/集合形式的通用可修改树；固定提交中没有专用 DOM、Schema、标准 path/patch、资源
  预算或 Native backend API。
- fastjson2 2.0.52 的能力面很广，但运行在 Java/JVM；它提供 JSONPath、JSON Schema、
  JSONB 和最大嵌套层级配置，不提供与 RFC 6901/6902/7386 对应的公开 API。它适合作为跨
  runtime 能力参照，不是 Cangjie package 的直接替代品。
- Go yyjson 主要提供只读/可修改 DOM、Pointer/Patch 与增量读取；其 `Marshal`、`Unmarshal`、
  `Encoder` 和 `Decoder` 兼容入口当前委托 Go 标准库，不能解读为 yyjson 原生 typed codec。

“能力更多”不自动意味着目标 workload 更快或部署成本更低。Native backend、document
生命周期、输入所有权和线程安全差异仍应分别查阅各库 contract。

yjson 的结论由仓库内可重复 gate 支撑：固定 revision 的 JSON Schema draft 2020-12
required suite 为 1299/1299，JSONPath CTS 为 703/703，JSON Patch tests 为 108/108。
安装 `yjson_schema_formats` provider 后，适用于当前 dialect 的 JSON Schema optional audit
为 964/964；默认不安装 provider 的 required gate 仍为 2110/2110。contract 与边界见
[Schema](schema.md)、[标准路径与 Patch](path-and-patch.md)及[测试指南](maintainers/testing.md)。

## 审计口径

本表对每个依赖固定一个源码或完整公开 API 快照，并检查与表格各行对应的公开声明。`❌` 表示
该快照没有相应能力入口，而不是仅凭 benchmark adapter 未调用某 API 得出的结论。表中不留
空白结论；无法取得固定源码或完整 API 索引时，不新增该库的结论。

## 对比快照与来源

- yjson：当前候选实现与[文档导航](README.md)，typed/DOM/backend contract 见
  [API 选择指南](choosing-an-api.md)、[Codec 生成](codec-generation.md)、
  [Backend 指南](backends.md)、[Schema](schema.md)、[标准路径与 Patch](path-and-patch.md)
  和[资源限制](resource-limits.md)。
- stdx.json：Cangjie stdx `main` 完整 API index（3141 symbols），生成时间
  `2026-08-25T10:26:12.963589Z`；主要入口为
  [`stdx.encoding.json`](https://955work.icu/dev/stdx/libs_stdx/encoding/json/json_package_api/encoding_json_package_classes.html)
  与 `stdx.encoding.json_stream`。
- cjfast_json：固定 commit
  [`eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`](https://gitcode.com/Cangjie-TPC/cjfast_json/commit/eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65)，
  审计该提交完整源码树、`README.md` 与 `doc/api.md`；性能实验使用同一提交。
- fastjson2：固定 tag [`2.0.52`](https://github.com/alibaba/fastjson2/tree/2.0.52)，审计 core、
  codegen、Kotlin module 与版本内 docs，重点核对 `JSONReader`、`JSONPath`、`JSONSchema`、
  `JSONCompiler` 和 `JSONB` 的公开实现。
- Go yyjson：[`dwisiswant0/yyjson`](https://github.com/dwisiswant0/yyjson)，对比固定在
  commit `d435bcf10652012c1c1b585f0b54068c29f2d6f5`。

该表会随依赖版本变化。新增结论时应同时更新 snapshot、直接来源和措辞。

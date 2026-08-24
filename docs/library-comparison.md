# JSON 库能力对比

这张表比较公开文档能够确认的能力，不比较性能，也不把不同语言/runtime 的库解释为可直接
替换的依赖。性能数字、测量批次和稳定性门槛见[性能文档](performance/README.md)。

## 如何阅读

- ✅：引用的公开 API 或官方文档明确提供该能力。
- ◐：只覆盖部分场景、需要间接组合，或兼容入口委托给另一套实现。
- —：本次查阅的公开资料未确认该能力；不等同于证明内部实现或扩展绝对不存在。
- N/A：受语言或 runtime 边界影响，不能按同一种集成方式比较。

| 能力 | yjson | stdx.json | cjfast_json | fastjson2 | Go yyjson |
| --- | --- | --- | --- | --- | --- |
| 语言/runtime | Cangjie；默认 Pure，可选 C backend | Cangjie stdx | Cangjie | Java/JVM | Go；Pure Go、无 CGo |
| Typed object mapping | ✅ generated `JsonCodec<T>` | ✅ `DataModel` / `JsonSerializable` | ✅ `@JsonAdapter` | ✅ Java object mapping | ◐ `Marshal` / `Unmarshal` 当前委托 `encoding/json` |
| 映射代码生成 | ✅ 消费方编译期宏 | — 公开 API index 未发现生成宏 | ✅ `@JsonAdapter` 宏 | ✅ ASM/runtime；另有 `@JSONCompiler` | — 官方 README 未记录 |
| Mutable DOM | ✅ `JsonNode` | ✅ `JsonValue` / `JsonObject` / `JsonArray` | — 官方 README 未记录 | ✅ `JSONObject` / `JSONArray` | ✅ `MutDoc` |
| Compact/read-only DOM | ✅ Pure Compact、Custom Native、yyjson | — 公开 API index 未记录 | — 官方 README 未记录 | ◐ 支持按需解析，但未作为独立 Compact document API 描述 | ✅ document-owned read-only DOM |
| Stream/token I/O | ✅ caller-owned stream，可选择 typed backend | ✅ `JsonReader` / `JsonWriter` | ✅ `JsonStreamReader` / `JsonStreamWriter` | ✅ `JSONReader` / `JSONWriter` | ◐ incremental reader；Encoder/Decoder 兼容入口委托标准库 |
| Custom codec/adapter | ✅ `JsonCodec<T>` | ✅ serializable/deserializable interfaces | ✅ `IStreamJsonAdapter<T>` | ✅ `ObjectReader` / `ObjectWriter` | ◐ 标准库兼容接口 |
| 字段映射声明 | ✅ 字段名、忽略、默认值等宏配置 | — 公开 API index 未发现 annotation | ✅ name/ignore/null/default annotations | ✅ annotations | ◐ Go tags，经 `encoding/json` 兼容路径 |
| Typed polymorphism | ✅ 显式 discriminator/subtype | — 公开 API index 未记录 | — 官方 README 未记录 | ✅ opt-in AutoType | — 官方 README 未记录 |
| JSON literal DSL | ✅ `@Json` / `@JsonValue` | — | — | ◐ Kotlin DSL；不是 Cangjie 语法 | — |
| JSON Schema | ◐ draft 2020-12 常用子集 | — 公开 API index 未记录 | — 官方 README 未记录 | ✅ | — 官方 README 未记录 |
| 标准 path/patch | ◐ DOM 索引；无标准 JSONPath/Patch | ◐ DOM 索引 | — 官方 README 未记录 | ✅ JSONPath | ✅ JSON Pointer/Patch/Merge Patch |
| 显式输入资源预算 | ✅ depth 与 byte budgets | — 公开 API index 未记录 | — 官方 README 未记录 | — 本次查阅资料未确认统一预算 API | ◐ incremental reader 要求最大输入大小 |
| Native 加速 | ✅ 显式可选 Custom Native/yyjson packages | — 用户不可选择 backend | — 官方 README 未记录 | N/A；JVM/ASM 优化路径 | N/A；项目明确 Pure Go、无 CGo |
| Binary JSON | — JSON text | — 公开 API index 未记录 | — 官方 README 未记录 | ✅ JSONB | — 官方 README 未记录 |

## 选型边界

- 在 Cangjie 应用中，需要编译期 typed mapping、literal DSL、mutable/compact DOM 和显式
  资源预算的一体化入口时，yjson 覆盖面最完整。
- stdx.json 是 SDK 自带的数据模型与 stream API；typed mapping 采用显式 interface，当前
  公开 API index 未显示与 `@JsonCodec` 等价的生成宏。
- cjfast_json 聚焦宏生成的 typed streaming codec，支持字段映射和自定义 adapter；其官方
  README 没有把 DOM、Schema 或标准 path/patch 列为产品能力。
- fastjson2 的能力面很广，但运行在 Java/JVM；它适合作为跨 runtime 能力参照，不是
  Cangjie package 的直接替代品。
- Go yyjson 主要提供只读/可修改 DOM、Pointer/Patch 与增量读取；其 `Marshal`、`Unmarshal`、
  `Encoder` 和 `Decoder` 兼容入口当前委托 Go 标准库，不能解读为 yyjson 原生 typed codec。

“能力更多”不自动意味着目标 workload 更快或部署成本更低。Native backend、document
生命周期、输入所有权和线程安全差异仍应分别查阅各库 contract。

## 对比快照与来源

- yjson：当前候选实现与[文档导航](README.md)，typed/DOM/backend contract 见
  [API 选择指南](choosing-an-api.md)、[Codec 生成](codec-generation.md)、
  [Backend 指南](backends.md)和[资源限制](resource-limits.md)。
- stdx.json：Cangjie stdx `main` API index，生成时间 `2026-08-24T03:50:21Z`；主要入口为
  [`stdx.encoding.json`](https://955work.icu/dev/stdx/libs_stdx/encoding/json/json_package_api/encoding_json_package_classes.html)
  与 `stdx.encoding.json_stream`。
- cjfast_json：官方 [`main` README](https://gitcode.com/Cangjie-TPC/cjfast_json)。能力表采用
  2026-08-24 查阅到的公开文档；性能实验另行固定在 commit
  `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`，两者不可混作同一个 snapshot。
- fastjson2：官方 [README](https://github.com/alibaba/fastjson2/blob/main/README.md)、
  [architecture](https://github.com/alibaba/fastjson2/blob/main/docs/ARCHITECTURE.md) 与
  [JSON Schema](https://github.com/alibaba/fastjson2/blob/main/docs/JSONSchema/json_schema_en.md)，
  查阅日期 2026-08-24。
- Go yyjson：[`dwisiswant0/yyjson`](https://github.com/dwisiswant0/yyjson)，对比固定在
  commit `d435bcf10652012c1c1b585f0b54068c29f2d6f5`。

该表会随依赖版本变化。新增结论时应同时更新 snapshot、直接来源和措辞，不能仅凭某次
benchmark adapter 没有调用某项 API 就判定库不支持该能力。

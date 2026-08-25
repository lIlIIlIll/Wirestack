# JSON 库能力对比

本页比较公开 API 能力，帮助选择工具；它不是性能排名。不同 runtime、数据模型和测试批次
的数字不能从能力表推导出来。

## 矩阵

`✅` 表示存在直接公开 contract，`◐` 表示部分支持或通过其他 runtime/API 间接提供，
`❌` 表示固定审计版本未发现对应公开入口。

| 能力 | yjson | stdx.json | cjfast_json | fastjson2 | Go yyjson |
| --- | --- | --- | --- | --- | --- |
| Typed object mapping | ✅ generated `@JsonCodec` | ✅ explicit model interfaces | ✅ `@JsonAdapter` | ✅ Java object mapping | ◐ typed compatibility delegates to Go stdlib |
| Mutable DOM | ✅ `JsonNode` | ✅ | ◐ generic `Any` tree | ✅ | ✅ |
| Compact/read-only DOM | ✅ Pure + optional Native | ❌ | ❌ | ❌ | ✅ |
| Stream/token I/O | ✅ backend-neutral codec | ✅ | ✅ | ✅ | ◐ reader + stdlib Decoder |
| Custom codec | ✅ | ✅ | ✅ | ✅ | ◐ |
| Generated polymorphism | ✅ explicit subtype map | ❌ | ❌ | ✅ | ❌ |
| JSON Schema | ✅ draft 2020-12 | ❌ | ❌ | ✅ | ❌ |
| Pointer / Patch / Merge / Path | ✅ / ✅ / ✅ / ✅ | ❌ | ❌ | ◐ | ✅ Pointer/Patch/Merge |
| Cangjie 直接依赖 | ✅ | ✅ SDK | ✅ | N/A，Java/JVM | N/A，Go |

## 如何使用这张表

- 需要 Cangjie typed mapping 且不希望运行时反射：比较 yjson 与 cjfast_json 的调用方生成
  模型和部署要求。
- 只需要 SDK 内置 JSON：优先评估 stdx.json，减少外部依赖。
- 需要 mutable AST、Schema、Path/Patch 组合：yjson 的 API 面更集中。
- 跨语言方案必须把 runtime、FFI、内存模型和发布方式纳入总成本，不能只比较 parser 名称。

## 固定来源

- yjson：当前 checkout 的 public declarations、[API 指南](choosing-an-api.md)、
  [Codec 生成](codec-generation.md)与[Backend 指南](backends.md)。
- stdx.json：[仓颉 stdx.encoding.json API](https://955work.icu/dev/stdx/libs_stdx/encoding/json/json_package_api/encoding_json_package_classes.html)。
- cjfast_json：固定提交
  [`eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`](https://gitcode.com/Cangjie-TPC/cjfast_json/commit/eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65)。
- fastjson2：固定 tag [`2.0.52`](https://github.com/alibaba/fastjson2/tree/2.0.52)。
- Go yyjson：[`dwisiswant0/yyjson`](https://github.com/dwisiswant0/yyjson) 固定审计快照。

需要性能决策时，应在相同主机、SDK/runtime、输入、语义和 warmup 方法下重新测量。仓库的
证据规则见[性能方法](performance/methodology.md)。

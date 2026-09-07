# JSON 库能力对比

本页按公开 API 比较功能。性能需要结合运行时、数据模型和测试条件另行测量。

## 矩阵

`✅` 表示有直接可用的公开接口，`◐` 表示部分支持或通过其他运行时/API 间接提供，
`❌` 表示在固定审计版本中未发现对应公开入口。

| 能力 | yjson | stdx.json | cjfast_json | fastjson2 | Go yyjson |
| --- | --- | --- | --- | --- | --- |
| 类型化对象映射 | ✅ `@JsonCodec` 生成 | ✅ 显式模型接口 | ✅ `@JsonAdapter` | ✅ Java 对象映射 | ◐ 类型兼容接口委托给 Go 标准库 |
| 可变 DOM | ✅ `JsonNode` | ✅ | ◐ 通用 `Any` 树 | ✅ | ✅ |
| 紧凑或只读 DOM | ✅ Pure，可选 Native | ❌ | ❌ | ❌ | ✅ |
| 流和 token 读写 | ✅ 与后端无关的 codec | ✅ | ✅ | ✅ | ◐ reader 和标准库 Decoder |
| 自定义 codec | ✅ | ✅ | ✅ | ✅ | ◐ |
| 生成多态支持 | ✅ 显式子类型映射 | ❌ | ❌ | ✅ | ❌ |
| JSON Schema | ✅ draft 2020-12 | ❌ | ❌ | ✅ | ❌ |
| Pointer / Patch / Merge / Path | ✅ / ✅ / ✅ / ✅ | ❌ | ❌ | ◐ | ✅ Pointer/Patch/Merge |
| Cangjie 直接依赖 | ✅ | ✅ SDK | ✅ | N/A，Java/JVM | N/A，Go |

## 如何使用这张表

- 需要仓颉类型映射且不希望使用运行时反射：比较 yjson 与 cjfast_json 在调用方生成
  代码的方式和部署要求。
- 只需要 SDK 内置 JSON：优先评估 stdx.json，减少外部依赖。
- 需要同时使用可变 AST、Schema 和 Path/Patch：yjson 在同一组包中提供这些 API。
- 跨语言方案必须把运行时、FFI、内存模型和发布方式纳入总成本，不能只比较解析器名称。

## 固定来源

- yjson：当前检出版本的公开声明、[API 指南](choosing-an-api.md)、
  [Codec 生成](codec-generation.md)与[后端指南](backends.md)。
- stdx.json：[仓颉 stdx.encoding.json API](https://955work.icu/dev/stdx/libs_stdx/encoding/json/json_package_api/encoding_json_package_classes.html)。
- cjfast_json：固定提交
  [`eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`](https://gitcode.com/Cangjie-TPC/cjfast_json/commit/eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65)。
- fastjson2：固定 tag [`2.0.52`](https://github.com/alibaba/fastjson2/tree/2.0.52)。
- Go yyjson：[`dwisiswant0/yyjson`](https://github.com/dwisiswant0/yyjson) 固定审计快照。

需要性能决策时，应在相同主机、SDK 和运行时、输入、语义和预热方法下重新测量。仓库的
证据规则见[性能方法](performance/methodology.md)。

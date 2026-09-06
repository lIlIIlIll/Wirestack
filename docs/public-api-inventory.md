# yjson 0.1 公开 API 清单

本页说明 `0.1.x` 的发布边界。完整声明列表位于
[`release/public-api-snapshot.txt`](../release/public-api-snapshot.txt)，经过评审的 breaking
与 additive 变化位于
[`release/public-api-inventory.toml`](../release/public-api-inventory.toml)。相对于冻结基线的完整
Cangjie 声明差异及逐项分类位于
[`release/public-cangjie-delta-bfd29.toml`](../release/public-cangjie-delta-bfd29.toml)。

运行：

```terminal
python3 scripts/check_api_inventory.py
```

命令检查九包版本配套、release graph、inventory、快照生成器回归测试和当前快照。任一未评审
差异都会返回非零状态。

## 默认产品面

普通应用使用以下入口：

```cangjie
YJson.toJson(value)
YJson.fromJson<T>(text)
YJson.parseDocument(text)
JsonNode.parse(text)
```

`JsonDocument` 提供 `root()`、`materialize()` 和 JSON 输出。它不包含 backend identity、
`Resource`、`close()` 或 `isClosed()`。String、bytes 和 stream overload 使用同一
`JsonReadOptions`、`JsonWriteOptions`、codec 和 error contract。

`JsonValueView` 是 read-only interchange boundary。managed document、高级 backend 和
`JsonNode` 都能交给 serializer 与算法；修改只通过明确的 `JsonNode` API 发生。

## 快照收集范围

生成器收集顶层 public declaration、外部可见 public 类型的成员、interface 的隐式 public
成员和 enum case。private 或默认 internal 类型中的 public 成员不会进入快照。多行类型头被
规范化成单条声明。C ABI 快照另含 `native/*.h` 导出的 `YJ_*` prototype。

快照是 fail-closed 差异检测，不替代兼容性评审。公开声明变化时，先运行：

```terminal
python3 scripts/generate_public_api_snapshot.py --write
```

随后逐条审查 diff，并同步 inventory。不要手工编辑快照。

差异文件把每条 removed/added declaration 放入且只放入一个 review group。每组记录分类、
理由和 review status；全局 `approved-for-release` 只有在没有漏项、重复项、未分类声明或 pending
group 时才有效。`release-ready` graph 会再次执行这项检查。

## Generated-code protocol

`yjson` 与 `yjson_macros` 是同一个 lockstep release。macro 输出面向
`generated_support.v1` 并嵌入 protocol version 1；不匹配时明确失败。

普通 generated codec bridge 是
`GeneratedCodecProviderV1<T>.generatedCodecV1(_: GeneratedCodecTokenV1<T>): JsonCodec<T>`。
`GeneratedCodecTokenV1<T>` 是零状态的重载 token，使继承链上的父类和子类各自返回精确
`JsonCodec<T>`。宏展开和 runtime dispatch 之间不经过 `Any`、erase/reify adapter 或运行时
类型转换。

bridge 声明因跨 package 展开而必须 public，但不是普通应用入口。应用使用 `@JsonCodec`、
`JsonCodec<T>`、`YJson` 和 `JsonCodecs`。

## 可选 package

| Package | 用途 | 生命周期 |
| --- | --- | --- |
| `yjson_macros` | 编译期 generated codec | 与 runtime lockstep，不在运行期加载 |
| `yjson_algorithms` | Pointer、Patch、Path 和 Schema | 默认有限预算；cursor 单线程 |
| `yjson_schema_formats` | 国际化 Schema format | 在 Schema 构造前安装到 registry |
| `yjson_native_accel` | 启动时初始化 Native primitive | 进程级冻结；不能 uninstall 或切换 |
| `yjson_native_primitives` | scanner/provider closed SPI | 只供第一方 Native package |
| `yjson_backends` | metadata 和 explicit-resource interface | 不提供任意 strategy registry |
| `yjson_native` | `NativeBackends.customNative` | 返回显式 resource |
| `yjson_yyjson` | `YyjsonBackends.yyjson` | 返回显式 resource |

Schema resource URI 只通过注入的 `UriResolver` 在构造阶段解析。成功构造后，compiled schema
不再保留 resolver。

## 兼容性结论

`0.1.0` 有意重置成熟度版本并允许 breaking change，不提供旧 API alias、deprecated shim 或
umbrella package。后续 `0.1.y` patch 应保持已记录的应用 API 兼容；需要 breaking change 时
提升到新的 `0.x.0` minor，并提供 machine API diff。

### Binary compatibility

Cangjie 声明快照（`release/public-api-snapshot.txt` 与 delta TOML）只证明源码级 API 表面
未漂移，**不等于二进制兼容证明**。源码兼容不能覆盖编译产物层面的变化：cjc 对同一声明
可能生成不同符号名、方法表布局或内联行为；跨 nightly 或跨 patch 的预编译 consumer
可能在链接期或运行期失败，即使声明 diff 为空。

因此 0.1 线的 binary 兼容性以实测为准：release 前必须用冻结的旧 consumer artifact（用上一
个 release 的 SDK 与九包构建的应用或 fixture）对新版九包做链接/调用矩阵验证。矩阵至少覆盖：

- 普通 `YJson` 调用（encode/decode、parseDocument）；
- generated codec（`@JsonCodec` 展开的调用方）与 generated-support v1 入口；
- algorithms（Pointer/Patch/Path/Schema）与 schema-formats 动态库链接；
- Native/yyjson backend 的显式 resource 生命周期调用；
- 跨 package 依赖图中每个 `output-type = "dynamic"` 包的链接。

**0.1.0 状态：NOT PROVIDED。** 首个 release 没有更旧的 consumer artifact 可测，0.1.0 的
binary compatibility 声明不提供；后续 0.1.y 的矩阵证据应写入 `release/<version>/evidence.md`。
在矩阵通过之前，任何"二进制兼容"或"补丁版本可安全替换"的表述都不得出现在文档或 release
notes 中。

历史 1.x/2.0 tag 和 release evidence 保持不可变，只用于审计与基线，不代表当前
`0.1.x` API。九包顺序与 stability 分类来自
[`release/release-graph.toml`](../release/release-graph.toml)。

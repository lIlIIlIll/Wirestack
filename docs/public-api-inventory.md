# yjson 2.0 公开 API 清单

本页说明 2.0 的发布边界。完整声明列表位于
[`release/public-api-snapshot.txt`](../release/public-api-snapshot.txt)，经过评审的 breaking 与
additive 变化位于
[`release/public-api-inventory.toml`](../release/public-api-inventory.toml)。运行以下命令同时
检查 package 版本配套、inventory、快照生成器回归测试和当前快照：

```terminal
python3 scripts/check_api_inventory.py
```

成功时，命令依次输出快照生成器测试、快照声明数和已评审变化数；任一差异都会返回非零状态。

## 默认产品面

普通应用通过 GC 管理的跨平台引擎使用以下入口：

```cangjie
YJson.toJson(value)
YJson.fromJson<T>(text)
YJson.parseDocument(text)
```

`JsonDocument` 提供只读 view、`materialize()` 和 JSON 输出。它不包含 backend identity、
`Resource`、`close()` 或 `isClosed()`。默认 stream 入口是增量实现，也没有 backend 参数。

`JsonReadConfig` 与 `JsonWriteConfig` 分别组合 `JsonReadLimits` 和 `JsonWriteLimits`。built-in、
generated、stream 与 accelerated 执行使用相同的 limits、duplicate-field policy、数字规则、
path 和 error 语义。

## 快照收集范围

生成器收集顶层公开声明、外部可见公开类型的成员、interface 的隐式公开成员和 enum case。
private 或默认 internal 类型中的 `public` 成员不会进入快照。多行类型头会被合并为单条规范化
声明。C ABI 快照还包含 `native/*.h` 中导出的 `YJ_*` prototype。

快照是 fail-closed 差异检测，不替代兼容性评审。公开声明发生变化时，先运行
`python3 scripts/generate_public_api_snapshot.py --write`，再逐条审查生成差异并同步 inventory。
不要手工编辑快照文件。

## Generated-code protocol

`yjson` 与 `yjson_macros` 是一个发行单元。macro 输出面向 `generated_support.v1` 并嵌入
protocol version 1。稳定的 v1 SPI 允许 runtime 在 patch 版本间升级；protocol 不匹配时会明确
失败，不依赖 exact-checkout 配套。

实现内部包含供 runtime 与 macro bridge 使用的 direct reader/writer helper，但生成源码只引用
版本化 support 名称。这些 helper 不是应用入口。

## 可选 package

| Package | 用途 | 生命周期 |
| --- | --- | --- |
| `yjson_native_accel` | 启动时调用一次 `YJsonNativeAccel.initialize()` | 冻结进程引擎；不能 uninstall 或在运行时切换 |
| `yjson_algorithms` | Pointer、Patch、Merge Patch、JSONPath 和 Schema | 默认使用有限预算；`.unlimited` 必须显式选择 |
| `yjson_backends` | 高级 Custom Native/yyjson DOM 和 WholeDocument stream adapter | 显式持有 `BackendJsonDocument` 资源 |
| `yjson_schema_formats` | 可选的国际化 Schema format | 安装到显式 registry |

Schema resource URI 只能通过注入的 `UriResolver` 解析；core 不发起网络访问。

## 兼容性结论

2.0 有意引入 source 与 ABI breaking change：移除默认 backend 选择和 document resource 方法，
把 algorithms 与高级 backend 移至独立 package，以单向启动冻结替代可变的 runtime backend
安装，并把资源限制组合到 limits 对象中。不提供兼容别名或 deprecated shim。迁移步骤见
[`migration/1.x-to-2.0.md`](migration/1.x-to-2.0.md)。

历史 1.0 release evidence 保存在 `release/1.0.0-*`。这些文件描述不可变的历史 artifact，
不代表 2.0 API。

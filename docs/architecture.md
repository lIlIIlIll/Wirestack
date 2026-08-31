# yjson 架构

本页解释 public package、宏展开和运行时数据流。源码如何进入发布候选见
[Repository layout](maintainers/repository-layout.md)。

## Package graph

```text
yjson
├── yjson_macros ────────────────> yjson
├── yjson_algorithms ────────────> yjson
├── yjson_backends ──────────────> yjson
├── yjson_native_primitives ─────> yjson
├── yjson_native_accel ──────────> yjson_native_primitives
├── yjson_native ────────────────> yjson + yjson_backends
│                                  + yjson_native_primitives
├── yjson_yyjson ────────────────> yjson + yjson_backends
│                                  + yjson_native_primitives
└── yjson_schema_formats ────────> yjson + yjson_algorithms
```

箭头表示左侧依赖右侧。九个 package 使用同一 `0.1.x` 版本和候选 SHA。
[`release/release-graph.toml`](../release/release-graph.toml) 是发布顺序、source root、
stability 和依赖闭包的清单。仓库不发布 umbrella package。

根 development manifest 只通过 `[test-dependencies]` 使用 macros；core runtime 没有
runtime → macro 环。所有 cjpm 测试文件使用 `*_test.cj` 后缀，使 cjpm 与 cjdoc 使用同一隔离
规则。

## 编译期路径

```text
consumer declaration
        │ @JsonCodec
        ▼
yjson_macros expansion
        ├── generated JsonCodec<T>
        ├── generated <Type>Json value/function
        ├── GeneratedCodecTokenV1<T> -> GeneratedCodecProviderV1<T> -> JsonCodec<T>
        └── typed object-provider bridge for concrete classes and structs
        ▼
consumer compiles against generated_support.v1
```

macro 在声明所在 package 展开，不扫描目录，也不创建 checked-in generated 文件。输出嵌入
protocol version 1；protocol 不匹配会明确失败。生成代码只通过版本化 reader/writer bridge
进入 runtime，不命名具体 parser class。普通 provider 直接返回 `JsonCodec<T>`，不经过
`Any` 装箱或运行时 cast。零状态 type token 使父类和子类 provider 形成参数重载。多态
dispatcher 通过 subtype 自己的 typed object provider 读写字段；直接编码 concrete subtype
时，宏组合 base 和 subtype object fields。

## Typed runtime

```text
YJson.toJson / fromJson / toJsonBytes / writeJson
                    │
                    ▼
       generated, built-in or custom JsonCodec<T>
                    │
                    ▼
             one semantic engine
       ┌────────────┴────────────┐
       ▼                         ▼
 shared grammar + cursor    writer state machine
   ┌───┴────┐                 ┌──┴──────────┐
   ▼        ▼                 ▼             ▼
 bytes   InputStream       String/bytes  OutputStream
       optional Native primitives
```

String/bytes 和 stream 共享 grammar、error mapper、read options 和 codec contract。stream
只改变输入窗口与输出 target，不维护第二套 JSON 语义。普通 stream 增量读取一个 document，
不会先读取到 EOF。

writer 统一维护 separator、object/array 状态、单根值、path、depth、output budget 和非有限
浮点拒绝。String、bytes、stream、generated 和 `JsonValueView` 都通过这套状态机。

## 三条文档路径

```text
JsonNode.parse                  -> JsonNode
YJson.parseDocument             -> JsonDocument -> JsonValueView
Native/Yyjson named facade      -> BackendJsonDocument -> JsonValueView
```

`JsonNode` 可修改。`JsonDocument` immutable 且由 GC 管理。高级 backend document immutable
但实现 `Resource`，需要关闭。三者通过 `JsonValueView` 汇合，算法和 serializer 不需要按
storage type 分叉。materialization 默认有 100,000 节点和 256 层边界。

## Native scanner seam

core 没有 C foreign declaration。`YJsonNativeAccel.initialize()` 在首次普通调用前验证
provider identity、protocol、ABI 和 CPU capability。状态从 `Unconfigured` 进入初始化后，
最终冻结为 Pure 或 Native；并发初始化和普通调用由同一状态机线性化。

Native primitive 覆盖 structural scan、UTF-8/string、number 和写出热点。配置、error、codec
和 writer 状态仍由 core 解释。provider 故障不能静默切回 Pure。

首次冻结或初始化通过 Mutex 线性化。终态通过 atomic frozen flag 发布；之后普通 `YJson`
调用只执行原子读，不再获取 process-wide Mutex。

`yjson_native_primitives` 独占 scanner archive、原生链接和 provider 实现。它的 public
声明是第一方 package bridge，不是普通应用入口。

## 算法扩展

`yjson_algorithms` 只依赖 `JsonValueView`：

- JSONPath 的 `matches()` 返回惰性、单线程 cursor；
- Patch 显式区分 copy-on-apply 和 in-place；
- Schema 构造时复制根文档、解析完整 resolver 图并编译受限 regex；
- validation 阶段不保留 resolver，不执行网络访问；
- 所有算法默认使用有限工作预算。

未来 backend 可以接入统一 view façade，不需要向 core 的最短 typed API 增加策略参数。

## 稳定边界

- 默认应用入口：`YJson`、`JsonCodec<T>`、`JsonNode`、`JsonDocument`。
- 可选算法入口：`yjson_algorithms`，默认预算有限。
- 高级 backend：只有命名 façade，不暴露任意 strategy 注入。
- Generated-code bridge：public 但只供 matching macro/runtime。
- Maintainer-only：C ABI、scanner activation、symbol isolation 和 qualification knob。
- Repository-only：fixtures、tests、benchmarks 和 release staging scripts。

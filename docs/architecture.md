# yjson 架构

本页说明包的依赖关系、宏展开和运行时数据流。发布源码的组织方式见
[仓库布局](maintainers/repository-layout.md)。

## 包依赖关系

```text
yjson
├── yjson_macros (standalone repository) ─> yjson
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

普通箭头表示左侧的 cjpm module 依赖右侧；`yjson_macros → yjson` 是例外，表示宏展开产物
面向 runtime，而不是宏模块自身的直接依赖。九个包使用同一 `0.1.x` 版本和候选 SHA；
`yjson_macros` 的源码仓库为 [`lIlIIlIll/yjson_macros`](https://github.com/lIlIIlIll/yjson_macros)。主
仓库的发布清单仍记录该宏包的 lockstep 版本。仓库不发布统一导出所有功能的包。

开发用的根清单只通过 `[test-dependencies]` 使用宏；核心运行时没有
指向宏包的循环依赖。所有 cjpm 测试文件使用 `*_test.cj` 后缀，使 cjpm 与 cjdoc 按同一规则排除测试代码。

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

宏在声明所在包展开，不扫描目录，也不生成需要提交到仓库的文件。输出嵌入
协议版本 1；协议不匹配会报错。生成代码只通过带版本的读写接口
调用运行时，不依赖具体解析器类。普通 provider 直接返回 `JsonCodec<T>`，不经过
`Any` 装箱或运行时类型转换。不保存状态的类型标记使父类和子类 provider 形成参数重载。多态
分派器通过子类型自己的对象 provider 读写字段；直接编码具体子类型
时，宏组合基类和子类型的对象字段。

## 类型化读写

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

字符串、字节数组和流共用语法、错误映射、读取选项和 codec 接口。流只改变输入窗口与
输出目标，JSON 语义保持一致。普通流接口增量读取一份文档，不会先读取到 EOF。

写入器统一管理分隔符、对象和数组状态、单根值、路径、深度及输出预算，并拒绝非有限浮点数。
字符串、字节数组、流、宏生成的 codec 和 `JsonValueView` 都通过这套状态机写出。

## 三种文档表示

```text
JsonNode.parse                  -> JsonNode
YJson.parseDocument             -> JsonDocument -> JsonValueView
Native/Yyjson named facade      -> BackendJsonDocument -> JsonValueView
```

`JsonNode` 可修改。`JsonDocument` 不可变，由 GC 管理。独立后端返回的文档也不可变，
但实现了 `Resource`，需要关闭。三者都提供 `JsonValueView`，算法和序列化器无需区分
底层存储。将视图转换为 AST 时，默认最多转换 100,000 个节点、256 层。

## Native 扫描器接口

核心包没有 C 外部函数声明。`YJsonNativeAccel.initialize()` 在首次普通调用前验证
provider 标识、协议、ABI 和 CPU 能力。状态从 `Unconfigured` 进入初始化后，
最终冻结为 Pure 或 Native；并发初始化和普通调用由同一状态机确定执行顺序。

Native 底层操作覆盖结构扫描、UTF-8 与字符串处理、数字处理，以及写出热点。配置、错误、
codec 和写入器状态仍由核心包处理。provider 故障不能静默切回 Pure。

首次冻结或初始化通过 Mutex 确定执行顺序。终态通过原子标记发布；之后普通 `YJson`
调用只执行原子读，不再获取进程级 Mutex。

`yjson_native_primitives` 负责扫描器静态库、原生链接和 provider 实现。它公开的
声明用于第一方包之间的调用，不供普通应用使用。

## 算法扩展

`yjson_algorithms` 只依赖 `JsonValueView`：

- JSONPath 的 `matches()` 返回按需遍历的单线程游标；
- Patch 区分返回副本和原地修改；
- Schema 构造时复制根文档、解析所有外部引用并编译受限正则表达式；
- 校验阶段不保留 resolver，不执行网络访问；
- 所有算法默认使用有限工作预算。

新后端可以实现统一的视图接口，核心类型化 API 无需增加策略参数。

## 稳定边界

- 默认应用入口：`YJson`、`JsonCodec<T>`、`JsonNode`、`JsonDocument`。
- 可选算法入口：`yjson_algorithms`，默认预算有限。
- 高级后端：通过各自的命名入口访问，不支持任意策略注入。
- 生成代码接口：公开可见，但只供匹配版本的宏和运行时使用。
- 维护者接口：C ABI、扫描器激活、符号隔离和发布验证参数。
- 仅仓库使用：测试数据、测试、基准测试和发布暂存脚本。

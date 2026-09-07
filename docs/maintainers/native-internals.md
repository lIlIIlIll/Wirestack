# Native 加速与高级后端内部实现约定

普通应用的启用方式和后端选择见
[后端使用指南](../backends.md)。本页记录 provider、C ABI、符号隔离、生命周期和
发布验证要求。

## 产品边界

Pure `yjson` 是默认实现和语义参照，不包含外部函数声明，也不链接 Native。

- `yjson_native_accel` 只公开 `YJsonNativeAccel.initialize()`；
- `yjson_native_primitives` 拥有扫描器静态库和 v1 provider；
- `yjson_native` 提供 `NativeBackends.customNative`；
- `yjson_yyjson` 提供 `YyjsonBackends.yyjson`，不参与默认引擎选择。

缺失符号、ABI 或协议不匹配、CPU 能力不足，以及激活失败，都必须报错，不能
返回 Pure 成功的结果。

yyjson 包内置 0.12.0 源码，以静态方式链接，并将公开 C 符号设为隐藏。
仓颉共享库不应导出 `yyjson_*`。双版本测试检查应用同时链接固定的
0.11.1 时，无论加载顺序如何，适配器都绑定自身的 0.12.0。

## 进程级初始化

状态转换为：

```text
Unconfigured -- first ordinary call --> PureFrozen
Unconfigured -- initialize() --------> Initializing --> NativeFrozen
```

初始化期间，其他普通调用等待结果；同线程重入调用会报错。相同 provider 重复初始化
幂等。Pure 已冻结后的晚初始化、不同 provider 竞争、协议或 ABI 不匹配，以及激活失败都抛出 `JsonException`，错误码以 `acceleration_` 开头。

不提供卸载、模式选择或运行期切换。成功激活后的 provider 故障必须向调用方暴露，
不能静默切回 Pure。底层操作在接管 token 前返回协议规定的“不适用”状态，属于解析和编码实现
的正常分支，不属于故障回退。

## 共用解析和编码规则

启用 Native 后，核心包仍负责解析和编码的选项、路径、深度、预算、错误映射
及写入器状态：

- 读取操作执行结构扫描、UTF-8 与字符串校验、转义还原、数字扫描和转换；
- 写出操作执行转义、数字格式化和连续缓冲区复制；
- 分隔符、容器状态、循环引用、`maxOutputBytes` 和非有限浮点拒绝仍由核心包控制；
- 普通流接口继续增量消费，不能为了调用 Native 改为先读到 EOF。

`YJ_JSON_ParseDouble` 只接收已经验证的数字 token，最多复制 256 字节到有界栈缓冲区。接口不执行仓颉回调、I/O 或阻塞操作。

## GC 管理的文档与显式资源

`YJson.parseDocument` 返回 GC 管理的不可变 `JsonDocument`。Native 临时对象在返回前
释放；返回的文档没有 `close()`、`isClosed()` 或后端标识。

只有独立后端入口返回的 `BackendJsonDocument` 是显式资源。Custom Native 和 yyjson
文档的共同约定：

- 文档和视图在打开期间不可变，读取之间可并发；
- `close()` 幂等；
- 读取和关闭由内部读写锁确定执行顺序；
- 竞争中的操作要么完成，要么抛出 `JsonException(code: "resource_closed")`；
- 所属文档关闭后，先前取得的视图也失效；
- 析构函数只用于回收未关闭的资源。

这两个解析器通过 C 接口处理整份文档，适合粗粒度查询、批量遍历和原生序列化。
逐节点取值会反复承担 FFI 调用成本。它们的流元数据报告为 `WholeDocument`，
普通流接口仍保持增量读取。

## ABI、数字与错误

provider 初始化调用 v1 探测函数；结果必须为 `0x594A0101`，并校验协议、ABI 和能力。
这三项是独立版本边界，任一不匹配都失败。

所有路径保留精确 `Int64` 和 `UInt64` 边界；溢出、小数、指数和 `-0` 按
JSON 数字语义处理。重复键默认 `Reject`，比较解码后的键字节，因此 `"a"` 与
`"\u0061"` 冲突。`LastWins` 只能显式选择。

Native 消息不要求与 Pure 逐字一致，但公开 `JsonException.code`、路径、位置和预算
语义必须一致。受限解析使用 `*ParseWithLimits` C 符号；C ABI 的零值仅用于内部
“不设该原生限制”的表示，不能覆盖 `JsonReadOptions` 的正数约定。

## 安全性与发布验证

Native 语义索引使用每份文档独立的随机种子，并始终执行精确字节比较。
Linux 熵源顺序为 `getrandom`、`/dev/urandom`、进程专用的备用方案。随机化降低
可预测碰撞风险，但不承诺开放寻址表不存在最坏情况。

发布验证包含畸形输入测试、无编译警告的 Clang/GCC、ASan、UBSan、
LSan、固定种子的差分模糊测试、分配失败和生命周期、符号隔离，以及
固定 CPU 的 Pure/Native 交替性能检查。发布证据记录对应的源码、SDK、运行器和校验和，
性能结论仅适用于该次验证的版本与环境。


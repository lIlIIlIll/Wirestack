# Native 加速与高级 Backend 内部契约

普通应用的启用方式与显式 DOM/stream 选型见 [Backend 使用指南](../backends.md)。本页只
记录 provider、C ABI、symbol isolation、生命周期和 qualification 等维护者边界。

## 产品边界

Pure `yjson` 是默认实现和语义 oracle，不包含 foreign declaration，也不链接 Native：

- `yjson_native_accel` 只公开 `YJsonNativeAccel.initialize()`；成功初始化后应用继续调用相同
  的 `YJson` API。
- `yjson_native` 提供 Custom Native primitive provider，也保留显式高级 backend。
- `yjson_yyjson` 是显式高级 backend，不参与默认 `YJson` 引擎选择。
- 不支持的平台在构建 optional package 时失败；缺失符号、ABI/protocol 或 CPU capability 问题
  在 `initialize()` 时失败，不能伪装成 Pure 成功。

yyjson package 静态 vendoring 0.12.0，并以 hidden visibility 编译其 public C symbols。
Cangjie shared library 不应导出 `yyjson_*`。dual-version fixture 需要证明应用同时链接固定
0.11.1 时，无论加载顺序如何，adapter 都绑定自己的 0.12.0。

## 进程级 activation

core 的状态只允许以下转换：

```text
Unconfigured -- first YJson call --> PureFrozen
Unconfigured -- initialize() -----> NativeFrozen
```

相同 Native provider 可幂等重复初始化。Pure 已冻结后的晚初始化、不同 provider 竞争、
ABI/protocol 不匹配都抛出 `JsonAccelerationException`。没有 uninstall、模式选择或运行期切换。
内部 `enableYJsonNative()` 只是 `yjson_native_accel` 绑定 provider 的实现细节，不是应用入口。

成功初始化后的 provider 执行故障必须向调用方暴露，不能静默切回 Pure。primitive 在接管
token 前返回协议规定的“不适用”状态仍是合法的 semantic-engine 分支；这与执行失败后的
fallback 不同。

## 单一 semantic engine

Native 不是第二套 parser/writer。core 继续拥有配置、路径、深度、limits、错误映射和 writer
结构状态：

- read primitive 可完成 structural scan、UTF-8/string validation 与 unescape、number scan 与
  conversion，并驱动 managed AST、Compact 或 typed reader builder；
- write primitive 可完成 escaping、数字格式化和连续 buffer copy；separator、object/array
  状态、cycle、`maxBytes` 与 NaN/Infinity 仍由 core writer 决定；
- primitive 只处理当前连续窗口或有界 scratch。默认 stream API 仍由 `StreamInputCursor`
  增量消费，不能为了调用 Native 偷换成 read-to-EOF。

`YJ_JSON_ParseDouble` 接收已验证 number token，最多复制 256 bytes 到有界 stack buffer。
bridge 不执行 Cangjie callback、I/O 或阻塞操作。

## Managed document 与显式资源

`YJson.parseDocument` 始终返回 GC 管理的 Compact document。Native 临时对象在返回前释放，
公开 document 没有 `close()`、`isClosed()` 或 backend identity。

只有 `YJsonAdvanced.*WithBackend` 返回的 `BackendJsonDocument` 是显式 resource。Custom Native
DOM 与 yyjson DOM 的 document contract 为：

- `close()` 幂等且需要独占所有权；
- read/read 并发也由调用方同步；
- read/close、serialize/close race 禁止；
- close 后操作抛出 `IllegalStateException`；
- view 保持 owner 可达，但 owner close 后 view 无效；
- destructor 只用于泄漏兜底。

这两个高级 DOM parser 使用 whole-document C 边界，适合 coarse lookup、bulk traversal 与
native serialization。大量 per-node getter 会放大 FFI 固定成本。明确命名的
`WholeDocument` stream backend 同样不代表默认 stream API。

## ABI、数字与错误

provider 初始化先调用 v1 probe；返回值必须为 `0x594A0101`，并校验要求的 capability bit。
probe、ABI 和 generated-support protocol 是独立版本边界，任何一项不匹配都必须明确失败。

所有路径保留精确 `Int64`；overflow integer、decimal、exponent、`-0` 与
`PreserveLiteral` 保持 literal 语义。duplicate key 默认 LastWins，Reject 比较 decoded key
bytes，因此 `"a"` 和 `"\u0061"` 冲突。

Native message 和细分类不要求与 Pure 逐字一致；无效输入必须拒绝，并在可用时给出 byte
offset。资源预算的公开 error code 必须跨路径一致。limited parse 使用 additive
`*ParseWithLimits` C symbols；全零预算继续走旧 ABI。

## 安全与 qualification

Native semantic index 使用 per-document randomized seed，并始终执行 exact byte equality。
Linux entropy 顺序为 `getrandom`、`/dev/urandom`、process-specific fallback。随机化降低可
预测 collision 攻击，但不承诺开放寻址表不存在最坏情况。

Native release qualification 必须包含 malformed-input targeted tests、warning-clean
clang/gcc、ASan、UBSan、LSan、确定性 differential fuzz、allocation failure/lifecycle、
symbol isolation，以及固定 CPU/heap 的 Pure/Native 交替性能门禁。结果记录在具体 release
evidence 或带日期结果页，不写成无版本的永久性能声明。

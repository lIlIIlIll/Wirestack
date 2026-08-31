# Native 加速与高级 Backend 内部契约

普通应用的启用方式和显式 document/I/O 选型见
[Backend 使用指南](../backends.md)。本页记录 provider、C ABI、symbol isolation、生命周期和
qualification 等维护边界。

## 产品边界

Pure `yjson` 是默认实现和语义 oracle，不包含 foreign declaration，也不链接 Native。

- `yjson_native_accel` 只公开 `YJsonNativeAccel.initialize()`；
- `yjson_native_primitives` 拥有 scanner archive 和 v1 provider；
- `yjson_native` 提供 `NativeBackends.customNative`；
- `yjson_yyjson` 提供 `YyjsonBackends.yyjson`，不参与默认 engine 选择。

缺失 symbol、ABI/protocol mismatch、CPU capability 不足或 activation 失败都必须明确失败，不能
伪装成 Pure 成功。

yyjson package 静态 vendoring 0.12.0，并以 hidden visibility 编译 public C symbol。
Cangjie shared library 不应导出 `yyjson_*`。dual-version fixture 证明应用同时链接固定
0.11.1 时，无论加载顺序如何，adapter 都绑定自身 0.12.0。

## 进程级 activation

状态转换为：

```text
Unconfigured -- first ordinary call --> PureFrozen
Unconfigured -- initialize() --------> Initializing --> NativeFrozen
```

初始化期间，其他普通调用等待结果；同线程 reentrant use 明确失败。相同 provider 重复初始化
幂等。Pure 已冻结后的晚初始化、不同 provider 竞争、protocol/ABI mismatch 和 activation
failure 都抛出 `JsonException`，code 以 `acceleration_` 开头。

没有 uninstall、mode selector 或运行期切换。成功激活后的 provider 故障必须向调用方暴露，
不能静默切回 Pure。primitive 在接管 token 前返回协议规定的“不适用”状态，属于 semantic
engine 的正常分支，不是故障 fallback。

## 单一 semantic engine

Native 不是第二套 parser/writer。core 继续拥有 options、path、depth、budget、error mapping
和 writer state：

- read primitive 执行 structural scan、UTF-8/string validation、unescape、number scan 和
  conversion；
- write primitive 执行 escaping、数字格式化和连续 buffer copy；
- separator、container state、cycle、`maxOutputBytes` 和非有限浮点拒绝仍由 core 控制；
- ordinary stream 继续增量消费，不能为了调用 Native 偷换成 read-to-EOF。

`YJ_JSON_ParseDouble` 只接收已经验证的 number token，最多复制 256 bytes 到有界 stack
buffer。bridge 不执行 Cangjie callback、I/O 或阻塞操作。

## Managed document 与显式资源

`YJson.parseDocument` 返回 GC 管理的 immutable `JsonDocument`。Native 临时对象在返回前
释放；public document 没有 `close()`、`isClosed()` 或 backend identity。

只有命名 façade 返回的 `BackendJsonDocument` 是显式 resource。Custom Native 和 yyjson
document 的共同 contract：

- document 和 view 在打开期间 immutable，read/read 可并发；
- `close()` 幂等；
- read/close 由内部 read-write lock 线性化；
- 竞争中的操作要么完成，要么抛出 `JsonException(code: "resource_closed")`；
- owner close 后，先前取得的 view 也失效；
- destructor 只作为泄漏兜底。

这两个 parser 使用 whole-document C 边界，适合 coarse lookup、bulk traversal 和 native
serialization。大量 per-node getter 仍会放大 FFI 固定成本。façade stream metadata 明确报告
`WholeDocument`，不改变 ordinary stream 的 incremental contract。

## ABI、数字与错误

provider 初始化调用 v1 probe；结果必须为 `0x594A0101`，并校验 protocol、ABI 和 capability。
这三项是独立版本边界，任一 mismatch 都失败。

所有路径保留精确 `Int64` 和 `UInt64` 边界；overflow、decimal、exponent 和 `-0` 保留
JSON number 语义。duplicate key 默认 `Reject`，比较 decoded key bytes，因此 `"a"` 与
`"\u0061"` 冲突。`LastWins` 只能显式选择。

Native message 不要求与 Pure 逐字一致，但公开 `JsonException.code`、path、location 和预算
语义必须一致。limited parse 使用 `*ParseWithLimits` C symbol；C ABI 的零值仅用于内部
“不设该 native limit”表示，不能覆盖 `JsonReadOptions` 的正数 contract。

## 安全与 qualification

Native semantic index 使用 per-document randomized seed，并始终执行 exact byte equality。
Linux entropy 顺序为 `getrandom`、`/dev/urandom`、process-specific fallback。随机化降低
可预测 collision 风险，但不承诺开放寻址表不存在最坏情况。

release qualification 包含 malformed-input tests、warning-clean Clang/GCC、ASan、UBSan、
LSan、deterministic differential fuzz、allocation failure/lifecycle、symbol isolation，以及
固定 CPU 的 Pure/Native 交替性能门禁。结果写入绑定 source/SDK/runner/checksum 的 release
evidence，不写成无版本的永久性能声明。


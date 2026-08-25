# Native backend 内部契约

用户安装、选型和生命周期见 [Backend 使用指南](../backends.md)。本页只记录 C ABI、
activation、symbol isolation、语义索引和安全验证等维护者边界。

## 产品边界

Pure `yjson` 是默认实现和语义 oracle，不链接 Native。`yjson_native` 与 `yjson_yyjson` 是
显式 optional package；选中后构建/链接失败必须暴露，不能假装回退成功。backend 内部可在
保持 public contract 时选择 portable 子路径。

yyjson package 静态 vendoring 0.12.0，并以 hidden visibility 编译其 public C symbols。
Cangjie shared library 不应导出 `yyjson_*`。dual-version fixture 需要证明应用同时链接固定
0.11.1 时，无论加载顺序如何，adapter 都绑定自己的 0.12.0。

## 生命周期与线程

Native document 实现 `Resource`：

- `close()` 幂等且需要独占所有权；
- 所有 read/read 并发也由调用方同步；
- read/close、serialize/close race 禁止；
- close 后操作抛出 `IllegalStateException`；
- view 保持 owner 可达，但 owner close 后 view 无效；
- destructor 只用于泄漏兜底。

## Access model

两个 Native parser 都以 whole-document 调用跨 Cangjie/C 边界。推荐 coarse lookup、bulk
traversal 和 native serialization；大量 per-node getter 会放大 FFI 固定成本。Native DOM
不会加速 `JsonNode.parse`，materialize 也不是默认 fast path。

Typed stream 使用 bulk tape：decode 为 parse/export/copy，encode 为 tape/copy。generated
codec 只看到 `JsonCodecReader/Writer` contract。

## Scanner 与 Float64 seam

`enableYJsonNative()` 安装 structural、bulk-number 和 Float64 backend；FloatOnly 与
NumericOnly 用于隔离部署/测量，模式互斥。安装、移除或切换不得与 decode 并发。

`YJ_JSON_ParseDouble` 接收已验证 number token，最多复制 256 bytes 到有界 stack buffer；
无效 bounds、格式或主动拒绝返回 NaN，由 Cangjie 调用方回退 portable parser。bridge 不
执行 Cangjie callback、I/O 或阻塞操作。

## 数字、重复 key 与错误

所有 backend 保留精确 `Int64`；overflow integer、decimal、exponent、`-0` 与
`PreserveLiteral` 保持 literal 语义。duplicate key 默认 LastWins，Reject 比较 decoded key
bytes，因此 `"a"` 和 `"\u0061"` 冲突。

Native message 和细分类不要求与 Pure 逐字一致；无效输入必须拒绝，并在可用时给出 byte
offset。资源预算的公开 error code 必须跨 backend 一致。limited parse 使用 additive
`*ParseWithLimits` C symbols；全零预算继续走旧 ABI。

## 安全与 qualification

Native semantic index 使用 per-document randomized seed，并始终执行 exact byte equality。
Linux entropy 顺序为 `getrandom`、`/dev/urandom`、process-specific fallback。随机化降低可
预测 collision 攻击，但不承诺开放寻址表不存在最坏情况。

Native release qualification 必须包含：malformed-input targeted tests、warning-clean
clang/gcc、ASan、UBSan、LSan、确定性 differential fuzz、allocation failure/lifecycle 和
symbol isolation。结果记录在具体 release evidence，不写入本页。

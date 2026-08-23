# Wirestack：仓颉跨平台 TLS/HTTPS 网络栈重写 PRD

**版本：** 2.0  
**状态：** 架构确认稿  
**日期：** 2026-08-22  
**目标平台：** Windows、Linux、macOS、Android、iOS、HarmonyOS/OpenHarmony  
**文档主题：** 在保留 `std.net` 作为默认网络实现依赖的前提下，重写跨平台 TLS、HTTPS 与 HTTP/2 栈

---

## 0. 文档控制

| 项目 | 内容 |
|---|---|
| 文档编号 | PRD-SECURE-NET-002 |
| 产品名称 | Wirestack |
| 主要包名 | `wirestack.tls`、`wirestack.http`；内部包统一使用 `wirestack.internal.*` |
| 兼容策略 | 绿色开发；不复制旧 TLS API、全局 provider、OpenSSL 配置或旧错误模型 |
| 依赖决策 | 官方默认实现依赖 `std.net`；TLS/HTTP 核心不依赖或暴露 `std.net` 公共类型 |
| 发布目标 | 六平台 HTTPS 客户端；桌面/服务器平台完整 TLS/HTTP 服务端；移动平台前台 listener 基础能力 |
| 代码仓库 | `lIlIIlIll/Wirestack`，独立绿地仓库 |

### 0.1 与上一版 PRD 的主要变化

1. 不再把“重写 `std.net` 公共层”设为项目先决条件。
2. 新增独立的内部 Transport SPI，TLS/HTTP 核心不直接导入 `std.net`。
3. 第一版通过 `StdNetTransport` 适配器复用仓颉运行时已有的 socket AIO 与协程调度。
4. 不使用现有 `std.net` 的域名解析和字符串地址连接路径；Resolver 与 Happy Eyeballs Connector 单独实现。
5. 仅当跨平台采纳门禁失败时，才对 `std.net` 或 runtime 做定向补强。
6. 禁止 Wirestack 直接调用 `CJ_MRT_Sock*` 私有 ABI，也不自行实现六套 epoll/kqueue/IOCP 网络循环。

### 0.2 仓库与命名边界

- Wirestack 是独立绿地仓库，不是 `cangjie_stdx` 的子目录，也不复用旧 `stdx.net.tls/http` 包名作为新 API 命名空间。
- 新公共包统一使用 `wirestack.*`；内部实现使用 `wirestack.internal.*`，具体物理目录与 `cjpm` target 在 M0-002 根据实际仓颉工具链冻结。
- `cangjie_stdx`、仓颉 SDK、`std.net` 与 runtime 源码是外部参考/上游依赖，不属于 Wirestack 工作树。
- 文档中出现的 `stdx.net.tls`、`stdx.net.http` 若用于描述“当前/旧实现”，仍保留原名；迁移目标与新实现一律称为 Wirestack。
- `std.net`/runtime 的修改必须在对应上游仓库单独提交，并由 Wirestack 的失败门禁证据解锁；Wirestack 仓库不得通过复制私有实现绕过上游接口。

---

## 1. 执行摘要

当前 `stdx.net.tls` 和 `stdx.net.http` 的主要问题不是“OpenSSL 不可用”，而是 OpenSSL 已经泄漏为应用的编译、链接、部署和运行时契约。用户为了使用 HTTPS，需要理解动态库路径、版本匹配、系统证书、静态/动态链接和平台差异。这不符合标准扩展库的交付目标。

另一方面，现有 `std.net` 已经具备有价值的运行时基础：它与仓颉任务调度器集成，能够通过 runtime socket AIO 挂起和恢复仓颉任务，并管理 native socket 生命周期。完全绕过它将迫使项目重新实现六个平台的非阻塞 I/O、事件循环、取消唤醒、句柄生命周期和调度器桥接，范围与风险都远大于 TLS/HTTP 重写本身。

因此，本项目确认以下总原则：

```text
官方默认数据路径：

HTTP/1.1 / HTTP/2
        ↓
跨平台 TLS Core
        ↓
内部 Transport SPI
        ↓
StdNetTransport
        ↓
std.net TcpSocket / TcpServerSocket
        ↓
CJThread socket AIO
        ↓
操作系统网络栈
```

但依赖必须被严格限制：

```text
可以依赖：
    std.net 的 TCP 连接、读写、监听和 runtime 调度能力

不能依赖：
    std.net 当前 DNS 策略
    TcpSocket(String, port) 隐式解析路径
    mutable socket timeout 作为请求总预算
    read() == 0 的完整关闭语义
    SocketException.message 作为控制流
    std.net 类型进入 TLS/HTTP 公共 API
```

最终产品应实现：

- 六平台一致的 TLS 1.2/1.3 客户端；
- Windows、Linux、macOS、HarmonyOS/OpenHarmony 完整 TLS 服务端；
- Android、iOS 前台应用场景的基础 TLS listener；
- HTTP/1.1 和 HTTP/2 客户端、服务端；
- 统一的绝对 Deadline、取消、结构化错误和可观测性；
- 平台系统信任、企业证书和不可导出私钥；
- 默认产物无系统 OpenSSL 依赖；
- 可替换 transport 和 TLS provider，但不泄漏 provider 类型。

---

## 2. 已确认架构决策

| 决策编号 | 决策 | 约束 |
|---|---|---|
| D-001 | `std.net` 是 v1 官方默认实现依赖 | 所有正式平台默认启用 `StdNetTransport` |
| D-002 | TLS/HTTP Core 不直接依赖 `std.net` | Core 只能依赖内部 Transport SPI |
| D-003 | 公共 API 不暴露 `TcpSocket`、`StreamingSocket`、`SocketException` | 防止现有语义成为长期兼容包袱 |
| D-004 | 不使用 `TcpSocket(String, port)` 和现有默认 DNS 连接路径 | Resolver 与 Connector 独立实现 |
| D-005 | 不直接调用 `CJ_MRT_Sock*` 私有 ABI | 若适配器能力不足，优先修改 `std.net`/runtime 的正式接口 |
| D-006 | 不为六个平台重写网络事件循环 | 继续复用 CJThread socket AIO |
| D-007 | OpenSSL 降为可选兼容 provider | 官方默认产物不搜索或依赖系统 OpenSSL |
| D-008 | 首版优先单一可移植 TLS Engine | 平台差异集中在 Trust、Key、Random 和诊断适配器 |
| D-009 | `std.net` 修改采用门禁驱动 | 只有采纳门禁失败的能力才进入上游改造范围 |
| D-010 | Deadline、取消、错误和 EOF 语义由新 Transport 层定义 | 不继承现有 socket API 的模糊语义 |

### 2.1 决策的直接结果

项目不再按以下方式推进：

```text
先重写 std.net
    ↓
再重写 TLS
    ↓
最后实现 HTTP
```

而采用：

```text
先验证 std.net 是否满足适配要求
    ↓
定义独立 Transport SPI
    ↓
实现 StdNetTransport
    ↓
并行实现 Resolver/Connector 与 TLS Core
    ↓
实现 HTTP/1.1、HTTP/2
    ↓
只对失败门禁做定向 runtime 改造
```

---

## 3. 背景与问题定义

### 3.1 OpenSSL 强依赖带来的问题

现有 TLS/HTTPS 路径使 OpenSSL 成为用户必须管理的外部条件，典型问题包括：

- 编译时需要 OpenSSL 头文件和库；
- 链接方式和链接顺序影响结果；
- 运行时动态库名称和搜索路径不确定；
- 系统 OpenSSL 版本、provider 和配置差异改变行为；
- Windows、Apple、Android、HarmonyOS 的平台信任和系统密钥能力不能自然复用；
- 应用嵌入其他宿主进程时可能加载多套 TLS 库；
- 安全更新责任不清晰；
- 同一仓颉二进制在不同机器上可能呈现不同 TLS 能力。

### 3.2 `std.net` 的价值

`std.net` 当前最值得复用的是：

- 与仓颉协程/任务调度器集成的 socket 等待；
- 非阻塞 socket 的运行时封装；
- native handle 生命周期和 close 协调；
- TCP client/server 的基础能力；
- 跨 Windows、Linux、Apple、Android、HarmonyOS 的统一入口；
- 一读一写的基本并发约束。

这些能力与 TLS 协议本身无关，但重新实现成本极高。

### 3.3 `std.net` 当前不能直接成为 TLS/HTTP 语义层的原因

现有公共接口存在以下不足：

- 域名解析失败通常缺少结构化原因；
- 默认连接路径只选取有限候选，缺少 Happy Eyeballs；
- socket timeout 是可变相对值，不等于端到端绝对 Deadline；
- 取消主要依赖关闭整个 socket；
- `read() == 0` 可能同时表示 peer EOF 与本地已关闭；
- 缺少显式读写半关闭；
- 读写主要使用完整 `Array<Byte>`，缺少 offset/length 和部分写语义；
- 错误类型不足以支持重试、连接池和协议诊断；
- 平台数据路径存在复制和行为差异。

本项目不要求这些问题全部先在 `std.net` 内解决，而是先通过适配层和门禁判断哪些是真正阻断项。

---

## 4. 产品目标

### G-001：解除 OpenSSL 强绑定

官方默认发布产物必须：

- 不要求用户安装 OpenSSL；
- 不依赖运行时搜索 `libssl`、`libcrypto` 或 OpenSSL DLL；
- 不暴露 OpenSSL 类型、错误码、cipher string 或 provider 对象；
- TLS provider 版本、构建参数和安全补丁级别可查询；
- 安全更新由 SDK/库发布流程承担。

### G-002：复用 `std.net` 的运行时能力

- 默认 TCP transport 基于 `std.net`；
- 不为每条连接创建系统线程；
- 不自行实现独立 epoll/kqueue/IOCP 循环；
- 不直接绑定 runtime 私有 ABI；
- 保留未来替换 transport 的能力。

### G-003：六平台一致可用

支持：

- Windows；
- Linux；
- macOS；
- Android；
- iOS；
- HarmonyOS/OpenHarmony。

HTTPS 客户端是所有平台的 P0。TLS/HTTP 服务端在桌面和服务器平台为 P0，在移动平台提供前台应用可用的基础能力。

### G-004：统一操作语义

DNS、TCP、Proxy、TLS、HTTP headers 和 HTTP body 共享：

- 单调时钟 Deadline；
- CancellationToken；
- 结构化错误；
- trace context；
- exactly-once completion。

### G-005：现代协议基线

P0 支持：

- TLS 1.2、TLS 1.3；
- SNI、ALPN；
- 系统信任和自定义 CA；
- mTLS；
- session resumption；
- HTTP/1.1；
- HTTP/2；
- HTTP CONNECT；
- 流式请求和响应；
- 客户端连接池；
- 服务端 graceful shutdown。

### G-006：默认安全

- 默认最低 TLS 1.2；
- 优先 TLS 1.3；
- 始终验证证书链和 reference identity；
- 普通生产 API 不提供 `TrustAll`；
- 所有 parser、队列、缓存和窗口有明确上限；
- 不自行临时实现密码原语。

### G-007：性能和资源可预测

- 稳态 I/O 尽量零分配；
- body 大小不导致全量内存缓冲；
- HTTP/2 多流共享连接；
- 所有缓存和 pending 队列有界；
- 取消能及时唤醒底层等待；
- 新 raw TCP 数据路径不显著劣化当前 `std.net` 性能。

---

## 5. 非目标

P0 不包含：

1. HTTP/3 和 QUIC；
2. DTLS；
3. TLS 1.0、TLS 1.1、SSL；
4. TLS renegotiation；
5. TLS compression；
6. 0-RTT；
7. 从零实现 AES、RSA、ECC、X25519 或完整 X.509 PKI；
8. PAC、WPAD 和浏览器级系统代理策略；
9. DoH、DoT 或完整 DNS 客户端；
10. WebSocket 扩展压缩；
11. 旧 `TlsKit`、旧 `TlsSocket`、旧错误类型的兼容层；
12. Wirestack 直接调用 runtime 私有 socket ABI；
13. 运行时自动寻找任意 TLS 动态库；
14. 在项目第一阶段重写整个 `std.net`。

---

## 6. 用户与核心场景

### 6.1 普通应用开发者

目标体验：

```cangjie
let client = HttpClient.default()
let response = client.get("https://example.com")
```

用户不需要理解 OpenSSL、动态库、CA 路径或 native callback。

### 6.2 协议库开发者

需要：

- 在现有 TCP 连接上升级 TLS；
- 实现 HTTP CONNECT 后的 TLS；
- 实现 SMTP/IMAP STARTTLS；
- 使用内存 transport 做确定性测试；
- 控制 Deadline、取消和背压；
- 获取协商版本、ALPN、证书链和关闭证据。

### 6.3 服务端开发者

需要：

- TCP listener；
- TLS server context；
- SNI 证书选择；
- mTLS；
- HTTP/1.1 与 HTTP/2；
- graceful shutdown；
- 资源和并发上限；
- 结构化访问日志和网络诊断。

### 6.4 移动应用开发者

需要：

- 系统 CA、企业证书和应用自定义 CA；
- Android Keystore、Apple Keychain、Harmony 系统密钥；
- Wi-Fi/蜂窝切换后的明确错误；
- 应用页面退出时快速取消请求；
- 不依赖系统内部 OpenSSL/BoringSSL。

---

## 7. 总体架构

```text
┌─────────────────────────────────────────────────┐
│                  Public HTTP API                │
│ HttpClient / HttpServer / Request / Response    │
├─────────────────────────────────────────────────┤
│ HTTP/2                     HTTP/1.1             │
│ HPACK / Flow Control       Strict Codec         │
├─────────────────────────────────────────────────┤
│ Pool / Proxy / Redirect / Retry / Body Stream   │
├─────────────────────────────────────────────────┤
│                  Public TLS API                 │
│ TlsClientContext / TlsServerContext             │
│ TlsConnection / TlsListener                     │
├─────────────────────────────────────────────────┤
│ Portable TLS Engine / Trust / Identity / Session│
├─────────────────────────────────────────────────┤
│             Internal Transport SPI              │
│ DuplexTransport / Listener / Resolver / Connector│
├───────────────────────────┬─────────────────────┤
│ StdNetTransport           │ Memory/Fault Transport│
├───────────────────────────┴─────────────────────┤
│ std.net TcpSocket / TcpServerSocket             │
├─────────────────────────────────────────────────┤
│ CJThread socket AIO / OS socket                 │
└─────────────────────────────────────────────────┘
```

### 7.1 模块边界

| 模块 | 职责 | 是否允许依赖 `std.net` |
|---|---|---:|
| `transport-core` | OperationContext、Deadline、取消、流接口、结构化错误 | 否 |
| `transport-stdnet` | `std.net` 适配器 | 是 |
| `resolver-system` | 系统 DNS 与结构化结果 | 可按平台实现，不依赖现有默认连接策略 |
| `connector` | Happy Eyeballs、多地址连接、Proxy route | 仅通过 Transport 工厂 |
| `tls-core` | TLS context、握手、record、session、关闭 | 否 |
| `trust-platform` | 系统证书链和 identity 验证 | 平台 API |
| `identity-platform` | 不可导出私钥签名 | 平台 API |
| `http1` | HTTP/1.1 parser、serializer、pool | 否 |
| `http2` | HTTP/2、HPACK、flow control | 否 |
| `http-api` | 对外 API | 否 |

### 7.2 依赖方向

必须保持：

```text
HTTP → TLS → Transport SPI ← StdNetTransport → std.net
```

禁止：

```text
HTTP → std.net
TLS → TcpSocket
Public API → StreamingSocket
Wirestack → CJ_MRT_Sock*
```

---

## 8. `std.net` 依赖契约

### 8.1 允许使用的能力

`StdNetTransport` 可以使用：

- 基于 IP 地址的 `TcpSocket` 连接；
- `TcpServerSocket` 监听和 accept；
- socket read/write；
- native close；
- local/remote address；
- 强类型且跨平台稳定的基础 socket option；
- runtime 已有的任务挂起和唤醒能力。

### 8.2 禁止使用的能力

正式实现不得使用：

- `TcpSocket(String, port)`；
- 现有“解析后只选择单个地址”的默认路径；
- socket mutable timeout 作为端到端操作预算；
- `SocketException.message` 字符串判断重试；
- `read() == 0` 同时表达 peer EOF、本地关闭和取消；
- raw socket option 作为 TLS/HTTP 正常配置机制；
- `StreamingSocket` 作为稳定公共 TLS 接口。

### 8.3 所有权

- `StdNetTransport` 独占持有底层 `TcpSocket`；
- transport 创建成功后，调用方不能直接操作底层 socket；
- TLS 包装 transport 后，所有权进一步转移给 `TlsConnection`；
- 关闭和 abort 必须幂等；
- native socket 最多 dispose 一次。

### 8.4 修改 `std.net` 的原则

仅当采纳门禁表明适配器无法正确实现 P0 语义时，才允许新增正式能力，例如：

- 可取消的 runtime wait；
- 明确的 `shutdownRead` / `shutdownWrite`；
- offset/length 或 span I/O；
- `writeSome`；
- 结构化 native error；
- 可靠区分 local close 与 peer EOF；
- Windows 更低复制的数据路径。

禁止为了便利而在 Wirestack 内复制 runtime socket 实现。

---

## 9. STD.NET 采纳门禁

在进入 TLS 正式实现前，必须在六个平台完成以下门禁。

### GATE-NET-01：关闭唤醒

测试：

- blocked read + 另一任务 close；
- blocked write + 另一任务 close；
- blocked connect + 另一任务 close/cancel；
- blocked accept + listener close。

验收：

- P99 唤醒延迟不超过 50 ms，或不超过一个 runtime 调度 tick，以更严格者为准；
- 无死锁、use-after-free、double-close；
- 操作 exactly once 完成；
- 结果能稳定映射为 Cancelled、DeadlineExceeded 或 Closed。

### GATE-NET-02：全双工与关闭竞态

模型：

```text
一个 reader
+
一个 writer
+
并发 graceful close / abort
```

验收：

- 百万级随机 interleaving 无死锁；
- 禁止同方向并发；
- 一读一写可以稳定并行；
- 关闭后所有 waiter 最终退出。

### GATE-NET-03：绝对 Deadline

验证外部 Deadline timer + abort 是否能限制：

- connect；
- repeated partial write；
- body idle read；
- accept。

验收：

- 总耗时不能因内部循环而重复获得完整 timeout；
- 超时偏差不超过 `max(20 ms, 配置值的 5%)`，平台调度抖动需单独记录。

### GATE-NET-04：EOF 与关闭证据

验证：

- peer FIN；
- peer RST；
- local close；
- local abort；
- cancel during read；
- close/read 同时发生。

验收：

- 适配器能够稳定区分 peer EOF 与本地主动终止；
- 若无法区分，必须进入 `std.net`/runtime 改造范围，不能在 TLS 层猜测。

### GATE-NET-05：大块数据和复制

测试 payload：

```text
1 KiB / 16 KiB / 64 KiB / 1 MiB / 100 MiB
```

记录：

- 吞吐；
- P50/P95/P99；
- 分配次数；
- copied bytes；
- Windows 与其他平台差异；
- TLS record 尺寸下的读取次数。

验收：

- 新适配器 raw TCP 吞吐不低于现有 `std.net` 基线的 95%；
- P95 延迟恶化不超过 10%；
- Windows 不得继续把单次有效读取固定限制在 4 KiB。

### GATE-NET-06：泄漏与长时间运行

至少执行：

```text
100,000 次 connect/cancel/close
100,000 次 peer reset
100,000 次 handshake failure transport cleanup
24 小时 idle/active 混合 soak
```

验收：

- socket handle、timer、waiter、native buffer 和 GC root 无单调增长；
- 无无法回收的 background task。

### GATE-NET-07：移动网络变化

Android、iOS、HarmonyOS 验证：

- Wi-Fi → 蜂窝；
- 蜂窝 → Wi-Fi；
- 飞行模式；
- 网络断开/恢复；
- 应用前后台切换；
- 系统休眠/恢复。

验收：

- 旧连接失败可诊断；
- 新连接可重新解析和选路；
- 取消不依赖应用保持前台；
- 不泄漏旧网络绑定。

### 9.1 门禁失败升级规则

| 失败项 | 首选修复位置 | 禁止方案 |
|---|---|---|
| close 不能唤醒等待 | runtime/`std.net` 增加正式 cancel/wakeup | Wirestack 自己轮询 sleep |
| 无法区分 local close 与 peer EOF | `std.net` 暴露结构化终态 | TLS 根据时间顺序猜测 |
| 无半关闭 | `std.net` 增加 typed shutdown | 直接调用私有 native handle |
| Windows 复制过重 | `std.net`/runtime 改进 buffer API | 在 TLS 层叠加更多大缓冲 |
| 错误无法分类 | `std.net` 增加稳定 error code | 解析异常 message 文本 |
| DNS 阻塞 carrier thread | 新 Resolver/runtime resolver API | 无界线程池 |

---

## 10. Transport SPI 功能需求

### 10.1 字节区间

**TR-BUF-001 · P0**

新增不复制区间类型：

```cangjie
public struct ByteSpan {
    let bytes: Array<Byte>
    let offset: Int64
    let length: Int64
}

public struct MutableByteSpan {
    let bytes: Array<Byte>
    let offset: Int64
    let length: Int64
}
```

要求：

- 构造时检查范围；
- 子区间不复制；
- native 调用结束后不得继续保存用户数组地址；
- 支持推进已消费/已写入范围。

**TR-BUF-002 · P1**

支持 vectored I/O；P0 正确性不得依赖该能力。

### 10.2 OperationContext

**TR-CTX-001 · P0**

所有可能等待的操作接受：

```cangjie
public struct OperationContext {
    let deadline: ?Deadline
    let cancellation: CancellationToken
    let trace: ?NetworkTraceContext
}
```

**TR-CTX-002 · P0**

Deadline 基于单调时钟；不得使用 wall clock。

**TR-CTX-003 · P0**

子操作只能继承或缩短父 Deadline，不能延长。

**TR-CTX-004 · P0**

操作开始前 token 已取消时，不产生网络副作用。

**TR-CTX-005 · P0**

取消 registration、timer 和 waiter 在终态后必须解除。

### 10.3 双工传输接口

**TR-STREAM-001 · P0**

```cangjie
public enum ReadResult {
    | Data(Int64)
    | EndOfStream
}

public interface DuplexTransport <: Resource {
    prop info: TransportInfo

    func readSome(
        destination: MutableByteSpan,
        context!: OperationContext
    ): ReadResult

    func writeSome(
        source: ByteSpan,
        context!: OperationContext
    ): Int64

    func shutdown(direction: ShutdownDirection): Unit
    func close(context!: OperationContext): Unit
    func abort(reason!: ?AbortReason): Unit
}
```

**TR-STREAM-002 · P0**

允许一个 read 与一个 write 并行；同方向并发返回 `ConcurrentOperation`。

**TR-STREAM-003 · P0**

`writeSome` 可以部分写入；提供通用 `writeAll` helper。

**TR-STREAM-004 · P0**

空 buffer：

- `readSome(empty)` 立即返回 `Data(0)`；
- `writeSome(empty)` 立即返回 `0`；
- EOF 只能由 `EndOfStream` 表达。

**TR-STREAM-005 · P0**

本地关闭、取消和 Deadline 不得被返回为 peer EOF。

**TR-STREAM-006 · P0**

`shutdown(Write)` 禁止新写入，但保留读取；`shutdown(Read)` 禁止新读取但不自动关闭写方向。

**TR-STREAM-007 · P0**

`close()` 尝试 graceful completion；`abort()` 立即终止且幂等。

### 10.4 Listener

**TR-LISTEN-001 · P0**

```cangjie
public interface TransportListener <: Resource {
    func accept(context!: OperationContext): DuplexTransport
    func close(): Unit
}
```

要求：

- accept 支持取消和 Deadline；
- listener close 唤醒 accept；
- backlog 有界；
- 结构化 accept 错误。

### 10.5 状态机

Transport 状态：

```text
Created
  → Connecting / Accepted
  → Open
  → ReadHalfClosed / WriteHalfClosed
  → Closing
  → Closed

任意非终态 → Aborted
任意非终态 → Failed
```

每个公开 operation 只能完成一次。

---

## 11. `StdNetTransport` 适配器需求

### 11.1 创建与连接

- 只接受已经解析的 `IPSocketAddress`；
- 不在构造器中执行 DNS；
- 一个适配器独占一个 `TcpSocket`；
- 连接成功后记录实际 local/remote endpoint；
- 连接 attempt 由上层 Connector 管理。

### 11.2 Deadline 与取消

P0 允许通过以下方式实现：

```text
OperationContext timer/cancel
        ↓
StdNetTransport.abort()
        ↓
TcpSocket.close()
        ↓
唤醒底层等待
```

但只有在 GATE-NET-01/03/04 全部通过时才能接受。

若 close 无法可靠唤醒某类操作，必须增加正式 runtime/std.net cancellation 原语。

### 11.3 错误映射

适配器内部可以读取 `std.net` 异常和 native code，但对上只返回稳定错误：

```text
Resolve
ConnectRefused
NetworkUnreachable
HostUnreachable
ConnectionReset
BrokenPipe
TimedOut
Cancelled
Closed
AddressInUse
PermissionDenied
ResourceExhausted
Unsupported
SystemFailure
```

禁止：

- 上层按异常 message 匹配；
- 把所有错误统一成 `IoError`；
- 丢失 operation phase。

### 11.4 缓冲

- P0 可以使用有界 staging buffer；
- buffer 应按连接复用；
- 不能按 body 大小扩展；
- 默认读 buffer 应容纳至少一个典型 TLS record；
- Windows 专用路径的额外复制必须计量并纳入 benchmark。

### 11.5 线程与所有者

- 不要求调用者固定 OS 线程；
- native handle 只能通过 `std.net` 正式接口操作；
- adapter 内不缓存私有 handle；
- finalizer 不直接执行网络 cleanup；
- 必要时向安全执行上下文投递 abort。

---

## 12. Resolver 与 Connector

### 12.1 Resolver

**DNS-001 · P0**

```cangjie
public interface Resolver {
    func resolve(
        host: HostName,
        service!: ?String,
        options!: ResolveOptions,
        context!: OperationContext
    ): ResolveResult
}
```

**DNS-002 · P0**

结果包含：

- 所有候选地址；
- address family；
- 规范化 host；
- resolver source；
- 可选 expiration；
- 结构化 diagnostics。

系统 API 不提供 TTL 时不得伪造。

**DNS-003 · P0**

错误类别：

```text
NameNotFound
NoData
TemporaryFailure
Timeout
Cancelled
InvalidName
UnsupportedFamily
SystemFailure
```

**DNS-004 · P0**

解析不得无限占用 scheduler carrier thread。允许：

- runtime-native async resolver；
- 平台异步 resolver；
- 有界 blocking resolver pool。

禁止无界线程池。

### 12.2 Happy Eyeballs Connector

**CONN-001 · P0**

实现 RFC 8305 风格的地址交错和错峰连接。

**CONN-002 · P0**

流程：

```text
Resolve A/AAAA
    ↓
生成交错候选
    ↓
启动第一尝试
    ↓
按 attemptDelay 启动后续尝试
    ↓
首个成功者胜出
    ↓
关闭所有落败连接
```

**CONN-003 · P0**

DNS 和全部连接尝试共享一个总 Deadline。

**CONN-004 · P0**

诊断记录：

- 每个候选地址；
- 开始时间；
- 完成时间；
- 失败类别；
- 胜出地址；
- 取消原因。

**CONN-005 · P0**

取消后不能留下后台连接；取消后才成功的 candidate 不得返回给调用者。

---

## 13. TLS 产品需求

### 13.1 Provider 边界

**TLS-PROV-001 · P0**

TLS provider 为实例，不是全局可变单例。

**TLS-PROV-002 · P0**

公共 API 不出现 native provider 类型。

**TLS-PROV-003 · P0**

官方默认 provider 在构建时确定，不在运行时自动 fallback。

**TLS-PROV-004 · P0**

发布 manifest 包含：

```text
providerId
providerVersion
buildFingerprint
cryptoBackend
trustBackend
supportedCapabilities
securityPatchLevel
```

### 13.2 Provider 选择门禁

候选 TLS Engine 必须具备：

- TLS 1.2、TLS 1.3 client/server；
- 外部字节流驱动；
- ALPN、SNI；
- session resumption；
- external signer；
- 外部 trust evaluation；
- close_notify；
- 交叉编译六平台；
- 稳定漏洞响应；
- fuzz 和互操作基础；
- 许可证可接受；
- 无系统 OpenSSL 强依赖。

具体 provider 选择在 M0 冻结，不进入公共 API。

### 13.3 Context

```text
TlsClientContext
TlsServerContext
```

要求：

- builder 构造；
- 构造后不可变；
- 可并发共享；
- context 创建时完成 capability、trust、identity、ALPN 和版本校验；
- 不把配置错误推迟到握手中途。

### 13.4 安全配置

公开安全档位：

```text
Compatible
Modern
StrictTls13
```

默认：

- 最低 TLS 1.2；
- 优先 TLS 1.3；
- 禁止 TLS compression、renegotiation、NULL/anonymous cipher；
- 关闭 0-RTT。

普通 API 不接受 OpenSSL cipher string。

### 13.5 Trust

支持：

```text
System
CustomRoots
SystemPlusCustomRoots
PinnedPublicKeys
```

要求：

- 自定义 CA 不自动关闭主机名验证；
- 使用 SAN 验证 reference identity；
- DNS 名称与 IP 地址分别验证；
- 不回退到 Common Name；
- SNI 名称与 reference identity 分别建模；
- 普通生产命名空间不提供 `TrustAll`。

测试专用不安全配置只能位于显式 testing 命名空间，并允许 release 构建禁用。

### 13.6 身份与私钥

```text
LocalIdentity {
    certificateChain
    privateKeyRef
}
```

`PrivateKeyRef` 支持：

- PKCS#8 可导出私钥；
- Windows 系统 key handle；
- Apple Keychain/SecKey；
- Android Keystore alias；
- Harmony 系统 key handle；
- external signer。

TLS Engine 不得强制导出平台私钥。

### 13.7 握手

```cangjie
let secure = tlsContext.handshake(
    transport,
    serverName: host,
    context: operationContext
)
```

握手结果包含：

- negotiated TLS version；
- cipher suite；
- ALPN；
- peer certificate chain；
- verified identity；
- session resumed；
- provider info。

握手失败、取消或超时必须 abort 底层 transport。

### 13.8 TLS 关闭

`close(context)`：

1. 停止接受新应用写入；
2. 发送 `close_notify`；
3. 在 Deadline 内处理必要的 peer close；
4. 关闭底层 transport；
5. 无论中间失败，最终释放资源。

`abort()`：

- 不尝试 graceful TLS close；
- 立即终止 transport；
- 唤醒所有等待。

peer TCP EOF 且未收到 `close_notify` 时必须保留 `PeerClosedWithoutCloseNotify` 证据。

### 13.9 Session

- 支持 TLS 1.2 session 和 TLS 1.3 ticket；
- session store 有界；
- 按 server identity、ALPN、trust context、client identity、provider 隔离；
- session 有过期时间；
- P0 关闭 0-RTT。

---

## 14. 平台适配策略

### 14.1 统一主路径

所有平台默认：

```text
std.net TCP
    +
统一可移植 TLS Engine
    +
平台 Trust/Key Adapter
```

首版不维护六套不同的 TLS 协议状态机。

### 14.2 平台矩阵

| 平台 | Transport | Trust | 不可导出私钥 | HTTPS Client | TLS/HTTP Server |
|---|---|---|---|---:|---:|
| Windows | `StdNetTransport` | 系统证书链 | 系统 key handle | P0 | P0 |
| Linux | `StdNetTransport` | 系统 CA bundle/dir | external signer/文件 key | P0 | P0 |
| macOS | `StdNetTransport` | 系统信任 | Keychain/SecKey | P0 | P0 |
| Android | `StdNetTransport` | 系统和应用 trust | Android Keystore | P0 | 前台基础能力 |
| iOS | `StdNetTransport` | 系统信任 | Keychain/SecKey | P0 | 前台基础能力 |
| HarmonyOS/OHOS | `StdNetTransport` | 系统信任 | 系统 key handle | P0 | P0 |

### 14.3 平台能力查询

运行时公开只读诊断：

```text
systemTrust
customRoots
hardwareKeys
clientCertificate
serverMode
tls12
tls13
http2
networkBinding
```

不支持能力必须在 context 创建时失败，不能静默忽略。

---

## 15. HTTP 产品需求

### 15.1 公共模型

核心类型：

```text
HttpClient
HttpServer
HttpRequest
HttpResponse
HttpHeaders
HttpMethod
HttpVersion
RequestBody
ResponseBody
HttpTrailer
```

Header：

- 大小写不敏感；
- 保留多值；
- 拒绝 CR/LF 注入；
- 有单行和总大小限制；
- 不以普通 `Map<String, String>` 作为唯一模型。

Body 类型区分：

```text
Empty
Bytes
String
File
ReplayableStreamFactory
OneShotStream
```

### 15.2 HTTP Client

请求路径：

```text
URL normalize
→ proxy route
→ DNS
→ Happy Eyeballs
→ optional CONNECT
→ TLS
→ ALPN
→ HTTP/2 or HTTP/1.1
```

全部阶段共享 request Deadline。

连接池 key 至少包含：

```text
scheme
origin host/port
proxy route
network binding
TLS context identity
trust policy identity
client identity
provider
ALPN policy
```

Response body 未消费或未显式关闭前，连接不得归还池。

### 15.3 重试

默认仅在以下条件同时满足时重试：

- 请求幂等或显式标记安全；
- body 可重放；
- 没有已提交给用户的响应；
- 未超出总 Deadline；
- retry policy 允许；
- 错误类别支持该重试。

禁止捕获通用 socket 异常后盲目重发。

### 15.4 重定向

检查：

- 最大次数；
- 跨 origin；
- Authorization、Cookie 等敏感 header；
- HTTPS → HTTP 降级；
- 301/302/303 方法变化；
- 307/308 body 重放性。

### 15.5 Proxy

P0：

- 显式 HTTP proxy；
- HTTPS CONNECT；
- proxy authentication hook；
- `NO_PROXY`；
- IPv4/IPv6 proxy 地址；
- proxy 与 origin 独立 DNS。

P1：系统代理和 PAC。

### 15.6 HTTP/1.1

P0 支持：

- Content-Length；
- chunked；
- trailers；
- 1xx；
- 100-continue；
- CONNECT；
- Upgrade；
- connection-close framing；
- keep-alive；
- client/server。

安全要求：

- 拒绝冲突 Content-Length；
- 拒绝含糊 Transfer-Encoding；
- 禁止 obs-fold；
- 防请求走私；
- parser 和 serializer 使用统一 framing 规则。

P0 不实现 HTTP/1.1 pipelining。

### 15.7 HTTP/2

P0 支持：

- ALPN `h2`；
- SETTINGS、HEADERS、DATA、CONTINUATION；
- WINDOW_UPDATE、RST_STREAM、GOAWAY、PING；
- HPACK；
- stream/connection flow control；
- client/server multiplexing。

要求：

- 每连接一个 reader loop；
- 一个有界 write scheduler；
- 每个 stream 不创建系统线程；
- stream 取消发送 RST_STREAM，不默认关闭整条连接；
- GOAWAY 后只对幂等且可重放请求做策略重试；
- frame、header table、pending writes 和 stream 数量全部有界。

### 15.8 HTTP Server

支持：

- 明文 HTTP/1.1；
- TLS HTTP/1.1；
- TLS HTTP/2；
- ALPN；
- SNI；
- header/body limits；
- idle timeout；
- per-client concurrency limit；
- graceful shutdown。

Graceful shutdown：

1. 停止 accept；
2. HTTP/2 发送 GOAWAY；
3. 不再接受新 request；
4. 等待进行中 request 到 Deadline；
5. abort 剩余连接。

---

## 16. 错误模型

### 16.1 NetworkError

```cangjie
public class NetworkException <: IOException {
    prop category: NetworkErrorCategory
    prop phase: NetworkPhase
    prop code: NetworkErrorCode
    prop retryability: Retryability
    prop nativeCode: ?Int64
    prop localEndpoint: ?SocketEndpoint
    prop remoteEndpoint: ?SocketEndpoint
    prop cause: ?Exception
}
```

Category：

```text
Resolve
Connect
Accept
Read
Write
Shutdown
Closed
Cancelled
DeadlineExceeded
Address
Option
ResourceExhausted
Unsupported
System
```

Phase：

```text
Dns
AddressSelection
TcpConnect
ProxyConnect
TlsHandshake
TlsRead
TlsWrite
HttpHeaders
HttpBody
PoolAcquire
ServerAccept
```

Retryability：

```text
Never
SafeBeforeWrite
SafeIfReplayable
Temporary
Unknown
```

### 16.2 TLS 错误

至少区分：

```text
ProtocolViolation
UnsupportedVersion
NoSharedCipher
NoSharedAlpn
CertificateUntrusted
IdentityMismatch
CertificateExpired
CertificateRevoked
ClientCertificateRequired
PrivateKeyFailure
HandshakeTimeout
HandshakeCancelled
PeerAlert
PeerClosedWithoutCloseNotify
InvalidRecord
BadMac
SessionFailure
ProviderFailure
UnsupportedCapability
```

### 16.3 HTTP 错误

至少区分：

```text
InvalidUrl
InvalidRequest
InvalidResponse
HeaderLimitExceeded
BodyLimitExceeded
InvalidFraming
ProtocolViolation
ProxyFailure
PoolExhausted
RedirectLimit
BodyNotReplayable
StreamReset
ConnectionGoAway
ServerOverloaded
```

HTTP 4xx/5xx 是正常收到的 HTTP 响应，不是 transport error。

---

## 17. 生命周期与并发不变量

1. 每个 native socket 最多 dispose 一次。
2. 每个 operation 最多完成一次。
3. operation 完成后不得再触发用户 callback。
4. TLS 包装成功后，调用者不得继续使用底层 transport。
5. 一个 transport 同时最多一个 read 和一个 write。
6. HTTP response body 完成前，连接不得归还连接池。
7. HTTP/2 stream 取消不影响其他 stream。
8. 所有 cancellation registration 和 timer 在终态后解除。
9. Happy Eyeballs 所有落败 candidate 都必须关闭。
10. provider callback 不得在持有内部全局锁时调用用户代码。
11. 用户异常不得跨越 C ABI。
12. finalizer 不直接执行 socket 或 TLS cleanup。
13. context 构造后不可变。
14. 所有队列、缓存、session store 和窗口有界。
15. close 和 abort 都必须幂等。

---

## 18. 安全需求

- 默认禁用 TLS 1.0/1.1；
- 默认验证证书链和 reference identity；
- 普通 API 不提供 `TrustAll`；
- TLS record、handshake、证书链、HTTP header、HTTP/2 frame 和 HPACK table 有明确上限；
- TLS/HTTP parser 持续 fuzz；
- 密码原语来自经过审计和持续维护的 provider；
- 私钥、traffic secret、session secret 不进入日志；
- key log 只在测试/debug 构建可用；
- 构建产物提供 SBOM、provider 版本和 build fingerprint；
- 稳定版发布前完成独立安全审查；
- 未修复 Critical/High 安全问题时禁止稳定发布。

---

## 19. 性能与资源需求

### 19.1 Transport

- 不采用每连接一个系统线程；
- 预热后普通 read/write 目标为零仓颉层临时分配；
- 新 raw TCP 吞吐不低于现有 `std.net` 基线的 95%；
- P95 延迟恶化不超过 10%；
- Windows P0 最多允许一次额外 copy，但不得固定 4 KiB 有效读取；
- 10,000 idle connection 不产生 10,000 OS 线程。

### 19.2 TLS

- 1 MiB 以上 bulk TLS 吞吐不低于现有 stdx/OpenSSL 基线的 90%；
- full handshake P50 不慢于基线 10%，P95 不慢于 20%；
- session-resumed handshake 单独 benchmark；
- body 大小不导致线性内存峰值；
- 每 idle TLS connection 的库层专属内存目标不超过 48 KiB，不含 OS socket buffer 和共享 context。

### 19.3 HTTP

- HTTP/1.1 keep-alive 小请求吞吐不低于当前 stdx 基线的 90%；
- HTTP/2 在 100 并发小请求下显著减少 TCP/TLS 连接数；
- stream flow control 不形成无界内存；
- 服务端支持 10,000 idle connections 的目标平台：Windows、Linux、macOS、HarmonyOS/OpenHarmony。

### 19.4 取消

本地可控测试中，取消 blackhole connect、blocked read、blocked write 和 pool wait 的 P99 响应时间目标不超过 50 ms。

---

## 20. 可观测性与诊断

提供默认关闭的结构化事件 sink：

```text
DnsStarted / DnsCompleted
ConnectAttemptStarted / ConnectAttemptCompleted
TcpConnected
ProxyTunnelEstablished
TlsHandshakeStarted / TlsHandshakeCompleted
HttpConnectionAcquired / HttpConnectionReleased
Http2StreamOpened / Http2StreamClosed
ConnectionClosed
```

事件不得默认包含：

- Authorization；
- Cookie；
- body；
- 私钥；
- session secret；
- 完整证书 DER。

诊断接口：

```cangjie
NetworkRuntime.info()
TlsRuntime.info()
```

示例：

```text
transportBackend: std-net
runtimeIoBackend: cjthread-aio
tlsProvider: portable-x
trustBackend: android-system
supportedTlsVersions: [1.2, 1.3]
httpVersions: [1.1, 2]
externalOpenSslDependency: false
buildFingerprint: ...
```

---

## 21. 测试与 CI

### 21.1 单元测试

覆盖：

- ByteSpan 边界；
- Deadline 计算；
- cancellation races；
- transport state；
- exactly-once completion；
- half-close；
- error mapping；
- pool key；
- body replayability；
- redirect header stripping。

### 21.2 确定性模型测试

使用：

- virtual clock；
- memory transport；
- scripted resolver；
- scripted connector；
- fake TLS engine；
- fault injector。

重点竞态：

```text
read + close
write + abort
connect success + cancel
handshake complete + timeout
HTTP/2 RST_STREAM + GOAWAY
response body close + pool return
provider callback + connection abort
```

### 21.3 协议测试

TLS：

- 正常和畸形 record；
- bad transcript；
- 错误证书链；
- SAN/wildcard 边界；
- session resumption；
- close_notify；
- truncated stream。

HTTP/1.1：

- CL 冲突；
- TE/CL 组合；
- chunked/trailer；
- 1xx；
- CONNECT；
- request smuggling corpus。

HTTP/2：

- HPACK vectors；
- flow control；
- invalid frame order；
- CONTINUATION；
- GOAWAY；
- RST_STREAM；
- table/window limit。

### 21.4 Fuzz Targets

```text
TLS record parser
TLS handshake parser
hostname verifier
certificate input adapter
HTTP/1.1 request/response parser
chunked decoder
HTTP/2 frame parser
HPACK decoder
URL authority parser
proxy parser
```

### 21.5 平台 CI

| 平台 | 编译 | 单测 | 集成 | 真机/原生 VM |
|---|---:|---:|---:|---:|
| Windows | 必须 | 必须 | 必须 | 必须 |
| Linux glibc | 必须 | 必须 | 必须 | 必须 |
| Linux musl | 必须 | 必须 | 必须 | 必须 |
| macOS | 必须 | 必须 | 必须 | 必须 |
| Android | 必须 | 必须 | 必须 | 必须 |
| iOS | 必须 | 必须 | 必须 | 必须 |
| HarmonyOS/OHOS | 必须 | 必须 | 必须 | 必须 |

仅交叉编译通过不视为平台支持完成。

---

## 22. Benchmark 计划

### 22.1 对比对象

- 当前 `std.net` raw TCP；
- 当前 `stdx.net.tls` OpenSSL；
- 当前 `stdx.net.http`；
- 新 `StdNetTransport`；
- 新 TLS；
- 新 HTTP/1.1；
- 新 HTTP/2。

外部实现仅作参考，不作为唯一验收标准。

### 22.2 场景

Payload：

```text
0 B / 1 KiB / 16 KiB / 64 KiB / 1 MiB / 100 MiB
```

Connection：

```text
新 TCP
keep-alive
TLS full handshake
TLS resumed handshake
HTTP/2 1/10/100 concurrent streams
```

Network：

```text
loopback
LAN
20 ms RTT
100 ms RTT
1% packet loss
IPv6 available
IPv6 blackhole
HTTP proxy
```

指标：

- requests/sec；
- bytes/sec；
- P50/P95/P99；
- allocations/op；
- copied bytes/op；
- peak RSS；
- idle connection memory；
- carrier thread 数；
- cancellation latency；
- DNS-to-connected；
- TLS handshake；
- pool hit ratio；
- HTTP/2 connection count。

---

## 23. 构建与交付

- 官方默认 TLS provider 在构建时确定；
- 禁止运行时猜测 OpenSSL 动态库名称；
- 禁止失败后自动 fallback 到另一套 TLS；
- 每个平台执行动态依赖扫描；
- 版本查询公开 transport runtime、TLS provider、target triple 和 feature flags；
- 依赖版本锁定；
- 产物生成 SBOM；
- 发布 artifact 签名；
- 安全更新有明确 SLA；
- 默认产物必须报告 `externalOpenSslDependency: false`。

---

## 24. 兼容与迁移

### 24.1 不进入新 API 的旧设计

```text
global TlsKit
setGlobalTlsKit / getGlobalTlsKit
普通 TrustAll
CustomVerify(chain) -> Bool
OpenSSL cipher string
SSL_CTX / SSL*
SocketException.message 控制流
socket mutable timeout 作为请求预算
StreamingSocket 作为公开 TLS 类型
```

### 24.2 共存策略

迁移期允许旧包和新包并存，但：

- 新 HTTP 不调用旧 TLS；
- 新 TLS 不调用旧 OpenSSL bridge；
- 旧 global provider 不影响新 client；
- 不实现旧类型适配器；
- 使用新的 major version 或独立命名空间。

### 24.3 迁移文档

提供：

- API mapping；
- timeout → Deadline；
- cancellation；
- custom CA；
- mTLS；
- streaming body；
- retry policy；
- error handling；
- 删除 OpenSSL 构建配置指南。

---

## 25. 实施里程碑

### M0：`std.net` 采纳验证与架构冻结

交付：

- 六平台 GATE-NET-01～07 报告；
- raw TCP baseline；
- DNS carrier-thread 验证；
- Windows copy profile；
- TLS provider 候选 PoC；
- 最低 OS/API 版本；
- Transport SPI API；
- threat model。

退出条件：

- 明确哪些需求可由适配器完成；
- 明确需要上游修改的最小集合；
- TLS provider 选择完成；
- 所有权、取消和 EOF 语义评审通过。

### M1：Transport Core 与 StdNetTransport

交付：

- ByteSpan；
- Deadline/Cancellation；
- DuplexTransport；
- Listener；
- StdNetTransport；
- typed error；
- MemoryTransport；
- fault injection。

退出条件：

- 生命周期不变量通过；
- raw TCP 性能通过；
- 六平台 close/cancel 门禁通过；
- 无 handle/waiter 泄漏。

### M2：Resolver 与 Connector

交付：

- SystemResolver；
- typed DNS error；
- Happy Eyeballs；
- multi-attempt diagnostics；
- proxy-ready route model。

退出条件：

- IPv4/IPv6 blackhole 测试通过；
- loser candidate 无泄漏；
- 总 Deadline 不随候选数量放大。

### M3：TLS Core 与桌面平台

交付：

- TLS 1.2/1.3 client/server；
- ALPN/SNI；
- system/custom trust；
- hostname verification；
- mTLS；
- session resumption；
- Linux/Windows/macOS adapters。

退出条件：

- 互操作、fuzz、安全向量通过；
- 无系统 OpenSSL 依赖；
- 性能门槛通过。

### M4：移动与 Harmony 平台

交付：

- Android trust/key；
- iOS trust/key；
- Harmony trust/key；
- 真机 CI；
- network change tests。

退出条件：

- 三平台 HTTPS client 完整通过；
- 系统 CA、自定义 CA、不可导出 key 通过；
- 前后台/切网无泄漏。

### M5：HTTP/1.1

交付：

- client/server；
- strict parser；
- streaming body；
- connection pool；
- proxy/CONNECT；
- redirect/retry；
- graceful shutdown。

退出条件：

- conformance、fuzz、smuggling tests 通过；
- body backpressure 正确；
- 性能门槛通过。

### M6：HTTP/2

交付：

- client/server；
- HPACK；
- flow control；
- multiplexing；
- stream cancellation；
- GOAWAY；
- pool integration。

退出条件：

- conformance 通过；
- 100-stream benchmark 通过；
- 所有 table/queue/window 有界。

### M7：稳定版硬化

交付：

- 独立安全审查；
- SBOM；
- API freeze；
- migration guide；
- 全平台 release artifact；
- soak/fuzz/performance 报告。

退出条件：

- 所有 P0 完成；
- 无未修复 High/Critical；
- 六平台 release gate 通过；
- 默认产物无 OpenSSL 强依赖。

---

## 26. 发布验收标准

稳定版必须同时满足：

1. 六平台 HTTPS client 真机或原生 VM 运行通过；
2. Windows、Linux、macOS、HarmonyOS/OHOS TLS/HTTP server 通过；
3. Android、iOS 前台 listener 基础测试通过；
4. 默认产物无系统 OpenSSL 运行依赖；
5. TLS 1.2/1.3 互操作通过；
6. HTTP/1.1、HTTP/2 conformance 通过；
7. Happy Eyeballs blackhole 测试通过；
8. DNS、connect、TLS、HTTP body 支持统一取消；
9. 所有 Deadline 使用单调绝对时间；
10. peer EOF、local close、RST、TLS truncation 可区分；
11. 一读一写并发契约通过；
12. 无每连接系统线程；
13. benchmark 达标；
14. fuzz 无未修复崩溃；
15. 安全审查无未修复 High/Critical；
16. SBOM 与 provider manifest 完整；
17. 文档不要求安装 OpenSSL；
18. 旧 global TLS provider 不影响新栈；
19. 所有资源集合有界；
20. 所有错误有稳定 category、phase 和 retryability；
21. Wirestack 未直接调用 `CJ_MRT_Sock*` 私有 ABI；
22. 所有 `std.net` 上游修改都有对应失败门禁和回归测试。

---

## 27. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| `std.net` close 不能可靠唤醒某平台等待 | 取消语义无法实现 | M0 门禁；定向增加 runtime cancellation API |
| `read() == 0` 无法区分 local/peer close | TLS 截断判断错误 | 增加正式结构化终态，不在 TLS 层猜测 |
| Windows staging copy 性能差 | HTTPS 吞吐下降 | 改进 `std.net` buffer API；建立 copied-bytes 指标 |
| DNS 解析阻塞 carrier thread | 高并发连接拖垮调度器 | 平台 async resolver 或有界 resolver pool |
| 可移植 TLS provider 跨平台能力不足 | 被迫多后端分叉 | M0 provider gate 验证 external signer/trust/cross-build |
| 平台信任结果不完全一致 | 跨平台行为差异 | 定义 System policy；返回验证证据；做平台矩阵测试 |
| HTTP parser 安全问题 | request smuggling | strict parser、fuzz、差分测试、独立审计 |
| 硬件私钥接口设计过晚 | 无法支持系统身份 | P0 定义 opaque `PrivateKeyRef` 和 external signer |
| 连接池 key 不完整 | 跨身份/信任错误复用 | 把 trust、client identity、provider、proxy 纳入 key |
| timeout 语义重新分散 | 总时限失控 | 所有层只接受 OperationContext/Deadline |
| provider 供应链漏洞 | 六平台同时受影响 | 固定版本、SBOM、快速安全更新和回滚 |
| Core 意外导入 `std.net` | 长期耦合 | 构建层依赖规则和架构测试 |

---

## 28. 待冻结决策

以下决策在 M0 结束前必须完成：

1. 可移植 TLS Engine 的具体选择；
2. CryptoProvider 的默认实现；
3. 六平台最低 OS/API 版本；
4. `ByteSpan` 是否进入 `std.io` 或仅为内部类型；
5. `std.net` 是否需要正式 per-operation cancellation ABI；
6. Windows direct/low-copy buffer 路径；
7. Linux system trust 搜索规则；
8. 移动平台 listener 的正式支持级别；
9. FIPS 是否进入 P1；
10. `wirestack.tls` / `wirestack.http` 的 major version 与更细粒度公共包拆分；
11. system proxy 是否提前到 P0；
12. cookie/decompression 是否拆为可选包；
13. 是否允许用户替换 Resolver；
14. TLS provider 插件是否进入公开扩展点；
15. TLCP 的阶段和 provider 归属。

---

## 29. API 草案

### 29.1 HTTPS Client

```cangjie
let tls = TlsClientContext.builder()
    .securityProfile(TlsSecurityProfile.Modern)
    .trust(TrustPolicy.system())
    .alpn(["h2", "http/1.1"])
    .build()

let client = HttpClient.builder()
    .tls(tls)
    .requestTimeout(Duration.second * 30)
    .build()

let context = OperationContext(
    deadline: Deadline.after(Duration.second * 10),
    cancellation: token
)

let response = client.send(
    HttpRequest.get("https://example.com/data"),
    context: context
)

try (body = response.body) {
    body.copyTo(output, context: context)
}
```

### 29.2 包装已有 TCP Transport

```cangjie
let transport = connector.connect(
    HostEndpoint("example.com", 443),
    context: context
)

let secure = tls.handshake(
    transport,
    serverName: "example.com",
    context: context
)
```

### 29.3 CONNECT 后升级 TLS

```cangjie
let proxyTransport = connector.connect(proxyEndpoint, context: context)
performConnect(proxyTransport, target, context)

let secure = tls.handshake(
    proxyTransport,
    serverName: target.host,
    context: context
)
```

### 29.4 HTTP Server

```cangjie
let serverTls = TlsServerContext.builder()
    .identity(serverIdentity)
    .alpn(["h2", "http/1.1"])
    .clientAuthentication(ClientAuthentication.Optional)
    .build()

let server = HttpServer.builder()
    .listen(endpoint)
    .tls(serverTls)
    .limits(serverLimits)
    .handler(handler)
    .build()

server.serve(context: context)
```

---

## 30. 最终立项结论

本项目不应在“完全依赖 `std.net`”与“完全绕过 `std.net`”之间二选一。

正式方案是：

```text
保留 std.net：
    作为官方默认 TCP 实现和 runtime 调度桥梁

隔离 std.net：
    不让其当前 DNS、timeout、EOF、错误和类型进入 TLS/HTTP Core

验证 std.net：
    通过六平台采纳门禁确认 close、取消、性能和生命周期

定向修改 std.net：
    只修复适配器无法正确实现的阻断能力

禁止旁路：
    Wirestack 不直接调用 runtime 私有 ABI，也不重写六套事件循环
```

因此，本 PRD 的项目边界是：

> 以 `std.net` 和 CJThread socket AIO 为默认网络底座，通过独立 Transport SPI 重写仓颉跨平台 TLS、HTTPS、HTTP/1.1 和 HTTP/2 语义；在不泄漏 `std.net` 现有公共语义的前提下，复用其运行时价值，并用门禁驱动最小化上游改造。

# 公开 API 导览

Wirestack 对应用开发者公开 `wirestack.net`、`wirestack.http` 和 `wirestack.tls`。`wirestack.internal.*`
是实现细节，consumer 不应导入。Linux 入门路径见
[getting-started-linux.md](../guides/getting-started-linux.md)。

最新生成的 HTML 会发布到
[`lIlIIlIll.github.io/Wirestack`](https://lIlIIlIll.github.io/Wirestack/)。Pages workflow
从 `main` 重新生成站点；HTML 不提交到仓库。

## 生成和校验 API 参考

仓库固定使用 `cjdoc 0.7.2`。版本不符、找不到可执行文件、Doc IR 不完整、存在
warning、schema 未知或覆盖率低于 100% 都会使门禁失败。命令会先建立只包含公开
源码的临时视图，分别校验每个公开包，再写入 JSON 和 Markdown 投影：

```bash
CJDOC_BIN=/path/to/cjdoc-0.7.2 scripts/check-docs --json
```

命令写入以下可提交产物：

```text
docs/api/generated/docs.json
docs/api/generated/api-surface.json
docs/api/generated/coverage.json
docs/api/generated/markdown/
```

需要本地预览 HTML 或准备 Pages staging 时加 `--html`；输出位于
`target/doc/html/index.html` 和 `target/doc/html/search-index.js`：

```bash
CJDOC_BIN=/path/to/cjdoc-0.7.2 scripts/check-docs --html --json
```

仓库级 `scripts/check` 也会调用文档门禁。长时间 profile 不会被文档检查隐式触发。

## `wirestack.http`

使用 `HttpClient` 和 `HttpServer` 处理 HTTP/1.1 与 HTTP/2。facade 在同一个
`OperationContext` 下管理路由、DNS、Happy Eyeballs、可选 CONNECT、TLS、ALPN、连接池
和 body 生命周期。

常用类型包括 `HttpClient`、`HttpServer`、`HttpRequest`、`HttpResponse`、
`HttpClientTlsConfig`、`HttpServerTlsConfig`、`HttpBodyStream`、`RequestBody`、
`ResponseBody`，以及 request/connection/stream cancellation handle。响应 body 必须
读到 EOF 或显式关闭，连接才能安全归还连接池。

详细流程见 [Linux HTTP 指南](../guides/http1-linux.md)。

`HttpClient.builder()` 可配置 `CookieJar`、`HttpConnector`、
`HttpConnectionPoolHook` 和 `Http2PushConfig`。显式 `Cookie` header 优先于 jar；
pool hook 的异常不改变请求或连接租约的结果。`HttpServiceHook` 通过 server builder
注册，失败时走服务端既有 handler-failure 路径。

`upgrade` 和 `connectWebSocket` 返回已移交的双向连接或普通拒绝响应。拒绝响应仍由
调用方消费或关闭。`connectWebSocket` 接受 `http`、`https` URL，通过 HTTP/1.1
Upgrade 或 HTTP/2 extended CONNECT 建立不带压缩的 `WebSocketConnection`。
HTTP/2 push 默认关闭；启用后通过父响应的 `pushes` 接收独立拥有 body 的
`HttpPushedResponse`。

`MultipartWriter` 和 `MultipartReader` 提供有界流式 multipart 编解码。
`FileHandler` 的无符号链接路径解析和原子无覆盖上传只在 Linux x86_64 GNU 目标提供。
接口用法、资源所有权和明确排除项见 [Linux HTTP 扩展指南](../guides/http-parity-linux.md)。

## `wirestack.net`

`wirestack.net` 使用 Wirestack 的 endpoint、span、结构化错误和 `OperationContext`，
不向 consumer 暴露 `std.net` descriptor 或异常。M8-001 定义共享生命周期与
capability 契约、`TcpStream` 和 datagram 接口。M8-002 在 Linux x86_64 glibc 上
实现了基于 `std.net` 的公共 `TcpListener` 与 `UdpSocket`。
M8-003 增加 `UnixListener`、`UnixStream` 与 capability-scoped `UnixDatagramSocket`。

M9-002 增加 Internet socket 的 typed options：factory 在 bind/connect 前应用 `options`，
listener 在发布 accepted TCP 前应用 `acceptedOptions`；TCP/UDP 提供 `configure`，
TCP/listener/UDP 提供 `getOption(SocketOptionName, context:)` 并返回内核生效的
`SocketOption`。值域、默认值、阶段限制、非事务失败语义和 enum/ABI 迁移见
[配置与查询 typed socket options](../guides/network-foundation-linux.md#配置与查询-typed-socket-options)。

`TcpListener.bind(endpoint, backlog:, options:, acceptedOptions:, context:)` 只接受已解析的
`SocketEndpoint`，不执行 DNS。`backlog` 默认为 128，有效范围是 1 至 65,535。
`localEndpoint` 返回实际绑定地址，包括内核分配的端口。listener 同时只接受一个
`accept`；重叠调用以 `ConcurrentOperation` 失败，不建立无界等待队列。一次
`accept` 的取消或 Deadline 只终止该操作，listener 保持可用。接受得到的
`TcpStream` 保留已解析的本地和远端 endpoint。流式 `read`/`write` 允许 partial
progress，`readExact`/`writeAll` 是显式完整传输 helper。

`UdpSocket.bind(endpoint, context:)` 同样只绑定已解析的 Internet endpoint。
`localEndpoint` 返回包含实际绑定地址的 `NetworkEndpoint.Internet`，`remoteEndpoint`
在 `connect` 成功前为 `None`。`connect` 选择 native peer 并安装接收端源地址过滤；
`send` 使用该 peer，未连接时以 `NotConnected` 失败；`sendTo` 不改变已选择的 peer。
一次 send-like 操作可以与一次 `receive` 重叠；同方向重叠和 `connect` 与活动 I/O
的竞态以 `ConcurrentOperation` 失败。成功发送必须返回完整报文长度。
发送上限是 65,507 字节，`receive` capacity 的有效范围是 1 至 65,507。
`DatagramReceiveResult` 拥有返回 payload，保留已解析的来源 endpoint。报文超过
capacity 时只保留前缀、丢弃该报文尾部并设置 `truncated`，下一条报文不受影响。

当前 `std.net` backend 不支持发送空 UDP 报文，因此
`capabilities.zeroLengthDatagramSend` 为 `false`。`send` 和 `sendTo` 对空 payload
在 native I/O 前返回结构化 `Unsupported`，socket 仍可复用。接收空 UDP 报文是独立
且必须支持的行为：`receive` 返回空 payload 和 `truncated == false`，不能把它当作
EOF。预取消或已过期的 context 在进入 UDP I/O 前失败时不关闭 socket；对已经活动的
UDP connect、send 或 receive 发出取消会由该操作取得 abortive close 所有权并关闭
socket。TCP `accept` 的活动取消不会采用这条 UDP 所有权规则。

SocketCapabilities reports public callable capabilities, not OS potential.
Internet UDP supports connectedDatagramSend; broadcast and multicast are false
because SocketOption still has no public application or membership operation.
M9-001 changes constructor defaults and actual UDP flags, not field layout,
method signatures or enum cases. Rebuild consumers; old binary compatibility
has not been tested. Explicit custom capability values remain caller-owned.

<!-- NETWORK_CAPABILITIES:BEGIN -->
<!-- capability-description: {"domain": "text-utf8-lf-v1", "sha256": "295c45e1ed5061925a6080b840b78643ed164c88b83f000ffdd3297325f95187"} -->

## 当前 Linux 公开网络能力

此表由 [linux-network-capabilities.json](../references/linux-network-capabilities.json) 生成。
`支持` 仅指所列公开入口和条件；OS/SDK 有同名能力不等于 Wirestack 已提供入口。
静态一致性不等于原生 PASS；原生证据必须另外核验 source、SDK、target 和安装产物。

| 对象 | 能力字段 | 支持 | 条件 / 失败边界 | 原生场景 |
|---|---|---|---|---|
| `TcpStream` | `nonBlocking` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpStream` | `closeOnExec` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpStream` | `halfClose` | 不支持 | 固定 SDK 无公开定向 shutdown；拒绝后保持原状态，其他读写仍可用。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpStream` | `broadcast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpStream` | `multicast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpStream` | `raw` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpStream` | `ancillaryData` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpStream` | `zeroLengthDatagramSend` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpStream` | `connectedDatagramSend` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpListener` | `nonBlocking` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpListener` | `closeOnExec` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpListener` | `halfClose` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpListener` | `broadcast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpListener` | `multicast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpListener` | `raw` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpListener` | `ancillaryData` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpListener` | `zeroLengthDatagramSend` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `TcpListener` | `connectedDatagramSend` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `UdpSocket` | `nonBlocking` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | internet-ipv4, internet-ipv6, capability-contract |
| `UdpSocket` | `closeOnExec` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | internet-ipv4, internet-ipv6, capability-contract |
| `UdpSocket` | `halfClose` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `UdpSocket` | `broadcast` | 支持 | IPv4 socket 可配置并查询 Broadcast；IPv6 socket 的能力值为 false，调用返回 Option/DatagramSend/Unsupported/Never。此项不代表 multicast membership。 | capability-contract, socket-options |
| `UdpSocket` | `multicast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | internet-ipv4, internet-ipv6, capability-contract |
| `UdpSocket` | `raw` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `UdpSocket` | `ancillaryData` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | internet-ipv4, internet-ipv6, capability-contract |
| `UdpSocket` | `zeroLengthDatagramSend` | 不支持 | 只禁止发送空 payload；接收空报文仍是成功而非 EOF。 | internet-ipv4, internet-ipv6, capability-contract |
| `UdpSocket` | `connectedDatagramSend` | 支持 | IPv4/IPv6 Internet peer 必须先 connect；未连接为 NotConnected，sendTo 不改接收过滤。 | internet-ipv4, internet-ipv6, capability-contract |
| `UnixStream` | `nonBlocking` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | unix-pathname, unix-abstract, capability-contract |
| `UnixStream` | `closeOnExec` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | unix-pathname, unix-abstract, capability-contract |
| `UnixStream` | `halfClose` | 不支持 | 固定 SDK 无公开定向 shutdown；拒绝后保持原状态，其他读写仍可用。 | unix-pathname, unix-abstract, capability-contract |
| `UnixStream` | `broadcast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | unix-pathname, unix-abstract, capability-contract |
| `UnixStream` | `multicast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | unix-pathname, unix-abstract, capability-contract |
| `UnixStream` | `raw` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixStream` | `ancillaryData` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixStream` | `zeroLengthDatagramSend` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixStream` | `connectedDatagramSend` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixListener` | `nonBlocking` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | unix-pathname, unix-abstract, capability-contract |
| `UnixListener` | `closeOnExec` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | unix-pathname, unix-abstract, capability-contract |
| `UnixListener` | `halfClose` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixListener` | `broadcast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | unix-pathname, unix-abstract, capability-contract |
| `UnixListener` | `multicast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | unix-pathname, unix-abstract, capability-contract |
| `UnixListener` | `raw` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixListener` | `ancillaryData` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixListener` | `zeroLengthDatagramSend` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixListener` | `connectedDatagramSend` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixDatagramSocket` | `nonBlocking` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | unix-pathname, unix-abstract, capability-contract |
| `UnixDatagramSocket` | `closeOnExec` | 支持 | 仅限 Linux x86_64 glibc 和已固定 SDK；公开 factory 创建的对象，操作结果仍是权威。 | unix-pathname, unix-abstract, capability-contract |
| `UnixDatagramSocket` | `halfClose` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixDatagramSocket` | `broadcast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | unix-pathname, unix-abstract, capability-contract |
| `UnixDatagramSocket` | `multicast` | 不支持 | 此对象的该能力不受支持；IPv4 UDP Broadcast 配置不适用于其他对象，multicast 选项也不代表 membership join/leave。 | unix-pathname, unix-abstract, capability-contract |
| `UnixDatagramSocket` | `raw` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixDatagramSocket` | `ancillaryData` | 不支持 | 该对象不提供这种公开操作；不存在一个会伪装成功的 callable stub。 | unix-pathname, unix-abstract, capability-contract |
| `UnixDatagramSocket` | `zeroLengthDatagramSend` | 不支持 | 只禁止发送空 payload；接收空报文仍是成功而非 EOF。 | unix-pathname, unix-abstract, capability-contract |
| `UnixDatagramSocket` | `connectedDatagramSend` | 不支持 | 先 connect 后 send 为 Unsupported；SDK 会重新解析 Unix 名称，不能保证原 peer identity；显式 sendTo 独立可用。 | unix-pathname, unix-abstract, capability-contract |

| 操作 / 地址形式 | 公开入口 | 支持条件或失败 | 原生场景 |
|---|---|---|---|
| TCP ipv4 connect/accept 与双向 I/O | `TcpStream.connect`, `TcpListener.bind`, `TcpListener.accept`, `TcpStream.read`, `TcpStream.readSome`, `TcpStream.readExact`, `TcpStream.write`, `TcpStream.writeSome`, `TcpStream.writeAll` | 支持；仅接受已解析 Internet endpoint；不做隐式 DNS；partial I/O 和 EOF 后反向写保持独立。 | internet-ipv4 |
| UDP ipv4 bind/connect/send/sendTo/receive | `UdpSocket.bind`, `UdpSocket.connect`, `UdpSocket.send`, `UdpSocket.sendTo`, `UdpSocket.receive` | 支持；非空发送最多 65,507 字节；receive capacity 1..65,507，保留 source/截断边界；可接收空报文。 | internet-ipv4 |
| TCP ipv6 connect/accept 与双向 I/O | `TcpStream.connect`, `TcpListener.bind`, `TcpListener.accept`, `TcpStream.read`, `TcpStream.readSome`, `TcpStream.readExact`, `TcpStream.write`, `TcpStream.writeSome`, `TcpStream.writeAll` | 支持；仅接受已解析 Internet endpoint；不做隐式 DNS；partial I/O 和 EOF 后反向写保持独立。 | internet-ipv6 |
| UDP ipv6 bind/connect/send/sendTo/receive | `UdpSocket.bind`, `UdpSocket.connect`, `UdpSocket.send`, `UdpSocket.sendTo`, `UdpSocket.receive` | 支持；非空发送最多 65,507 字节；receive capacity 1..65,507，保留 source/截断边界；可接收空报文。 | internet-ipv6 |
| Unix pathname | `UnixListener.bind`, `UnixListener.accept`, `UnixStream.connect`, `UnixStream.read`, `UnixStream.readSome`, `UnixStream.readExact`, `UnixStream.write`, `UnixStream.writeSome`, `UnixStream.writeAll` | 支持；pathname 文件由调用者拥有并 unlink；close 不删除节点；stream 的未命名 peer 保留 unnamed。 | unix-pathname |
| Unix outgoing abstract | `UnixListener.bind`, `UnixListener.accept`, `UnixStream.connect`, `UnixStream.read`, `UnixStream.readSome`, `UnixStream.readExact`, `UnixStream.write`, `UnixStream.writeSome`, `UnixStream.writeAll` | 支持；名称必须恰好 107 字节且为有效 UTF-8，可包含 NUL；不补零、不重写名称。 | unix-abstract |
| 短或非 UTF-8 outgoing abstract | `UnixListener.bind`, `UnixStream.connect` | 不支持；短名称或非 UTF-8 名称在 native socket 创建或 I/O 前被拒绝。 `Unsupported/UnixSocket/Unsupported/Never`。 | capability-contract |
| Unix pathname | `UnixDatagramSocket.bind`, `UnixDatagramSocket.connect`, `UnixDatagramSocket.sendTo`, `UnixDatagramSocket.receive` | 支持；pathname 文件由调用者拥有并 unlink；close 不删除节点；stream 的未命名 peer 保留 unnamed。 | unix-pathname |
| Unix outgoing abstract | `UnixDatagramSocket.bind`, `UnixDatagramSocket.connect`, `UnixDatagramSocket.sendTo`, `UnixDatagramSocket.receive` | 支持；名称必须恰好 107 字节且为有效 UTF-8，可包含 NUL；不补零、不重写名称。 | unix-abstract |
| 短或非 UTF-8 outgoing abstract | `UnixDatagramSocket.bind`, `UnixDatagramSocket.connect`, `UnixDatagramSocket.sendTo` | 不支持；短名称或非 UTF-8 名称在 native socket 创建或 I/O 前被拒绝。 `Unsupported/UnixSocket/Unsupported/Never`。 | capability-contract |
| 接收任意字节的 named abstract source | `UnixDatagramSocket.receive` | 支持；接收时以 native 地址实际长度保留 named abstract 字节，包括短名称和非 UTF-8；不能套用 outgoing 的 107 字节限制。 | unix-pathname, unix-abstract |
| 接收未绑定 datagram sender | `UnixDatagramSocket.receive` | 不支持；固定 SDK 消费报文后无法转换未绑定来源；保留失败和 cause，不伪造 unnamed，也不能恢复该报文。 `Read/DatagramReceive/SystemFailure/Unknown`。 | unix-pathname, unix-abstract |
| Raw Ipv4 open | `RawSocket.open`, `RawSocketDomain.Ipv4` | 不支持；未安装 raw adapter；在 native I/O 前稳定拒绝，与权限是否足够无关；不得尝试私有 ABI 或 raw syscall。 `Unsupported/RawSocket/Unsupported/Never`。 | capability-contract |
| Raw Ipv6 open | `RawSocket.open`, `RawSocketDomain.Ipv6` | 不支持；未安装 raw adapter；在 native I/O 前稳定拒绝，与权限是否足够无关；不得尝试私有 ABI 或 raw syscall。 `Unsupported/RawSocket/Unsupported/Never`。 | capability-contract |
| Raw Packet open | `RawSocket.open`, `RawSocketDomain.Packet` | 不支持；未安装 raw adapter；在 native I/O 前稳定拒绝，与权限是否足够无关；不得尝试私有 ABI 或 raw syscall。 `Unsupported/RawSocket/Unsupported/Never`。 | capability-contract |
| Raw Netlink open | `RawSocket.open`, `RawSocketDomain.Netlink` | 不支持；未安装 raw adapter；在 native I/O 前稳定拒绝，与权限是否足够无关；不得尝试私有 ABI 或 raw syscall。 `Unsupported/RawSocket/Unsupported/Never`。 | capability-contract |
| SocketOption 仅值描述 | `SocketOption` | 不支持；构造或保存值不会调用 setsockopt；尚无公开 application/query 入口；本任务不实现后续 M9-002。 无公开调用入口，不能虚构运行时 Unsupported 方法。 | capability-contract |
| UnsafeSocketOption 仅值描述 | `UnsafeSocketOption` | 不支持；构造或保存值不会调用 setsockopt；尚无公开 application/query 入口；本任务不实现后续 M9-002。 无公开调用入口，不能虚构运行时 Unsupported 方法。 | capability-contract |
| 幂等 close/abort 与终态 | `TcpStream.close`, `TcpStream.abort`, `TcpStream.isClosed`, `TcpStream.state` | 支持；首个终态 owner 保留；不把 EOF、本地 close、abort、cancel、deadline 合并；listener accept 的取消是 operation-local。 | internet-ipv4, internet-ipv6, capability-contract |
| 幂等 close/abort 与终态 | `TcpListener.close`, `TcpListener.abort`, `TcpListener.isClosed`, `TcpListener.state` | 支持；首个终态 owner 保留；不把 EOF、本地 close、abort、cancel、deadline 合并；listener accept 的取消是 operation-local。 | internet-ipv4, internet-ipv6, capability-contract |
| 幂等 close/abort 与终态 | `UdpSocket.close`, `UdpSocket.abort`, `UdpSocket.isClosed`, `UdpSocket.state` | 支持；首个终态 owner 保留；不把 EOF、本地 close、abort、cancel、deadline 合并；listener accept 的取消是 operation-local。 | internet-ipv4, internet-ipv6, capability-contract |
| 幂等 close/abort 与终态 | `UnixStream.close`, `UnixStream.abort`, `UnixStream.isClosed`, `UnixStream.state` | 支持；首个终态 owner 保留；不把 EOF、本地 close、abort、cancel、deadline 合并；listener accept 的取消是 operation-local。 | unix-pathname, unix-abstract, capability-contract |
| 幂等 close/abort 与终态 | `UnixListener.close`, `UnixListener.abort`, `UnixListener.isClosed`, `UnixListener.state` | 支持；首个终态 owner 保留；不把 EOF、本地 close、abort、cancel、deadline 合并；listener accept 的取消是 operation-local。 | unix-pathname, unix-abstract, capability-contract |
| 幂等 close/abort 与终态 | `UnixDatagramSocket.close`, `UnixDatagramSocket.abort`, `UnixDatagramSocket.isClosed`, `UnixDatagramSocket.state` | 支持；首个终态 owner 保留；不把 EOF、本地 close、abort、cancel、deadline 合并；listener accept 的取消是 operation-local。 | unix-pathname, unix-abstract, capability-contract |
| 显式 DNS query/lookup | `DnsClient.init`, `DnsClient.query`, `DnsClient.lookup`, `DnsClient.close`, `DnsClient.isClosed` | 支持；本次证据使用显式配置的本地 nameserver；有界 UDP 查询与响应解析，不声称所有部署环境的 system DNS 配置通过。 | dns-basic |
| 显式配置的 resolve/connect | `Resolver.init`, `Resolver.resolve`, `Resolver.connect`, `Resolver.close`, `Resolver.isClosed` | 支持；hosts 为配置快照；共用 caller OperationContext；连接测试使用受控 nameserver 和 TCP peer，不推断未执行的系统配置矩阵。 | dns-connect |
| 有界 DNS message parser | `DnsMessageParser.init`, `DnsMessageParser.parse` | 支持；受 DnsParserLimits 限制；完整报文成功，截断报文保留结构化 ResolveException；此条只声明 parser，不代表 DNS 网络可达。 | capability-contract |
| TCP typed 选项 | `TcpStream.connect`, `TcpStream.configure`, `TcpStream.getOption` | 支持；NoDelay、KeepAlive、ReceiveBuffer、SendBuffer 支持创建前及打开后配置；默认 NoDelay(true)、KeepAlive(false)，KeepAlive(true) 使用 45s/5s/5。 | socket-options, invalid-option-admission |
| listener 与 accepted-stream 选项 | `TcpListener.bind`, `TcpListener.accept`, `TcpListener.getOption` | 支持；listener 绑定前支持 reuse、缓冲与 IPv6-only；默认 ReuseAddress(true)。acceptedOptions 在暴露连接前应用 TCP 默认值和调用者覆盖，失败只关闭该连接。 | socket-options, invalid-option-admission |
| UDP typed 选项 | `UdpSocket.bind`, `UdpSocket.configure`, `UdpSocket.getOption` | 支持；绑定前仅 reuse、缓冲与 IPv6-only；打开后支持缓冲、IPv4 broadcast/TTL、IPv6 hop limit、组播 loopback/interface。IPv4 interface-index 查询不可靠，返回 Unsupported。 | socket-options, invalid-option-admission, active-send-control |
| IPv4 multicast interface-index 查询 | `UdpSocket.getOption` | 不支持；IPv4 IP_MULTICAST_IF 不能可靠还原 interface index；不回显请求值。IPv6 interface index 可查询。 `Option/DatagramSend/Unsupported/Never`。 | socket-options |
| HTTP 自定义 connector 配置 TCP | `wirestack.http.HttpClientBuilder.connector`, `TcpStream.connect`, `TcpStream.configure`, `TcpStream.getOption` | 支持；建立及配置 TCP 时传递同一个 OperationContext，再交给 HTTP；不增加 HTTP timeout owner。 | http-option-connector |

ENVIRONMENT_FAILURE, never a supported PASS or permanent capability=false; preserve NetworkErrorCode.PermissionDenied/nativeCode/cause when available.
Public SDK errors without a stable native code remain SystemFailure/Unknown with cause; never classify from message text.
NOT_RUN, never native PASS
[当前原生收据](../evidence/M9-002/native-options.json)记录实际 source/SDK/target；未运行或交叉编译不能转成支持。

<!-- NETWORK_CAPABILITIES:END -->

完整 native consumer 位于
[`examples/linux/m8_002/main.cj`](../../examples/linux/m8_002/main.cj)，对应 runner
是 [`tools/m8_002_native_sockets.py`](../../tools/m8_002_native_sockets.py)。
M8-002 资格确认使用新的
[`wirestack-linux-pre1-m8-002.json`](baselines/wirestack-linux-pre1-m8-002.json)
作为公开 API baseline；完整门禁与原生结果见 [M8-002 验收记录](../evidence/M8-002/README.md)。

Unix stream 的 connect、accept、partial/exact I/O、EOF、取消和关闭使用同一组
Wirestack-owned 类型。`UnixDatagramSocket` 支持显式 `sendTo`、owned receive 和
connected peer 接收过滤。SDK 的 Unix connected send 会重新解析地址，可能误投
替代 socket，因此 `connectedDatagramSend=false`，`send` 显式返回 `Unsupported`。
SDK 的空发送限制也适用于 Unix datagram。

Pathname 支持不包含自动 unlink。Outgoing abstract endpoint 只接受恰好 107 字节且
为有效 UTF-8 的名称；较短或非 UTF-8 名称被拒绝，不改变共享 `UnixEndpoint` 的
任意字节模型。Incoming named sender 保留实际字节；未绑定 datagram sender 的地址
转换受 SDK 限制，不能恢复为伪造的 unnamed 报文。Raw native I/O 仍为 BLOCKED。
具体边界见 [Unix 使用指南](../guides/network-foundation-linux.md#unix-domain-socket)、
[native consumer](../../examples/linux/m8_003/main.cj) 和
[M8-003 验收记录](../evidence/M8-003/README.md)。

M8-002 与 M8-003 分别增加 `SocketCapabilities.zeroLengthDatagramSend` 和
`connectedDatagramSend` 实例字段及对应命名参数。旧调用保留默认值，但 struct 布局
和构造函数 ABI 已改变，消费者必须重新编译。新 baseline 匹配不代表旧二进制兼容，
见 [M8-003 兼容性分类](../evidence/M8-003/api-compatibility.json)。

M8-004 增加 `DnsRecordType`、`DnsQuestion`、`DnsRecord`、`DnsMessageSummary`、
`DnsParserLimits`、`DnsMessageParser`、`DnsResolverConfig`、`DnsClient` 和 `Resolver`。
parser 保留记录顺序与原始 RDATA，验证已知名称压缩边界；支持 A、AAAA、CNAME、
SRV、TXT、MX、PTR 和 SOA，其余类型保留为 `Unknown(code)`。
`DnsClient.query` 使用 UDP 和有界 TCP 截断回退；`lookup` 只使用相关 answer 地址，
不把 authority/additional 中的 glue 当作结果。正负缓存受绝对 TTL 和条目上限限制。

`wirestack.net.Resolver` 实现共享 `wirestack.Resolver` 接口，并提供保留末尾根点的
String overload 和共享 DNS/TCP Deadline 的 `connect`。hosts 是构造时快照；
关闭 resolver 会关闭其拥有的 client，但不关闭已返回的 transport。具体配置、
search/ndots、所有权和原生验证见 [DNS 使用指南](../guides/network-foundation-linux.md#dns-解析与连接)。

M8-004 的 Linux 验收门禁已通过，源码候选与证据摘要由任务的 `evidence.json` 绑定。
M8-005 的 HTTP parity 与 M8-006 的 TLS context/hooks 均已完成 Linux 验收，包含
原生 provider、完整仓库、严格 HTML 文档与浏览器验证。源码候选和报告由各自的
`evidence.json` 绑定；这些结果不能替代 M8-007 的最终 artifact 与 soak 证据。

## `wirestack.tls`

`TlsClientContext` 和 `TlsServerContext` 是不可变、可并发共享的 Linux TLS 配置。每次成功
`build()` 都分配一个进程内唯一、非零的 `UInt64` `contextVersion`。该值不是持久 ID，
也不能跨进程比较。它只用于隔离当前进程的可恢复 session 和 ticket。

builder 保留不可变证书链，在 `build()` 时复制 PKCS#8 和公钥元数据。外部 signer service 保留为调用方
拥有的线程安全引用。关闭原始 `PrivateKeyRef` 会清零其中可导出的内容，但不会使已构建
context 失效。context 不公开 provider 或 native handle。

context store 的公开签名如下：

```cj
public class TlsClientContextStore
public init(initial: TlsClientContext)
public func snapshot(): TlsClientContext
public func replace(value: TlsClientContext): UInt64
public func handshake(
    transport: DuplexTransport,
    serverName: HostName,
    context!: OperationContext = OperationContext.background()
): TlsConnection
public func handshake(
    transport: DuplexTransport,
    referenceIdentity: ReferenceIdentity,
    serverName!: ?HostName = None<HostName>,
    context!: OperationContext = OperationContext.background()
): TlsConnection

public class TlsServerContextStore
public init(initial: TlsServerContext)
public func snapshot(): TlsServerContext
public func replace(value: TlsServerContext): UInt64
public func handshake(
    transport: DuplexTransport,
    context!: OperationContext = OperationContext.background()
): TlsConnection
```

`replace` 是原子替换，只改变之后加载 snapshot 的握手。已开始的握手和已返回的
`TlsConnection` 保留原 context。新版本的首次连接执行完整握手，后续连接只能恢复该版本
自己的 session。session key 还按 server identity、ALPN、trust、client identity、
provider 和 TLS security policy 分区。

`TlsListener` 拥有传入的 `TransportListener`。store-backed 构造在 transport accept
之后、TLS 握手之前读取一次 server context。`accept` 将同一个 `OperationContext` 用于
accept 和握手。关闭 `TlsListener` 会关闭其 listener，但不会关闭已经返回的 connection。

```cj
public init(listener: TransportListener, context: TlsServerContext)
public init(listener: TransportListener, contextStore: TlsServerContextStore)
public func accept(
    context!: OperationContext = OperationContext.background()
): TlsConnection
public func close(): Unit
public func isClosed(): Bool
```

外部私钥服务通过以下公开契约接入：

```cj
public interface ExternalSigner {
    func supportedAlgorithms(): Array<TlsSignatureAlgorithm>
    func sign(
        request: ExternalSignatureRequest,
        context: OperationContext
    ): Array<Byte>
}

public struct ExternalDecryptionRequest
public init(algorithm: String, ciphertext: Array<Byte>)
public let algorithm: String
public func ciphertextBytes(): Array<Byte>

public interface ExternalDecryptor {
    func decrypt(
        request: ExternalDecryptionRequest,
        context: OperationContext
    ): Array<Byte>
}

public static func externalSigner(
    referenceIdentity: String,
    subjectPublicKeyInfoDer: Array<Byte>,
    signer: ExternalSigner
): PrivateKeyRef

public static func systemHandle(
    platform: String,
    alias: String,
    subjectPublicKeyInfoDer: Array<Byte>,
    signer: ExternalSigner,
    hardwareBacked!: Bool = true
): PrivateKeyRef

public func withExternalDecryptor(
    decryptor: ExternalDecryptor
): TlsServerContextBuilder
```

`ExternalSigner` 和 `ExternalDecryptor` 收到握手调用方传入的同一个 `OperationContext`，
包括绝对 Deadline、cancellation token 和 trace。Wirestack 在调用用户代码前释放 engine
锁，返回后再取得锁并提交结果。该规则不表示 Wirestack 能抢占一个正在阻塞的同步回调；
回调实现必须检查 context 并及时返回。

`ExternalDecryptor` 只适用于 server context，而且 identity 必须使用兼容 RSA 证书的
external signer 或 system signer。支持的 RSA modulus 对应 1 至 1,024 字节的 raw
private-operation block。builder 在握手前拒绝 client role、缺失 provider capability、
PKCS#8 identity、非 RSA identity 和不匹配的证书公钥。请求的 `algorithm` 必须恰好为
`"RSA_RAW"`，ciphertext 必须是该 modulus 的完整 block，长度为 1 至 1,024 字节。返回
数组的长度必须与 ciphertext 完全相同。返回成功后数组所有权转给 Wirestack；
decryptor 不得保留、复用或修改它。Wirestack 在 native completion 的所有路径清零数组。
admission 使用 `TlsContextException.code` 的 `InvalidHook` 或 `UnsupportedCapability`，
并在适用时通过 `capability` 返回 `TlsCapability.ExternalDecryptor`。握手期 callback
取消、Deadline、用户异常和错误长度分别保留 typed TLS 失败，不依赖错误文本判断。

`KeyLogSink` 的签名如下：

```cj
public struct TlsKeyLogLine
public init(label: String, clientRandom: Array<Byte>, secret: Array<Byte>)
public let label: String
public func clientRandomBytes(): Array<Byte>
public func secretBytes(): Array<Byte>

public interface KeyLogSink {
    func emit(line: TlsKeyLogLine, context: OperationContext): Unit
}

public func withKeyLogSink(sink: KeyLogSink): TlsClientContextBuilder
public func withKeyLogSink(sink: KeyLogSink): TlsServerContextBuilder
```

`TlsKeyLogLine` 包含 TLS traffic secret。label 是 1 至 128 字节的 NSS token，只能包含
大写 ASCII 字母、数字和下划线。client random 恰好 32 字节，secret 是 1 至 64 字节。
构造器复制输入，getter 返回 owned copy。sink 必须复制需要保留的数据，并安全清零临时
secret。

`KeyLogSink` 只在显式 test-keylog provider build 中可用。生产 provider 在编译时排除
secret logging capability，context builder 会以 `TlsCapability.KeyLog` 拒绝配置。
测试 provider 必须使用独立的 native output directory，不能覆盖默认 release output。
release collector 同时检查 `test_only_key_log` 和 `key-log` capability，并拒绝打包。

完整且已通过 installed-consumer 编译的示例是
[`examples/linux/m8_006/native_tls.cj`](../../examples/linux/m8_006/native_tls.cj)。
它覆盖 context replacement、TLS 1.2/1.3 version-local resumption、external signer、
RSA raw decrypt 和 test-only key logging。对应的 13 个 release 场景与 5 个 keylog
场景见 [M8-006 资格记录](../evidence/M8-006/README.md)。

## 稳定性和所有权

[M8-007 inventory](baselines/wirestack-linux-pre1-m8-007.json) 记录最终候选的公开契约，共
324 个 declaration 和 114 个 resolved alias。
[M8-006 snapshot](baselines/wirestack-linux-pre1-m8-006.json)、
[M8-004 snapshot](baselines/wirestack-linux-pre1-m8-004.json)、
[M8-003 snapshot](baselines/wirestack-linux-pre1-m8-003.json)、
[M8-002 snapshot](baselines/wirestack-linux-pre1-m8-002.json)、
[M7-032 snapshot](baselines/wirestack-linux-pre1-m7-032.json) 和
[M7-026 snapshot](baselines/wirestack-linux-v0.json) 保留为历史证据，不是当前兼容性目标。
1.0 之前，Wirestack 不承诺实验性 API 的 source、API、ABI 或语义兼容。

- 包装 transport 会把它的使用权转交给 TLS connection；
- 握手创建或执行失败会 abort 已转交的 transport；
- `close` 和 `abort` 幂等；
- 一个 read 和一个 write 可以并行，同方向重叠会失败；
- 子任务可以缩短 deadline，但不能延长；
- custom roots 不会关闭 reference-identity 校验；
- HTTP 4xx/5xx 是 response，不是 transport exception。

校验当前 API inventory：

```sh
scripts/check-m7-032-public-api --json --inventory docs/api/baselines/wirestack-linux-pre1-m8-007.json
```

该 baseline 当前精确匹配，但它只证明 source inventory。它不证明二进制、未来版本或运行时
语义兼容。最终发布状态见 [M8-007 验收记录](../evidence/M8-007/README.md)。

M8-006 为 `TlsCapability` 增加 `ExternalDecryptor`、`KeyLog`，为 `TlsContextErrorCode`
增加 `InvalidHook`。旧的穷尽匹配需要补充分支；当前 Cangjie context 布局也有变化。
请重编译 consumer，不要混用旧二进制和新库。[兼容性报告](../evidence/M8-006/compatibility.json)
保留两个旧 client 在 baseline 上编译运行成功、在新增 enum 分支后编译失败的最小证明。

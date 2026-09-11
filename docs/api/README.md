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

## `wirestack.net`

`wirestack.net` 使用 Wirestack 的 endpoint、span、结构化错误和 `OperationContext`，
不向 consumer 暴露 `std.net` descriptor 或异常。M8-001 定义共享生命周期与
capability 契约、`TcpStream` 和 datagram 接口。M8-002 在 Linux x86_64 glibc 上
实现了基于 `std.net` 的公共 `TcpListener` 与 `UdpSocket`。
M8-003 增加 `UnixListener`、`UnixStream` 与 capability-scoped `UnixDatagramSocket`。

`TcpListener.bind(endpoint, backlog:, context:)` 只接受已解析的
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

`SocketCapabilities` 只提供 advisory 信息，具体操作结果才是权威。当前 Linux
listener、接受的 TCP stream 和 UDP socket 都报告 `nonBlocking` 与 `closeOnExec`。
Internet UDP 还报告 `broadcast`、`multicast` 与 `connectedDatagramSend`；
`halfClose`、`raw`、`ancillaryData` 和 `zeroLengthDatagramSend` 为 false。
`SocketOption` 仍只是类型化值，公共 API 尚无
option application 操作。

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

完整 DNS、HTTP parity、TLS context versioning 和最终发布证据仍属于 M8-004 至 M8-007。

## `wirestack.tls`

当 TLS 包裹调用方拥有的 `DuplexTransport` 时，使用 `TlsClientContext` 或
`TlsServerContext`。context 构建后不可变，也不会暴露 AWS-LC handle。信任策略、
reference identity、本地身份、外部签名和 transport 所有权都是独立的类型化契约。

`TlsRuntime.info()` 返回只读的 provider/build 诊断，展示构建期选择，不会运行时选择
或替换 provider。

## 稳定性和所有权

[M8-003 inventory](baselines/wirestack-linux-pre1-m8-003.json) 记录当前公开契约。
[M8-002 snapshot](baselines/wirestack-linux-pre1-m8-002.json)、
[M7-032 snapshot](baselines/wirestack-linux-pre1-m7-032.json) 和
[M7-026 snapshot](baselines/wirestack-linux-v0.json) 保留为历史证据，不是当前兼容性目标。
1.0 之前，Wirestack 不承诺实验性 API 的 source、API、ABI 或语义兼容。

- 包装 transport 会把它的使用权转交给 TLS connection；
- `close` 和 `abort` 幂等；
- 一个 read 和一个 write 可以并行，同方向重叠会失败；
- 子任务可以缩短 deadline，但不能延长；
- custom roots 不会关闭 reference-identity 校验；
- HTTP 4xx/5xx 是 response，不是 transport exception。

完整的 public-only 可运行 consumer 位于
[`examples/linux/m7_027`](../../examples/linux/m7_027/)。源码声明是精确签名参考。

校验当前 API inventory：

```sh
scripts/check-m7-032-public-api --json
```

该门禁校验公开所有权，并拒绝指向 internal package 的 alias。

# 使用 Linux 网络契约

`wirestack` 提供共享 Internet/Unix endpoint，`wirestack.net` 提供同步 socket 生命周期、
capability 和结构化错误。Linux backend 使用公开 `std.net` API，不暴露 SDK socket 或
native handle。M8-002 提供 `TcpListener`、`TcpStream` 和 `UdpSocket` 的 Internet
原生证据；M8-003 增加受 SDK 能力限制的 `UnixListener`、`UnixStream` 和
`UnixDatagramSocket`。M8-004 增加经过 Linux 验收的 DNS wire client 与 resolver policy；后续协议集成属于 M8-005 及后续任务。

## 连接已解析的 TCP endpoint

先按[Linux 入门指南](getting-started-linux.md)配置仓颉 SDK 和 Wirestack 依赖，
并在本机 `127.0.0.1:8080` 启动可接收字节的 TCP 服务。连接构造不做 DNS。

```cj
import wirestack.net.*
import wirestack as api

main(): Int64 {
    let address = api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])
    let endpoint = api.SocketEndpoint(address, 8080u16)
    let context = api.OperationContext(
        deadline: Some(api.Deadline.after(5 * Duration.second)))
    let stream = TcpStream.connect(endpoint, context: context)
    try {
        let payload = api.ByteSpan("hello".toArray())
        stream.writeAll(payload, context: context)
    } finally {
        stream.close()
    }
    0
}
```

成功时服务端收到 `hello`，客户端退出码为 0。连接拒绝时先检查服务是否监听上述
地址。连接和写入共享同一个单调绝对 Deadline，不为每一步重新设置相对超时。

`finally` 使用无参 `close()` 回收资源，不重复使用可能已经耗尽的读写预算。
需要限制等待关闭的时间时，显式调用 `close(context:)` 并处理取消或超时。

## 监听已解析的 TCP endpoint

使用 `TcpListener.bind(endpoint, backlog:, context:)` 绑定已解析的 IPv4 或 IPv6
`SocketEndpoint`。端口为 0 时，`localEndpoint` 返回内核实际分配的端口。
`backlog` 默认为 128，只接受 1 至 65,535。无效范围、预取消或已过期 context 都在
listener 创建前失败。

同一 listener 同时只允许一个 `accept`。第二个重叠调用返回结构化
`ConcurrentOperation`，不会进入等待队列。活动 `accept` 的取消或 Deadline 只结束
该次接受操作，listener 保持 `Listening`，之后仍可再次接受连接。这是
operation-local cancellation。`close` 和 `abort` 才会唤醒接受者并终止 listener，
且第一个取得 native close 所有权的操作决定保留 `Closed`、`Aborted` 或 `Failed`
终态。接受成功后返回 `TcpStream`，其 `localEndpoint` 和 `remoteEndpoint` 都是已解析
endpoint。

## 生命周期与能力边界

流式 `read`/`write` 可以部分完成；需要完整缓冲区时使用 `readExact`/`writeAll`。
`readExact` 在缓冲区填满前遇到 EOF 时抛出 `UnexpectedEof`，保留已捕获的本地和远端
endpoint；已有错误中的 endpoint、分类、phase、重试性、native code 与 cause 不被覆盖。
对端 FIN 不因此中止仍可写的 TCP 方向；`UnexpectedEof` 表示此次精确读取未完成，
不是连接重置。所有 socket 操作统一报告底层异常，并保留可用的 endpoint 和原始 cause。
未分类异常的错误码为 `SystemFailure`；连接使用 `TcpConnect`，读写分别使用
`TcpRead` 和 `TcpWrite`，`shutdown`、`close`、`abort` 使用 `TransportClose`。
底层关闭失败保留 `Failed`；中止已经占有底层关闭时，即使回收失败也保留 `Aborted`。
`close` 与 `abort` 幂等，EOF、取消、Deadline 和本地关闭保持不同结果。
成功的单方向 `shutdown` 分别显示 `ReadHalfClosed` 或 `WriteHalfClosed`；不支持的
shutdown 不改变状态。正常关闭为 `Closed`，主动中止为 `Aborted`，终止性 I/O
失败为 `Failed`。后续 `close`/`abort` 不覆盖已确定的终态。
预取消且未触及 socket 的操作不改变生命周期。即使操作已获准进入读写路径，
其预取消检查也不能把并发正常关闭的 `Closing` 或 `Closed` 改成 `Aborted`。
只有真正拥有底层首次关闭的中止（包括取消）才保留 `Aborted`。其他操作随后观察到
`Closed` 或调用者随后执行 `close`，都不把该中止改记为失败或正常关闭。
半关闭后，对已关闭方向的新非空读写请求返回结构化 `Closed` 错误，但另一方向仍可用，
socket 保留对应的半关闭状态，不因此转为 `Failed`。空 buffer 仍按无 I/O 操作完成。
两个方向均关闭后，若底层资源也已关闭则为 `Closed`；否则保持 `Closing`，
调用 `close` 释放资源。被唤醒的旧 I/O 不把正常关闭改记为 `Failed`。

`close(context:)` 对 `Closed`、`Aborted`、`Failed` 直接返回，不访问调用者的取消标记或
时钟。对仍需关闭的流，接管前检查取消和 Deadline；拒绝时不调用底层，也不改变状态。
关闭已经开始后，上下文约束调用方的等待时间，而不放弃资源回收。等待被取消或超时时
返回结构化错误，关闭仍会继续；实际完成后才记录 `Closed` 或 `Failed`。
底层正常关闭已经占有资源时，后到的 `abort` 不升级或打断该关闭，也不把 `Closing` 或
`Closed` 改成 `Aborted`。若中止先占有底层关闭，后到的正常关闭不覆盖 `Aborted`。

## 收发 UDP 报文

`UdpSocket.bind(endpoint, context:)` 实现 Internet datagram 的原生创建与绑定，
不执行 DNS。端口为 0 时，`localEndpoint` 返回包含实际绑定地址的
`NetworkEndpoint.Internet`；`remoteEndpoint` 在 `connect` 成功前为 `None`。
`connect` 选择一个已解析的 Internet peer，并在 native socket 上安装接收来源过滤。
之后 `send` 发送给该 peer，未连接时以 `NotConnected` 失败；`sendTo` 则不改变已选择
的 peer。

`send` 和 `sendTo` 把报文作为原子单元处理，成功时返回完整 payload 长度。当前
Linux `std.net` backend 接受的非空 payload 上限是 65,507 字节。空 payload 在 native
I/O 前以结构化 `Unsupported` 失败，`capabilities.zeroLengthDatagramSend` 为 false，
socket 保持可用。这个限制只影响发送。接收空 UDP 报文是已实现的必需行为，
`receive` 会返回空 payload 和 `truncated == false`，不能把它当作 EOF。

`receive(capacity, context:)` 的 capacity 范围是 1 至 65,507。结果拥有自己的 payload，
并保留已解析的 source endpoint。报文超过 capacity 时只保留前缀，丢弃该报文剩余字节，
并设置 `truncated`；下一次 `receive` 从下一条报文开始。一次 send-like 操作可以与一次
receive 重叠。同方向的第二个操作以及与活动 I/O 竞态的 `connect` 返回
`ConcurrentOperation`，不会形成无界队列。

```cj
func forwardOneDatagram(
    socket: UdpSocket,
    target: api.NetworkEndpoint,
    context: api.OperationContext
): Int64 {
    let received = socket.receive(65507, context: context)
    if (received.truncated) {
        throw IllegalStateException("refusing to forward a truncated datagram")
    }
    socket.sendTo(target, api.ByteSpan(received.payload), context: context)
}
```

预取消或已经到期的 context 在 UDP I/O admission 前失败，不改变 socket 的 `Open`
状态。Deadline 到期会终止该次等待，socket 仍可复用。取消已经活动的 UDP
`connect`、`send`、`sendTo` 或 `receive` 不同：该操作通过 abortive close 唤醒
`std.net`，因此关闭此 `UdpSocket` 并保留 `Aborted` 所有权。每个 socket 必须在
`finally` 中调用 `close()`；不要把活动 UDP 取消当成 listener accept 那样的局部取消。

## Unix-domain socket

`UnixListener.bind(endpoint, backlog:, context:)` 绑定命名 Unix endpoint；
`accept(context:)` 返回 `UnixStream`。也可以用 `UnixStream.connect(endpoint, context:)`
主动连接。读写、exact/all helper、EOF 后继续写、单读单写并发和终态所有权沿用 TCP
契约。一次活动 accept 的取消只终止该 waiter，listener 可继续接受连接；
活动 stream I/O 的取消会关闭 stream。

`UnixDatagramSocket.bind(endpoint, context:)` 提供显式 `sendTo` 和拥有独立 payload 的
`receive`，可以作为 `DatagramSocket` 传入上面的转发函数。报文上限和截断语义与 UDP
相同。`connect` 安装内核接收端 peer 过滤，但 **connected `send` 不可用**：
SDK 自己的 `send` 也会重新解析 Unix 地址。pathname 被替换后，原本针对旧 peer 的
报文可能误投新 socket。因此 `connectedDatagramSend` 为 false，`send` 显式返回
`Unsupported`；显式 `sendTo` 仍按调用者提供的目的地址发送，不改变接收过滤。

| 地址或操作 | 当前 Linux backend |
|---|---|
| Pathname bind/connect | 支持；close 不删除文件系统节点，调用方负责清理 |
| Outgoing abstract name | 仅支持恰好 107 字节且为有效 UTF-8 的名称；允许内嵌 NUL |
| 短或非 UTF-8 outgoing abstract name | `Unsupported`；不补零或改写名称 |
| Stream 的未命名 peer | 保留 `UnixEndpoint.unnamed()` |
| Datagram 的命名 sender | 保留实际来源字节，包括短名称和非 UTF-8 abstract bytes |
| Datagram 的未绑定 sender | SDK 消费报文后无法转换来源地址，操作失败；不伪造来源或恢复报文 |
| 空 datagram | 接收支持；发送为 `Unsupported`，socket 可继续使用 |

`api.UnixEndpoint.pathname`、`abstractName` 和 `unnamed` 是不同的值。pathname
拒绝 NUL 字节；abstract name 保留任意字节，包括 NUL。两类地址都由
`api.NetworkEndpoint` 承载，`api.NetworkException.localEndpoint` 与
`remoteEndpoint` 使用同一类型，不把 Unix 地址转换为有损字符串。
地址值的表示范围大于当前 SDK 的 native 支持范围。AF_PACKET、AF_NETLINK、
SOCK_SEQPACKET、ancillary data 和特权 raw I/O 不计为成功能力；
`RawSocket.open` 当前没有 native adapter，所有 modeled domain 均返回 `Unsupported`。
`RawSocket.open` 必须显式传入 `protocolValue`；IPv6 ICMP 使用
`RawSocketProtocol.icmpv6()`，不继承 IPv4 的默认协议。

捕获共享 `NetworkException` 后，可直接匹配 Unix peer，不需要解析错误字符串：

```cj
func unixPeer(error: api.NetworkException): ?api.UnixEndpoint {
    match (error.remoteEndpoint) {
        case Some(api.NetworkEndpoint.Unix(endpoint)) => Some(endpoint)
        case _ => None<api.UnixEndpoint>
    }
}
```

## DNS 解析与连接

`DnsClient` 使用 `DnsResolverConfig.nameservers` 中的已解析 endpoint 发送 UDP DNS 查询。
响应必须匹配服务器、transaction ID、question、class 和 type；合法截断响应在同一个
`OperationContext` 下改用 TCP。`query(name, recordType, context:)` 返回有界
`DnsMessageSummary`；`lookup(host, options:, context:)` 返回请求 family 的地址。
公开摘要构造器在复制数组前检查每个 section 的 16-bit 数量范围，并将 resource record
总数限制为 65,535。无效数量抛出 `IllegalArgumentException`。
没有配置 nameserver 时，地址查询使用已有的有界 system resolver；它不伪造 DNS TTL。
该路径把已经选定的 DNS 名称作为绝对名称交给系统，不再应用系统 search 后缀。
因此显式根点与手动展开的 search 候选在 system fallback 中仍保持原意。
`Any` 查询中，某个地址族的 `TemporaryFailure` 或 `SystemFailure` 不会丢弃另一个
地址族的可用地址。取消、超时和跨地址族 canonical name 冲突仍会终止查询。
关闭 `DnsClient` 导致排队或活跃请求终止时，错误为 `Cancelled`；关闭后发起的
新请求返回 `SystemFailure`。
DNS transport 错误保留已有的本地和远端 endpoint、native code 和 cause。
底层 receive 错误没有远端 endpoint 时，顶层 `ResolveException` 使用本次选择的 nameserver。
`SERVFAIL` 和 `REFUSED` 重试耗尽时，错误保留最后响应的 nameserver。
匹配但格式损坏的 UDP 响应、重复 TC 的 TCP 响应等协议错误也保留所选 nameserver 和 cause。
每次尝试按剩余总预算和尚未执行的服务器尝试次数分配子 Deadline，UDP 与对应的
TCP fallback 共用该子 Deadline。静默服务器不会独占全部预算。子 Deadline 不会延长
总 Deadline；活跃取消或总预算耗尽立即终止，不进入下一次尝试。

`Resolver` 将标准点分十进制 IPv4 字面量直接作为 `ResolverSource.Static` 返回，不应用 hosts/search/DNS；
仍检查取消和 Deadline。请求的 family 不匹配时返回 `NoData`，不会转为 DNS 查询。
system fallback 支持 253 字节的规范 DNS 名称；native 输入上限为 254 字节，
包含提交绝对名称时追加的根点。

`Resolver(config:, client:)` 在构造时读取 hosts 快照。精确 hosts 名称优先于 DNS；
DNS 候选按 `searchDomains` 和 `ndots` 排序。需要保留末尾根点时使用
`resolve(String, options:, context:)`，因为 `HostName` 已规范化并移除末尾点。
`DnsResolverConfig.fromSystem(path:)` 支持 Linux resolv.conf 的 nameserver、
search/domain 和 ndots；不实现完整 NSS 配置。配置路径必须是可信的本地普通文件。
IPv6 nameserver 的 zone 只接受 `UInt32` 数字 scope ID。`fromSystem` 忽略接口名称
和超出范围的 zone；直接构造 `DnsResolverConfig` 则抛出 `IllegalArgumentException`，
不会进入无效 endpoint 的重试。没有可用 nameserver 时，地址查询仍可使用有界 system resolver。
nameserver 的数字 zone 会去除前导零；scope ID 0 规范化为无 zone，
与 native receive 返回的 endpoint 身份保持一致。
hosts 快照同样忽略接口名称和超出 `UInt32` 范围的 zone，保留数字 zone 和无 zone 地址。

正缓存使用整个 CNAME 链最早的绝对过期时间。负缓存要求相关父域的 SOA，并受
SOA TTL、MINIMUM、已经过的 CNAME 寿命和 `maximumCacheTtl` 限制。零 TTL、
缺失或无关 SOA 不会成为可复用缓存。`cacheCapacity` 限制缓存条目数。

`Resolver.connect(host, port, options:, attemptDelay:, context:)` 复用 Happy Eyeballs，
DNS 和所有 TCP attempt 消耗同一个绝对 Deadline。返回 transport 归调用者所有；
关闭 resolver 不关闭已经返回的连接。resolver 拥有传入的可选 `DnsClient`，
关闭时也会关闭它；不要将该 client 当作独立共享资源。
`queryTimeout` 只限制 DNS 解析，不会额外缩短 TCP attempt 的调用者 Deadline。

可复现的本地 UDP/TCP DNS peer、取消、缓存和服务字节交换见
[原生 consumer](../../examples/linux/m8_004/native_dns.cj)、
[runner](../../tools/m8_004_native_dns.py) 和
[M8-004 记录](../evidence/M8-004/README.md)。这些证据不代表 DNSSEC 或加密 DNS 支持。

## Capability 与验证边界

`SocketCapabilities` 是 advisory 值，调用结果仍是权威。当前 Linux Internet/Unix
listener、stream 和 datagram socket 报告 `nonBlocking` 与 `closeOnExec`。
Internet UDP 还报告 `broadcast`、`multicast` 和 `connectedDatagramSend`；
Unix datagram 的 connected send 为 false。当前 backend 的 `halfClose`、`raw`、
`ancillaryData` 和 `zeroLengthDatagramSend` 均为 false。`SocketOption` 仍只是类型化值，
公共 API 尚无 option application 操作。

Internet 原生结果见 [M8-002 验收记录](../evidence/M8-002/README.md)，Unix 支持范围与
SDK 限制见 [M8-003 验收记录](../evidence/M8-003/README.md)。
Unix [consumer](../../examples/linux/m8_003/main.cj) 和
[runner](../../tools/m8_003_native_sockets.py) 使用独立 Python peer，验证字节、来源、
原生等待、背压超时、地址替换防护和活动进程中的 descriptor 清理。
当前公开契约见 [API 参考](../api/README.md) 与
[`wirestack-linux-pre1-m8-004.json`](../api/baselines/wirestack-linux-pre1-m8-004.json)。
M8-004 的十二条 Linux 验收命令均已通过。M8-005 至 M8-007 仍待执行；局部资格确认不等于最终 release 验证。

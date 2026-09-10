# 使用 Linux 网络契约

M8-001 在 `wirestack` 提供共享的 Internet/Unix endpoint，在 `wirestack.net` 提供
生命周期、capability 类型与复用 Transport SPI 的 `TcpStream`。它不暴露 SDK socket 或 native
handle。本页只覆盖这个任务；完整 TCP/UDP listener、Unix adapter、DNS 和协议集成
分别由后续 M8 任务验收。

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

`DatagramSocket` 冻结 Internet 与 Unix adapter 的同步操作接口；原生创建与绑定
由 M8-002/M8-003 实现。`connect` 选择已解析的 peer，`send`/`sendTo` 成功时必须
发送完整报文，不能把部分发送当成流式进度。`receive` 接收一条报文，容量范围为
1–65,507 字节；超出容量的部分丢弃并设置 `truncated`。零长度报文不是 EOF。
同一 socket 最多同时进行一次发送和一次接收，操作共享调用者的绝对 context。

下面的调用方代码可按该接口编译；本任务不把它记为原生 datagram I/O 验收：

```cj
func forwardOneDatagram(
    socket: DatagramSocket,
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

`api.UnixEndpoint.pathname`、`abstractName` 和 `unnamed` 是不同的值。pathname
拒绝 NUL 字节；abstract name 保留任意字节，包括 NUL。两类地址都由
`api.NetworkEndpoint` 承载，`api.NetworkException.localEndpoint` 与
`remoteEndpoint` 使用同一类型，不把 Unix 地址转换为有损字符串。
能构造地址不代表其 native adapter 已实现。M8-003 负责逐地址形式的原生执行证据。AF_PACKET、
AF_NETLINK、SOCK_SEQPACKET、ancillary data 以及没有 native adapter 的特权 raw I/O
不计为成功能力。
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

Socket option 值类型在 M8-001 定义，实际应用由 M8-002 提供。DNS wire parser、
身份验证和 resolver 策略属于 M8-004；HTTP parity 值、hooks 和协议集成属于
M8-005，均不纳入本任务的公共接口基线。

查看[当前任务证据](../evidence/M8-001/README.md)及[公共 API 参考](../api/README.md)。

# 使用 Linux 网络契约

`wirestack.net` 的 M8-001 契约提供 Wirestack-owned endpoint、生命周期与 capability
类型，以及复用现有 Transport SPI 的 `TcpStream`。它不暴露 SDK socket 或 native
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
        stream.close(context: context)
    }
    0
}
```

成功时服务端收到 `hello`，客户端退出码为 0。连接拒绝时先检查服务是否监听上述
地址。连接和写入共享同一个单调绝对 Deadline，不为每一步重新设置相对超时。

## 生命周期与能力边界

流式 `read`/`write` 可以部分完成；需要完整缓冲区时使用 `readExact`/`writeAll`。
`close` 与 `abort` 幂等，EOF、取消、Deadline 和本地关闭保持不同结果。

`DatagramSocket` 冻结 Internet 与 Unix adapter 的同步操作接口；原生创建与绑定
由 M8-002/M8-003 实现。`connect` 选择已解析的 peer，`send`/`sendTo` 成功时必须
发送完整报文，不能把部分发送当成流式进度。`receive` 接收一条报文，容量范围为
1–65,507 字节；超出容量的部分丢弃并设置 `truncated`。零长度报文不是 EOF。
同一 socket 最多同时进行一次发送和一次接收，操作共享调用者的绝对 context。

下面的调用方代码可按该接口编译；本任务不把它记为原生 datagram I/O 验收：

```cj
func forwardOneDatagram(
    socket: DatagramSocket,
    target: NetworkEndpoint,
    context: api.OperationContext
): Int64 {
    let received = socket.receive(65507, context: context)
    if (received.truncated) {
        throw IllegalStateException("refusing to forward a truncated datagram")
    }
    socket.sendTo(target, api.ByteSpan(received.payload), context: context)
}
```

`UnixEndpoint.pathname`、`abstractName` 和 `unnamed` 是不同的值。能构造地址不代表
其 native adapter 已实现。M8-003 负责逐地址形式的原生执行证据。AF_PACKET、
AF_NETLINK、SOCK_SEQPACKET、ancillary data 以及没有 native adapter 的特权 raw I/O
不计为成功能力。

Socket option 值类型在 M8-001 定义，实际应用由 M8-002 提供。DNS wire parser、
身份验证和 resolver 策略属于 M8-004；HTTP parity 值、hooks 和协议集成属于
M8-005，均不纳入本任务的公共接口基线。

查看[当前任务证据](../evidence/M8-001/README.md)及[公共 API 参考](../api/README.md)。

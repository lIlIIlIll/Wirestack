# Linux 网络底座指南

这份指南面向使用 `wirestack.net` 的 Linux x86_64、glibc 应用开发者。它只描述
M8-001 已冻结的公共契约；尚未完成的 native capability 不会被示例隐藏。

## 一个最小 TCP 操作

```cj
import std.time.Duration
import wirestack.net.*
import wirestack as api

main(): Int64 {
    let address = api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])
    let endpoint = api.SocketEndpoint(address, 8080u16)
    let context = api.OperationContext(
        deadline: Some(api.Deadline.after(5 * Duration.second)))
    let stream = TcpStream.connect(endpoint, context: context)
    try {
        let payload = api.ByteSpan(bytes: "hello".toArray())
        stream.writeAll(payload, context: context)
    } finally {
        stream.close(context: context)
    }
    0
}
```

`connect`、`accept`、`read`、`write`、`send` 和 `receive` 的 timeout/cancellation
都来自同一个 `OperationContext`。context 使用单调绝对 deadline；socket 不保存
相对超时。读写允许部分完成，需要完整 payload 时使用 `readExact`/`writeAll`。

## 生命周期和并发

- `close` 幂等，阻止新操作；取消只终止当前操作，不隐式关闭 socket。
- 一个 stream 最多同时有一个 reader 和一个 writer；同方向第二个操作返回稳定的
  `ConcurrentOperation`。
- committed I/O progress 优先返回；没有可提交进度时，deadline/cancellation 才
  成为结果。
- datagram 保持消息边界；超过 65,507 bytes 的 IPv4 payload 返回
  `MessageTooLarge`，接收结果明确给出 `truncated`。

## Unix、Raw 和 DNS 边界

`UnixEndpoint.pathname`、`UnixEndpoint.abstractName` 和 `UnixEndpoint.unnamed` 是
不同的值。当前 Linux adapter 已验证 pathname 与 abstract byte-name 的 stream/datagram
操作；unnamed bind、AF_PACKET、AF_NETLINK、SOCK_SEQPACKET、ancillary data 与特权 raw
I/O 仍是显式 capability 边界。未验证的 capability 不会被 query 结果伪装成成功。

`NetworkEndpoint` 构造不会做 DNS。M8-004 才会把 bounded wire parser、hosts/search/
ndots 策略、负缓存、UDP 截断到 TCP fallback 和 Happy Eyeballs 组合成完整 `Resolver`。

## HTTP parity facade

`wirestack.http.CookieJar`、`MultipartWriter` 和 `WebSocketFrame` 都是有界、拥有值的
公开类型。Cookie jar 可由 `HttpClientBuilder.cookieJar` 注入，并只在请求没有显式
`Cookie` 头时追加匹配值；响应中的 `Set-Cookie` 会在同一 client 内更新 jar。multipart
writer 通过 `body()` 生成可重放的 `RequestBody`，并限制 metadata、part 数和总字节数。
WebSocket frame codec 不启用压缩，控制帧必须是 final 且不超过 125 bytes。

HTTP/2 client 默认拒绝 server push；`DenyHttp2PushPolicy` 是显式的 provider-neutral
policy boundary。HTTP server 可用 `HttpServerBuilder.serviceHook` 在每个 H1/H2 请求前后
接入 `OperationContext`，hook 不拥有 socket、native handle 或 TLS provider。

## TLS context versioning and external hooks

`wirestack.tls.TlsClientContext` 和 `TlsServerContext` 是不可变快照。使用
`TlsClientContextStore` 或 `TlsServerContextStore` 替换配置时，只影响之后开始的
handshake；已经取得的快照和连接继续使用原来的 `version`。session/resumption key
也包含该版本，因此替换 trust、identity 或安全策略不会沿用旧的恢复状态。

`ExternalDecryptor` 和 `KeyLogSink` 是 provider-neutral 的显式回调契约。回调收到握手
使用的同一个 `OperationContext`，不能自行创建 deadline、取消源或全局状态。key-log sink
只用于明确启用的测试/调试路径；release provider 不会隐式输出密钥日志。AWS-LC 仍由
Linux 构建期 provider factory 选择，公共 facade 不依赖 provider-specific 类型。

## 验证和限制

```bash
scripts/check-task M8-001 --json
```

各 M8 任务的测试证明 API/架构边界、值上限和 fail-closed 错误。M8-006 的 TLS
context、session epoch 和 hook 证据通过 `scripts/check-task M8-006 --json` 生成。开发门禁
不运行 1 小时 SSE profile 或 86,400 秒 soak；最终 candidate 的完整 artifact 证据由
M8-007 重新生成。

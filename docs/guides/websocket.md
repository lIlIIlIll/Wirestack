# ws/wss WebSocket 接入与生命周期

适用平台：Linux x86_64 glibc。WebSocket 复用现有 HTTP/1.1 Upgrade、HTTP/2 extended CONNECT、Transport SPI 和编译期 TLS provider；不增加扩展、压缩、自动重连或应用消息重放。

## URL 与迁移

```cj
import wirestack.http.*

let socketUrl = WebSocketUrl.parse("wss://example.test:443/events?cursor=a%2Fb")
```

`HttpClient.connectWebSocket` 的 URL 参数已从 `HttpUrl` 改为 `WebSocketUrl`。旧调用必须将 `http`/`https` 改为 `ws`/`wss` 并更换解析入口；没有旧重载或隐式转换。普通 HTTP client 和 `HttpUrl.parse` 仍拒绝 `ws`/`wss`。

解析入口不执行 DNS 或 I/O，复用同一份 authority、IP、port 和 percent-escape 校验。采用 RFC 6455 的绝对 WebSocket URI 及 RFC 3986 ASCII target profile：

- 原始输入最多 8192 bytes；scheme 与 DNS host 大小写规范化。
- `ws` 默认 80，`wss` 默认 443；显式十进制 port 为 1–65535，并保留显式 port 语义。
- host 为 ASCII DNS name、严格四段 IPv4 或方括号 IPv6；拒绝 IPv6 zone identifier、裸 IPv6、userinfo 和空 host。
- 空 path 变为 `/`；query-only target 变为 `/?...`。path、query 和合法 `%HH` 保留，不解码、消除 dot segment 或把 escaped 分隔符改成结构。
- 拒绝 fragment、非 ASCII、控制字符、空格、反斜杠、损坏 escape，以及 target 中需要 escape 的裸 `"<>[]^`、反引号、`{|}`。先 percent-encode 非 ASCII 文本；URL credential 不替代显式认证配置。

IPv4/IPv6 literal 直接进入现有 connector，不经过 DNS-only `HostName`。`wss` 使用原始 origin 的 DNS/IP reference identity：DNS host 进入 SNI，IP literal 验证 IP SAN 且不发送 DNS SNI。`Host`/`:authority`、CONNECT target 和 TLS identity 都不能替换成 resolver 地址或 proxy host。proxy 认证只发往 proxy，不转发到 origin。

literal 路径发出 `DnsCompleted` / `NotExecuted` 事件，不发出 `DnsStarted`，也不调用 resolver。

## 拥有连接或拒绝响应

```cj
import wirestack as api
import wirestack.http.*

let stop = api.CancellationSource()
let context = OperationContext(
    deadline: Some(Deadline.after(600 * Duration.second)),
    cancellation: stop.token,
    timeoutPolicy: api.OperationTimeoutPolicy(
        responseHeaders: Some(5 * Duration.second),
        streamReadIdle: Some(45 * Duration.second)
    )
)
let client = HttpClient.builder().requestTimeout(600 * Duration.second).build()
try {
    match (client.connectWebSocket(
        WebSocketUrl.parse("ws://example.test/echo"),
        protocols: ["events"],
        webSocketLimits: WebSocketLimits(
            maximumFrameBytes: 64 * 1024,
            maximumMessageBytes: 256 * 1024,
            ioBufferBytes: 4096,
            closeTimeout: 2 * Duration.second
        ),
        context: context
    )) {
        case WebSocketConnectResult.Connected(socket) =>
            try {
                socket.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [1u8, 2u8]))
                let frame = socket.receive()
                let _ = frame.opcode
                socket.close(1000u16, "done")
            } finally { socket.close() }
        case WebSocketConnectResult.Rejected(response) =>
            response.close()
    }
} finally { client.close() }
```

该片段展示受控 echo 会话的所有权，不是完整业务消息循环；实际接收必须处理下节的所有 opcode。`Rejected` 是仍拥有 body 的普通 `HttpResponse`：消费到 EOF 或显式 `close`。握手校验失败、managed header 冲突、错误 accept key、未提议的 subprotocol 或异常断连都不移交连接。成功只移交一个独占 `WebSocketConnection`；关闭它不关闭共享 client。HTTP/2 会话终止只终止自己的 stream，不能连带关闭 sibling。

## 一个预算、一个 reader、一个 writer

握手的 canonical context 保留到会话结束：绝对 deadline、parent cancellation、stream-read-idle policy、request/attempt/connection IDs，以及 HTTP/2 stream ID。已经完成的 DNS/TCP/TLS/response-header stage cap 不成为会话的新 lifetime。client `requestTimeout` 仍能缩短总预算；长会话必须相应配置 client，而不是每次 frame 新建更晚的 deadline。

`send`、`receive` 和 `close(code, reason)` 的 context 只能进一步缩短绝对 deadline 或 active-read-idle limit，不能延长会话；parent cancellation 与显式 frame cancellation 同时有效。默认 frame context 不分配额外 token bridge。预取消或已过期且尚未执行 I/O 的调用不破坏会话；帧 I/O 开始后的失败终止会话，避免半帧被继续发送或读取。

每个方向只有一个 active operation 和一个 pending caller。第三个同方向 caller 得到 `WebSocketErrorCode.CapacityExceeded`，不发送 frame bytes，也不改变 session。应用应保持一个 reader loop、一个 writer loop，并使用自己的显式有界消息队列；慢 consumer 和 HTTP/2 flow-control 会阻塞 writer，不产生无限后台缓存。取消或绝对 deadline 能唤醒 active、pending 和 backpressure 等待。

协议要求的回复不受应用 writer 阻塞影响：自动 Pong 与被动的 Close 回复各自占用一个 reserved 单槽位，应用 writer 在取得 active slot 前让位给它们；显式 `close(code, reason)` 的 close frame 也有自己的 reserved 单槽位。因此即使应用的 send 正持有 writer、且已有 close 在等待，收到的 Ping 或 Close 仍能得到应答。`close(code, reason)` 会先占用 reader admission 再写 close frame：当同方向已有 active reader 和 pending reader 时，第三个 `close` 直接以 `CapacityExceeded` 失败，不写任何字节也不终止 session。

`receive` 返回一个 frame，不拼接整条消息：

- `Text`/`Binary` 开始消息，`Continuation` 继续；`finalFragment` 表示结束。应用累计数据必须同样有界。
- Ping 在返回前自动发送匹配 payload 的有界 Pong；Ping/Pong 仍返回给 reader。控制帧可穿插在消息 fragment 之间，但不能插入已经写到一半的 frame。
- Close 自动回复并结束 transport。空 Close payload 没有 status；非空 payload 前两个 bytes 是大端 close code，剩余最多 123 bytes 是已校验的 UTF-8 reason。正常主动关闭使用 `close(1000u16, "done")`。

graceful close 使用 session deadline、caller deadline 与 `closeTimeout` 的最短预算。parameterless `close()` 是幂等终止清理，不新建协议交换；若另一个操作已经开始 cleanup，它等待该 cleanup 完成。terminal completion 只发生一次，request/stream/transport ownership 在返回前释放。

## 心跳、liveness 与业务进展

Wirestack 不启动隐式 heartbeat。应用若需要 Ping，使用有界 payload、固定上限的 writer queue 和同一 canonical context；不能因收到 Pong、再次发送 Ping 或重连而延长旧会话 deadline。

stream-read-idle 检查 active transport read 的空闲，不证明应用消息取得进展。收到 Ping/Pong 或其他 bytes 只能证明对应层的活动，不能替代业务 no-progress watchdog。业务 watchdog、应用 ACK/cursor 和 heartbeat schedule 分开维护，并受同一个绝对 deadline 与 cancellation 限制；不要增加相互竞争的网络 timeout owner。

断线时可能存在已发送但未被应用确认的消息，也可能丢失未持久化的消息。Wirestack 不自动重连、重放或保证 exactly-once。显式重连必须由应用决定，并结合持久化 cursor/ACK、幂等键和有界重试策略处理丢失或重复；旧会话状态不能被静默复用。

## 可执行验收

[安装后 public-only consumer](../../examples/linux/m11_003/websocket.cj) 覆盖真实 H1/H2、fragment/Ping/Pong/Close、拒绝 body、literal/default port、TLS identity、proxy 认证隔离、slow consumer、cancel/close race 和 HTTP/2 sibling。[native runner](../../tools/m11_003_native_websocket.py) 创建受控服务器、严格检查所有场景 marker，并将证据绑定到实际归档的 source bytes。

native runner 按包名组件检查 consumer import：拒绝 `wirestack.internal`、`std.net` 及其成员或别名，不把类似包名中的子串当作私有 namespace。边界回归由 `python3 -m unittest tools.tests.test_m11_003_native_websocket -v` 执行。

native runner 保存 stdout/stderr 前，将完整 URL token（任意 `scheme://...`）替换为 `<redacted-url>`；不保留 scheme、userinfo、host、port、path、query 或 fragment。URL 脱敏先于日志落盘，且不依赖 URL 是否包含 `std.net`。

```bash
python3 tools/m11_003_native_websocket.py
./scripts/check-task M11-003
```

当前任务的执行结果见 [M11-003 evidence](../evidence/M11-003/README.md)。未提交工作区的执行证据不等同于已发布、已签名或已 qualification 的构件；不能据此宣称其他平台可用。

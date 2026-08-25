# Stream I/O

Stream API 把一个完整 JSON document 与 typed codec 连接起来。stream 由调用方创建和
关闭；yjson 会完成输出 flush，但不会替调用方关闭 `InputStream` 或 `OutputStream`。

## 最短入口

```cangjie
YJson.encodeToStreamWith(UserJson, user, output)
let decoded = YJson.decodeFromStreamWith(UserJson, input)
```

类型实现 `JsonCodecProvider` 时，也可以使用 `YJson.toStream` 和
`YJson.fromStream<T>`。读取和写出策略分别通过 `JsonReadConfig` 与 `JsonWriteConfig` 传入。

## Backend

| Backend | Package | Decode / encode 模式 |
| --- | --- | --- |
| `PureStreamBackend` | `yjson` | 增量读取、增量写出；默认 |
| `NativeCompactStreamBackend` | `yjson_native` | WholeDocument |
| `YyjsonStreamBackend` | `yjson_yyjson` | WholeDocument |

```cangjie
YJson.encodeToStreamWith(UserJson, user, output,
    backend: NativeCompactStreamBackend)
let user = YJson.decodeFromStreamWith(UserJson, input,
    backend: YyjsonStreamBackend)
```

Native backend 一次 parse/export 或 encode/copy 后通过 bulk tape 驱动同一个
`JsonCodec<T>`，不逐节点跨 FFI。选择 Native 后，失败会直接抛错，不会静默切回 Pure。

## Decode contract

- 每次调用读取一个完整 JSON document，并检查 trailing content。
- Pure backend 使用 4096-byte 内部缓冲；Native backend 先读取到 EOF。
- 这不是多文档 framing protocol，也不保证目标对象使用恒定内存。
- `YJsonByteArrayInputStream` 专用入口读取其全部剩余 bytes。
- 失败后不保证 stream 停在可恢复边界，不应继续把它当作下一条消息的起点。
- `maxBytes` 可能在一次 buffer refill 后才报告，因此底层 read-ahead 可超过限制，最多到
  当前 buffer read 的边界。

需要连续消息时，先由上层协议完成 framing，再把单条受限消息交给 yjson。

## Encode contract

`JsonWriteConfig.maxBytes = 0` 表示 unlimited。Native whole-document backend 在向调用方
stream 写入前检查最终大小；Pure backend 为保留增量路径，可能先写出前缀，再在
`finish()` 报告 `output_too_large`。任何失败后的输出都不是可继续追加的 JSON document。

直接管理 `JsonStreamDecodeSession` / `JsonStreamEncodeSession` 时必须 `close()`；encode
session 的 `finish()` 必须且只能成功调用一次。应用通常不需要直接使用 session。

Backend 选型与性能边界见 [Backend 使用指南](backends.md)和
[typed stream 测量](performance/results/2026-08-24-stream-backends.md)。

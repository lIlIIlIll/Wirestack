# Stream I/O

使用显式 codec 与 caller-owned stream：

```cangjie
YJson.encodeToStreamWith(UserJson, user, output)
let decoded = YJson.decodeFromStreamWith(UserJson, input)
```

可通过 `config: JsonWriteConfig(...)` 或 `config: JsonReadConfig(...)` 覆盖默认策略。yjson 会 flush 输出，但不会替调用方关闭 `InputStream` 或 `OutputStream`。

## 当前 decode 语义

- 通用 `InputStream` 使用 4096-byte 内部缓冲读取并解析一个完整 JSON document。
- 当前 API 不是多文档 framing protocol，也不是恒定内存的增量 parser；typed decode 仍可能为目标对象分配完整结果。
- `YJsonByteArrayInputStream` 的专用入口会读取其全部剩余 bytes。
- parser 会检查 JSON 结束与 trailing content，不应把同一个 stream 当作连续 JSON 消息队列。
- decode 抛错或资源超限后，不保证 stream 位于可恢复边界；调用方不应依赖继续复用。

`maxBytes` 在 stream read 后检查，因此底层 stream 最多可能已多提供一个当前 4096-byte buffer 的数据，才报告 `document_too_large`。这不改变接受语义，但会影响协议层的 read-ahead 设计。

需要 framed transport 时，应由上层协议先切分一条完整消息，再把受限的 bytes 或 stream 交给 yjson。

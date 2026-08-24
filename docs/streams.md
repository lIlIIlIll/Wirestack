# Stream I/O

使用显式 codec 与 caller-owned stream：

```cangjie
YJson.encodeToStreamWith(UserJson, user, output)
let decoded = YJson.decodeFromStreamWith(UserJson, input)
```

provider 类型还可使用 `YJson.toStream` / `YJson.fromStream<T>`。可通过
`config: JsonWriteConfig(...)` 或 `config: JsonReadConfig(...)` 覆盖默认策略。yjson 会
flush 输出，但不会替调用方关闭 `InputStream` 或 `OutputStream`。

## 选择 backend

```cangjie
// 默认：portable incremental
YJson.encodeToStreamWith(UserJson, user, output)

// 依赖对应 optional package 后显式选择 whole-document Native backend
YJson.encodeToStreamWith(UserJson, user, output,
    backend: NativeCompactStreamBackend)
let decoded = YJson.decodeFromStreamWith(UserJson, input,
    backend: YyjsonStreamBackend)
```

| backend | package | decode | encode | `name()` |
| --- | --- | --- | --- | --- |
| `PureStreamBackend` | `yjson` | Incremental | Incremental | `pure-incremental` |
| `NativeCompactStreamBackend` | `yjson_native` | WholeDocument | WholeDocument | `custom-native` |
| `YyjsonStreamBackend` | `yjson_yyjson` | WholeDocument | WholeDocument | `yyjson-direct` |

所有 backend 使用同一个 `JsonCodec<T>` 和 backend-neutral
`JsonCodecReader` / `JsonCodecWriter` contract。Native backend 以 shared bulk tape
跨越 ABI：decode 是一次 parse、一次 tape export 和一次 bulk copy；encode 是一次 tape
encode 和一次 bulk copy，不执行 per-node FFI。选择 Native 后失败会直接抛错，不会静默
切换到 Pure。

Native encode 对所有 `JsonWriteConfig` 保持与 Pure 相同的 bytes，包括 compact/pretty、
newline、indent、separator space 与 HTML-safe escaping。

## 当前 decode 语义

- 默认 Pure backend 使用 4096-byte 内部缓冲增量读取一个完整 JSON document。
- Native backend 先读取到 EOF，再构建 Native DOM 并导出 matching-version tape。
- 当前 API 不是多文档 framing protocol，也不是恒定内存的增量 parser；typed decode 仍可能为目标对象分配完整结果。
- `YJsonByteArrayInputStream` 的专用入口会读取其全部剩余 bytes。
- parser 会检查 JSON 结束与 trailing content，不应把同一个 stream 当作连续 JSON 消息队列。
- decode 抛错或资源超限后，不保证 stream 位于可恢复边界；调用方不应依赖继续复用。

`maxBytes` 在 stream read 后检查，因此底层 stream 最多可能已多提供一个当前 4096-byte buffer 的数据，才报告 `document_too_large`。这不改变接受语义，但会影响协议层的 read-ahead 设计。

写出侧 `JsonWriteConfig.maxBytes` 同样以 `0` 表示 unlimited。whole-document Native
backend 在向调用方 stream 写任何 bytes 前检查最终大小；Pure backend 为保持增量 fast
path，可能在 `finish()` 报告 `output_too_large` 前已经提交前缀。无论哪种 backend，失败
后的输出都不是可继续追加的 JSON document。

`JsonStreamDecodeSession` / `JsonStreamEncodeSession` 是 backend implementer contract。
应用通常使用 `YJson` 入口；若直接管理 session，必须调用 `close()`，encode 必须且只能
成功调用一次 `finish()`。session close 是幂等的，但 close 后不得再取得 reader/writer。

需要 framed transport 时，应由上层协议先切分一条完整消息，再把受限的 bytes 或 stream 交给 yjson。

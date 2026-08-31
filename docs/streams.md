# Stream I/O

`YJson` 对 `InputStream` 和 `OutputStream` 提供与 String/bytes 相同的 typed 入口。
stream 由调用方创建和关闭；yjson 不关闭 caller-owned stream。

```cangjie
let decoded = YJson.fromJson<User>(input)
YJson.writeJson(decoded, output)
```

显式 codec 仍使用相同方法名：

```cangjie
let value = YJson.fromJson(input, codec: UserJson)
YJson.writeJson(value, output, codec: UserJson)
```

## 文档边界

一次调用读取一个完整 JSON document，并检查 trailing content。它不是 NDJSON、多文档或
length-prefixed framing protocol。解析失败后不保证 stream 停在可恢复边界；上层协议必须先
处理 framing，再把单个 document 交给 yjson。

读取端增量补充窗口，不先把普通 stream 全部读取到 EOF。写出端直接提交编码片段。内部每次
调用创建自己的 reader/writer 状态；public API 不暴露 reusable session。

## 预算和失败

读取选项通过 `options:` 传入：

```cangjie
let value = YJson.fromJson<User>(
    input,
    options: JsonReadOptions(maxInputBytes: 8 * 1024 * 1024)
)
```

写出选项同样通过 `options:` 传入：

```cangjie
YJson.writeJson(
    value,
    output,
    options: JsonWriteOptions(maxOutputBytes: 8 * 1024 * 1024)
)
```

`output_too_large`、codec 失败或 I/O 异常可能发生在前缀已经写出之后。失败后的 output
不是有效完整 document，不应继续追加。完整预算语义见[资源限制](resource-limits.md)。

## 显式 Native/yyjson I/O

普通 stream API 没有 backend 参数。需要 whole-document Native/yyjson 行为时，显式依赖
对应 package，并通过 `NativeBackends.customNative` 或 `YyjsonBackends.yyjson` 调用同名
`fromJson`、`writeJson` 方法。其 `metadata()` 明确报告
`JsonStreamBufferingMode.WholeDocument`。详见 [Backend 使用指南](backends.md)。


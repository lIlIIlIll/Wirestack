# Stream I/O

`YJson` 可以直接从 `InputStream` 读取目标类型，并向 `OutputStream` 写出 JSON。
流由调用方创建和关闭，yjson 不关闭传入的流。

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

一次调用读取一个完整 JSON 文档，并检查尾部是否还有非空白内容。NDJSON、多文档和带长度前缀
的协议必须先划分消息，再把单个 JSON 文档交给 yjson。解析失败后，流的位置不保证落在
下一条消息的起点。

读取端按需补充缓冲区，无需先读到 EOF 再开始解析；写出端直接提交编码后的片段。每次调用
创建独立的 reader 或 writer，公共 API 不提供可复用的会话。

## 并发边界

一次调用期间，同一个流必须由单一任务独占。`YJson.fromJson` 和 `writeJson`，包括后端的
同名方法，都不会在内部并发访问流。

多个任务共享同一个 `InputStream` 或 `OutputStream` 时，调用方必须串行化所有访问。
yjson 不为流加锁，也不会在调用后复位流的位置。不同任务使用不同流实例时没有这项限制。

## 限制输入和输出大小

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

报出 `output_too_large`、codec 错误或 I/O 异常时，流中可能已经写入部分内容。
写出失败后不要继续追加，这些内容不能当作完整 JSON 文档使用。各项限制见[资源限制](resource-limits.md)。

## 显式 Native/yyjson I/O

普通流 API 没有后端参数。需要 Native 或 yyjson 整篇缓冲的 I/O 时，添加对应包的依赖，
并通过 `NativeBackends.customNative` 或 `YyjsonBackends.yyjson` 调用同名
`fromJson`、`writeJson` 方法。其 `metadata()` 返回
`JsonStreamBufferingMode.WholeDocument`。详见 [Backend 使用指南](backends.md)。


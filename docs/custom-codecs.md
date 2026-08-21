# 自定义 Codec

无法或不适合使用 `@JsonCodec` 时，实现 `JsonDirectCodec<T>`。它直接读写 token，不要求先构建 `JsonNode`：

```cangjie
class UserId {
    let value: Int64
    init(value: Int64) { this.value = value }
}

class UserIdCodec <: JsonDirectCodec<UserId> {
    public func write(
        value: UserId,
        writer: JsonDirectWriter,
        context: JsonEncodeContext
    ): Unit {
        let _ = context
        writer.writeInt64(value.value)
    }

    public func read(
        reader: JsonDirectReader,
        context: JsonDecodeContext
    ): UserId {
        let _ = context
        UserId(reader.readInt64())
    }
}

let UserIdJson: JsonDirectCodec<UserId> = UserIdCodec()

extend UserId <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(UserIdJson)
    }
}
```

完成 provider 后可以使用 `YJson.toJson(UserId(7))`、`YJson.fromJson<UserId>("7")`，也可以把值插入 `@Json`。如果只在一个 generated 字段上使用该 codec，可改用 `@JsonUsing[UserIdJson]`，无需为类型提供全局 provider。

组合 codec 可通过 `YJson.optionCodec`、`arrayCodec`、`arrayListCodec` 与 `hashMapCodec` 构造。`YJson.fastDecoder(codec)` 要求 codec 提供 fast-reader contract；普通 `JsonDirectCodec<T>` 始终可以使用 `decodeStringWith`、`decodeBytesWith` 和 stream 入口，但不应假定具有 fast decode 实现。

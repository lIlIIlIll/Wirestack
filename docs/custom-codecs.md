# 自定义 Codec

不能使用 `@JsonCodec`，或 wire format 需要专门逻辑时，实现 `JsonCodec<T>`。custom codec
直接读写语义 token，不需要先构建 `JsonNode`。

## 最小实现

```cangjie
class UserId {
    let value: Int64
    init(value: Int64) { this.value = value }
}

class UserIdCodec <: JsonCodec<UserId> {
    public func write(value: UserId, writer: JsonCodecWriter,
        context: JsonEncodeContext): Unit {
        let _ = context
        writer.writeInt64(value.value)
    }

    public func read(reader: JsonCodecReader,
        context: JsonDecodeContext): UserId {
        let _ = context
        UserId(reader.readInt64())
    }
}

let UserIdJson: JsonCodec<UserId> = UserIdCodec()
```

显式使用：

```cangjie
let text = YJson.encodeStringWith(UserIdJson, UserId(7))
let id = YJson.decodeStringWith(UserIdJson, text)
```

## 让类型支持最短入口

实现 `JsonCodecProvider` 后，可以使用 `YJson.toJson/fromJson<T>`，也可以把值插入
`@Json`：

```cangjie
extend UserId <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(UserIdJson)
    }
}
```

如果 codec 只用于一个 generated 字段，使用 `@JsonUsing[UserIdJson]` 即可，不必为类型
提供全局 provider。

## Contract

- 只依赖 `JsonCodecReader` / `JsonCodecWriter`；不要向下转型到 direct reader/writer。
- 使用 `JsonDecodeContext` / `JsonEncodeContext` 传递深度和配置语义。
- 普通 codec 始终可使用 String、bytes 和 stream 显式入口。
- `YJson.fastDecoder(codec)` 只适用于提供 fast-reader contract 的 codec；否则产生
  `codec_contract`。
- `YJson.optionCodec`、`arrayCodec`、`arrayListCodec` 和 `hashMapCodec` 可组合已有 codec。

遵守 backend-neutral contract 后，同一 codec 可以由默认 Pure stream 或显式 Native
whole-document backend 驱动。

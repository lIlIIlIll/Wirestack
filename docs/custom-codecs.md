# 自定义 Codec

不能使用 `@JsonCodec`，或 wire format 需要专门逻辑时，实现 `JsonCodec<T>`。custom codec
直接读写语义 token，不需要先构建 `JsonNode`。

## 最小实现

```cangjie
class UserId {
    public let value: Int64
    public init(value: Int64) { this.value = value }
}

class UserIdCodec <: JsonCodec<UserId> {
    public func write(value: UserId, writer: JsonWriter): Unit {
        writer.writeInt64(value.value)
    }

    public func read(reader: JsonReader): UserId {
        UserId(reader.readInt64())
    }
}

let UserIdJson: JsonCodec<UserId> = UserIdCodec()
```

显式传入 codec：

```cangjie
let text = YJson.toJson(UserId(7), codec: UserIdJson)
let id = YJson.fromJson(text, codec: UserIdJson)
```

同一形式适用于 String、`Array<Byte>`、`InputStream` 和 `OutputStream`。不需要为 custom
codec 创建另一组 API 名称。

## Reader 和 writer contract

`JsonReader` 提供 scalar 读取、array/object 边界、field name、skip、path、location 和
`error(message, code)`。`JsonWriter` 提供对应 scalar、name、container、path 和 error
方法。

对象 codec 必须完整消费或写出一个值：

```cangjie
class PointCodec <: JsonCodec<Point> {
    public func write(value: Point, writer: JsonWriter): Unit {
        writer.startObject()
        writer.writeName("x")
        writer.writeInt64(value.x)
        writer.writeName("y")
        writer.writeInt64(value.y)
        writer.endObject()
    }

    public func read(reader: JsonReader): Point {
        var x: Int64 = 0
        var y: Int64 = 0
        reader.startObject()
        while (reader.hasObjectField()) {
            let name = reader.readName()
            match (name) {
                case "x" => x = reader.readInt64()
                case "y" => y = reader.readInt64()
                case _ => reader.skipValue()
            }
        }
        reader.endObject()
        Point(x, y)
    }
}
```

custom codec 应保持 immutable 或自行同步，因为应用可以并发调用同一个 codec instance。
不要向下转型到 runtime 的具体 reader/writer，不要持有 reader、writer 或 caller input 到调用
结束之后。需要报告业务格式错误时，使用 `reader.error` 或 `writer.error`，以保留当前
JSON Pointer path。

## 组合现有 codec

`JsonCodecs` 提供 scalar codec，以及以下容器组合器：

```cangjie
let ids = JsonCodecs.array(UserIdJson)
let optional = JsonCodecs.option(UserIdJson)
let list = JsonCodecs.arrayList(UserIdJson)
let byName = JsonCodecs.stringMap(UserIdJson)
```

generated 字段只需要专用 codec 时，使用 `@JsonUsing[UserIdJson]`，不必改变字段类型的全局
行为。

遵守这个 backend-neutral contract 后，同一 codec 可以由 Pure String/bytes/stream 入口，
以及命名 Native/yyjson façade 驱动。


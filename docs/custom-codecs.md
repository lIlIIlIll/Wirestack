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

## 使用 Int64 作为映射键

业务类型是 `HashMap<Int64, User>` 时，可以用自定义 codec 在 JSON 字段名和整数键之间转换。
JSON 对象的键是字符串，`JsonCodecs.stringMap` 只接受 `HashMap<String, T>`。
下面的 `Int64MapJsonCodec<T>` 是应用侧实现，可以与任意 `JsonCodec<T>` 组合。

在已配置 `yjson` 和 `yjson_macros` 依赖的项目中，将以下代码放入 `src/main.cj`。
将 `package play` 调整为项目的包名。`@JsonCodec` 会生成 `UserJson`，不需要额外构造。

```cangjie
package play

import std.collection.*
import yjson.*
import yjson_macros.*

class Int64MapJsonCodec<T> <: JsonCodec<HashMap<Int64, T>> {
    private let stringCodec: JsonCodec<HashMap<String, T>>

    public init(inner: JsonCodec<T>) {
        stringCodec = JsonCodecs.stringMap(inner)
    }

    public func write(value: HashMap<Int64, T>, writer: JsonWriter): Unit {
        let fields = HashMap<String, T>()
        for ((key, item) in value) {
            fields.add(key.toString(), item)
        }
        stringCodec.write(fields, writer)
    }

    public func read(reader: JsonReader): HashMap<Int64, T> {
        let fields = stringCodec.read(reader)
        let result = HashMap<Int64, T>()
        for ((name, item) in fields) {
            let key = try {
                YJson.fromJson(name, codec: JsonCodecs.int64)
            } catch (_: JsonException) {
                throw JsonException("Invalid Int64 object key '${name}'", code: "invalid_map_key")
            }
            if (key.toString() != name) {
                throw JsonException("Non-canonical Int64 object key '${name}'", code: "invalid_map_key")
            }
            result.add(key, item)
        }
        result
    }
}

@JsonCodec
class User {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}

main(): Unit {
    let tmp = HashMap<Int64, User>()
    tmp.add(1, User(7, "Alice"))
    let codec = Int64MapJsonCodec<User>(UserJson)
    let text = YJson.toJson(tmp, codec: codec)
    let users = YJson.fromJson(text, codec: codec)
    println(users[1].name)
}
```

运行 `cjpm run` 后输出 `Alice`。示例的 JSON 是：

```json
{"1":{"id":7,"name":"Alice"}}
```

序列化和反序列化都显式传入同一个 codec，解码结果是 `HashMap<Int64, User>`，可以用
`users[1]` 访问。`YJson.fromJson<User>(text)` 表示解码单个 `User`，不适用于这个映射。

这个实现接受 `Int64` 范围内的标准十进制键，包括零、负数和两端边界。非法整数、越界值，
以及 `"01"`、`"+1"`、`"-0"`、`"1.0"`、`"1e0"` 和带空白的键都会触发
`invalid_map_key`，避免不同字符串转换成同一个整数键。相同字符串字段名的重复键处理
沿用 `stringMap` 和调用方的读取选项。

读写过程各创建一个临时映射，额外空间随条目数增长。此示例适用于可以接受该开销的映射；
它没有提供专门的 fast-reader 实现。

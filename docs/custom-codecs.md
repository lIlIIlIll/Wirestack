# 自定义 Codec

不能使用 `@JsonCodec`，或需要自定义 JSON 格式时，实现 `JsonCodec<T>`。
自定义 codec 通过 reader 和 writer 直接读写 JSON 值，无需先构建 `JsonNode`。

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

字符串、`Array<Byte>`、`InputStream` 和 `OutputStream` 入口都支持显式 codec 参数。

## 实现读取和写出方法

`JsonReader` 提供标量读取、数组和对象遍历、字段名读取、值跳过、路径与位置查询，以及
`error(message, code)`。`JsonWriter` 提供对应的标量、字段名和容器写出方法，也支持路径查询
和错误构造。

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

应用可能并发调用同一个 codec 实例，因此 codec 应保持不可变，或自行同步。
不要向下转型到运行库的具体 reader 或 writer 类型，也不要在调用结束后继续持有 reader、
writer 或调用方输入。报告业务格式错误时，用 `reader.error` 或 `writer.error` 构造异常，
以保留当前 JSON Pointer 路径。

## 组合现有 codec

`JsonCodecs` 提供标量 codec，以及以下容器组合器：

```cangjie
let ids = JsonCodecs.array(UserIdJson)
let optional = JsonCodecs.option(UserIdJson)
let list = JsonCodecs.arrayList(UserIdJson)
let byName = JsonCodecs.stringMap(UserIdJson)
```

仅需为某个字段指定 codec 时，使用 `@JsonUsing[UserIdJson]`，不必改变字段类型的全局
行为。

遵守上述要求后，同一 codec 可用于纯仓颉的字符串、字节数组和流入口，也可用于
Native 和 yyjson 后端。

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
    private let inner: JsonCodec<T>

    public init(inner: JsonCodec<T>) {
        this.inner = inner
    }

    public func write(value: HashMap<Int64, T>, writer: JsonWriter): Unit {
        writer.startObject()
        for ((key, item) in value) {
            writer.writeName(key.toString())
            inner.write(item, writer)
        }
        writer.endObject()
    }

    public func read(reader: JsonReader): HashMap<Int64, T> {
        let result = HashMap<Int64, T>()
        reader.startObject()
        let objectPath = reader.path()
        while (reader.hasObjectField()) {
            let name = reader.readName()
            let keyPath = objectPath + "/" + name.replace("~", "~0").replace("/", "~1")
            let keyLocation = reader.location()
            let key = try {
                YJson.fromJson(name, codec: JsonCodecs.int64)
            } catch (_: JsonException) {
                throw JsonException("Invalid Int64 object key '${name}'",
                    code: "invalid_map_key", path: keyPath, location: keyLocation)
            }
            if (key.toString() != name) {
                throw JsonException("Non-canonical Int64 object key '${name}'",
                    code: "invalid_map_key", path: keyPath, location: keyLocation)
            }
            result[key] = inner.read(reader)
        }
        reader.endObject()
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
由 reader 按调用方的读取选项执行；允许重复键时，后一个值覆盖前一个值。

先调用 `startObject()`，再保存对象路径，确保 reader 已加入外层数组的下标。
键在 `readName()` 之后、读取字段值之前校验。示例按 JSON Pointer
规则转义字段名，显式将字段路径和当前 `reader.location()` 传入异常。这样即使 reader
尚未把字段名加入路径，也能保留嵌套上下文；例如 `users` 对象中非法键 `"bad"` 的路径是 `/users/bad`。

这个实现逐字段读写，不创建临时字符串映射；解码时只创建结果映射。它没有提供专门的
fast-reader 实现。

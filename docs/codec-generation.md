# `@JsonCodec` 生成指南

在类型声明上添加 `yjson_macros` 提供的 `@JsonCodec`，编译时即可生成对应的
`JsonCodec<T>` 和 `GeneratedCodecProviderV1<T>` 实现。宏随调用方的包一起编译，
不扫描源码目录，也不向仓库写入生成文件。

## 最小声明

```cangjie
import yjson.*
import yjson_macros.*

@JsonCodec
class User {
    public let id: Int64
    public var name: String

    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}
```

非泛型类型得到 `UserJson: JsonCodec<User>`。随后既可以使用自动推导 codec 的入口，也可以显式传 codec：

```cangjie
let text = YJson.toJson(User(7, "Alice"))
let same = YJson.toJson(User(7, "Alice"), codec: UserJson)
```

泛型类型得到 `TypeJson<T>(): JsonCodec<Type<T>>` 函数。参与自动推导的泛型参数必须满足
`GeneratedCodecProviderV1<T>` 约束；使用 `@JsonUsing` 的字段由显式 codec 决定。

## 支持范围

- class 和 struct；
- enum，包括带关联值的构造器；
- 泛型声明；
- 通过 `@JsonPolymorphic` 和重复 `@JsonSubtype` 声明的封闭多态映射。

## 字段规则

只有 public、非 static、具有显式类型的字段默认参与。private、protected、internal 和默认
可见字段不参与。

| 标记 | 行为 |
| --- | --- |
| `@JsonIgnore` | 排除字段 |
| `@JsonName["wire_name"]` | 修改写出名称和主读取名称 |
| `@JsonAlias["old_name"]` | 增加读取时接受的别名，可重复 |
| `@JsonIncludeNull` | `Option` 为 `None` 时仍写出 `null` |
| `@JsonUsing[codecExpression]` | 为字段选择自定义 codec |

```cangjie
@JsonCodec
class Profile {
    @JsonName["profile_id"]
    @JsonAlias["legacy_id"]
    public let id: Int64

    @JsonIncludeNull
    public var nickname: Option<String>

    @JsonIgnore
    public var cacheKey: String = ""

    public init(id: Int64, nickname: Option<String>) {
        this.id = id
        this.nickname = nickname
    }
}
```

JSON 名称和别名在同一类型中必须唯一。

## 构造和缺失字段

宏选择参数最多的构造器，并按参数名匹配字段。构造器未覆盖的可变字段在
构造后赋值；不可变字段必须由构造器接收。构造参数默认值可以处理缺失输入，
`Option<T>` 字段也不是必需字段。

- 必需字段缺失：`missing_field`。
- 未知字段：默认忽略；`JsonUnknownFieldPolicy.Reject` 时为 `unknown_field`。
- 重复键：默认拒绝并返回 `duplicate_key`；`LastWins` 必须显式选择。

## 多态类型

```cangjie
@JsonCodec
@JsonSubtype["dog", Dog]
@JsonSubtype["cat", Cat]
@JsonPolymorphic[discriminator: "kind"]
open class Animal {
    public let id: Int64
    public init(id: Int64) { this.id = id }
}
```

每个子类型都必须有 codec。上例用 `kind` 字段选择子类型；字段缺失时报
`missing_discriminator`，值不在映射中时报 `unknown_discriminator`。
生成的读取器先缓冲完整根值，读取判别字段后，再把同一份数据交给对应子类型的 codec。
宏为具体 class 和 struct 生成类型明确的对象读写接口，按这些接口分派子类型，
避免误用从 open 基类继承的 codec。

直接以具体子类型调用 `YJson` 时，宏会同时处理父类和子类的字段。父类与子类各自保留
对应的 `JsonCodec<T>`，无需类型擦除适配器或向下转换。

捕获大小受 `JsonReadOptions.maxBufferedValueBytes` 约束，默认 8 MiB；超限使用
`buffered_value_too_large`。根值分派不重复计入容器深度。

## 版本边界

`yjson` 和 `yjson_macros` 必须来自同一次发布。宏生成代码使用协议版本 1，协议不匹配时报
`generated_protocol_mismatch`。

生成代码通过 `generated_support.v1` 调用运行库。默认快速路径还直接引用
`JsonFastReader`、`JsonDirectWriter` 和 `ReadCursor`，这些类型也随 V1 协议一起演进。
快速路径先调用 `GeneratedSupportV1.enterGeneratedEntry()`，校验协议并冻结运行时配置，
再开始解析。

生成代码通过以下方法查找 codec：
`GeneratedCodecProviderV1<T>.generatedCodecV1(_: GeneratedCodecTokenV1<T>): JsonCodec<T>`。
无状态的 token 让父类和子类通过参数类型区分同名方法。这组内部扩展接口不把 codec 或值
转成 `Any`，也不依赖类型擦除、类型恢复适配器或运行时类型转换。

应用应直接声明 `yjson` 和 `yjson_macros` 依赖。不要直接调用生成支持接口或对象读写辅助方法。
这些声明设为 public 是为了让宏跨包展开，应用代码无需调用。

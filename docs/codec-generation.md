# `@JsonCodec` 生成指南

`@JsonCodec` 是 `yjson_macros` 提供的 declaration macro。它在调用方 package 编译时展开，
生成匹配的 `JsonCodec<T>` 和 `GeneratedCodecProviderV1<T>` 实现。它不扫描源码目录，也不
写入仓库级 generated 文件。

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

非泛型类型得到 `UserJson: JsonCodec<User>`。随后既可以使用最短入口，也可以显式传 codec：

```cangjie
let text = YJson.toJson(User(7, "Alice"))
let same = YJson.toJson(User(7, "Alice"), codec: UserJson)
```

泛型类型得到 `TypeJson<T>(): JsonCodec<Type<T>>` 函数。参与自动推导的泛型参数必须满足
`GeneratedCodecProviderV1<T>` 约束；使用 `@JsonUsing` 的字段由显式 codec 决定。

## 支持范围

- class 和 struct；
- enum，包括 associated-value constructor；
- generic 声明；
- 通过 `@JsonPolymorphic` 和重复 `@JsonSubtype` 声明的封闭多态映射。

## 字段规则

只有 public、非 static、具有显式类型的字段默认参与。private、protected、internal 和默认
可见字段不参与。

| 标记 | 行为 |
| --- | --- |
| `@JsonIgnore` | 排除字段 |
| `@JsonName["wire_name"]` | 修改写出名称和主读取名称 |
| `@JsonAlias["old_name"]` | 增加只读 alias，可重复 |
| `@JsonIncludeNull` | `Option` 为 `None` 时仍写出 `null` |
| `@JsonUsing[codecExpression]` | 为字段选择 custom codec |

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

JSON 名称和 alias 在同一类型中必须唯一。

## 构造和缺失字段

宏选择参数最多的 initializer，并按参数 identifier 匹配字段。构造器未覆盖的 mutable 字段在
构造后赋值；immutable 字段必须由构造器接收。构造参数默认值可以处理缺失输入，
`Option<T>` 字段也不是必需字段。

- 必需字段缺失：`missing_field`。
- 未知字段：默认忽略；`JsonUnknownFieldPolicy.Reject` 时为 `unknown_field`。
- 重复 key：默认拒绝并返回 `duplicate_key`；`LastWins` 必须显式选择。

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

每个 subtype 都必须有 codec。discriminator 缺失和未知分别产生
`missing_discriminator` 与 `unknown_discriminator`。generated reader 捕获一次完整根值，
读取 discriminator 后把同一 replay value 交给 subtype codec。宏为 concrete class/struct
生成 typed object-provider bridge；dispatcher 通过该 bridge 读写 subtype 字段，因此不会把
open base 继承的普通 provider 误当作 subtype codec。

直接以 concrete subtype 调用 `YJson` 时，宏组合 base object fields 和 subtype object
fields。父类与子类各自保留精确的 `JsonCodec<T>`，不需要 erased adapter 或向下转换。

捕获大小受 `JsonReadOptions.maxBufferedValueBytes` 约束，默认 8 MiB；超限使用
`buffered_value_too_large`。根 dispatcher 不重复计入容器深度。

## 版本边界

宏输出除了 versioned generated-support bridge，还会在 default fast path 直接引用
具体的 `JsonFastReader` / `JsonDirectWriter` 与 `ReadCursor` 类型。这些类型是 V1 协议表面
的一部分：与 `generated_support.v1` 同版本锁定，随 protocol version 一起演进。宏输出嵌入
protocol version 1；runtime 与 macro 必须来自同一个 lockstep release；protocol 不匹配以
`generated_protocol_mismatch` 明确失败。default fast path 入口先执行
`GeneratedSupportV1.enterGeneratedEntry()`（protocol 校验 + runtime freeze），因此生成代码
不会在未冻结的 runtime 上解析。

普通 generated lookup 使用
`GeneratedCodecProviderV1<T>.generatedCodecV1(_: GeneratedCodecTokenV1<T>): JsonCodec<T>`。
零状态 token 让继承链上的父类和子类 provider 通过参数类型重载。这条 closed SPI 不把
codec 或 value 转成 `Any`，也没有 erase/reify adapter 或运行时类型转换。

应用应直接声明 `yjson` 和 `yjson_macros` 依赖。不要直接调用 generated-support 或
generated object-provider helper；
这些 public 声明用于跨 package 展开代码，不是应用 API。

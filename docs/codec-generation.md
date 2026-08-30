# `@JsonCodec` 生成指南

`@JsonCodec` 是 `yjson_macros` 提供的 declaration macro。它在声明所在的调用方 package
编译时展开，生成匹配的 `JsonCodec<T>` 和 `JsonCodecProvider`。它不扫描源码目录，也不
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

非泛型 public 类型会得到 public `UserJson: JsonCodec<User>`。随后既可以使用最短的
`YJson.toJson/fromJson<User>`，也可以把 `UserJson` 传给显式 codec 入口。

## 支持范围

- class、struct、enum 和 associated-value enum；
- generic 声明；参与 codec 推导的类型参数必须满足 `JsonCodecProvider` 约束；
- 通过 `@JsonPolymorphic` 和重复 `@JsonSubtype` 声明的封闭多态映射。

## 字段如何参与

| 声明 | 行为 |
| --- | --- |
| public 且有显式类型 | 默认参与 |
| private | 不参与，也不能用 `@JsonProperty` 暴露 |
| protected/internal/默认可见性 + `@JsonProperty` | 显式参与 |
| `@JsonIgnore` | 排除 |
| `@JsonName["wire_name"]` | 修改写出名称和主读取名称 |
| `@JsonAlias["old_name"]` | 增加只读 alias，可重复 |
| `@JsonIncludeNull` | `Option` 为 `None` 时仍写出 `null` |
| `@JsonUsing[codecExpression]` | 为该字段选择 custom codec |
| `@JsonStatic` | 绑定由 `@JsonCodec` 生成的字段 codec；不能与 `@JsonUsing` 共用 |

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

## 构造、缺失字段和未知字段

宏选择可用 initializer 中参数最多的一项，并按参数 identifier 匹配字段。构造器未覆盖的
mutable 字段在构造后赋值；immutable 字段必须由构造器接收。构造参数默认值可以处理缺失
输入，`Option<T>` 字段默认也不是必需字段。

- 必需字段缺失：`missing_field`。
- 未知字段：默认忽略；`JsonUnknownFieldPolicy.Reject` 时为 `unknown_field`。
- 重复 key：默认 LastWins；`JsonDuplicateKeyPolicy.Reject` 时为 `duplicate_key`。

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
`missing_discriminator` 与 `unknown_discriminator`。generated reader 捕获一次根值，读取
discriminator 后把同一值 replay 给 subtype codec；Native tape 不会先序列化再解析。

`maxPolymorphicObjectBytes = 0` 表示不启用局部 byte budget；正数超限产生
`polymorphic_object_too_large`，负数配置被拒绝。根多态 dispatcher 不重复计入容器深度。

## 版本边界

宏输出嵌入所需的 generated-support protocol version，并且只调用
`GeneratedSupportV1Reader`、`GeneratedSupportV1Writer`、replay/polymorphic 等窄 SPI；生成
源码不依赖 `JsonDirectReader`、`JsonDirectWriter` 或公开 raw helper。v1 SPI 不变时允许
runtime 与宏跨 patch 版本使用；协议不匹配会在编译或初始化边界明确失败。

应用应显式依赖 `yjson` 与 `yjson_macros`。两个 package 随同一个 lockstep release 发布，
并声明相同 generated-support protocol；不要混用不同 release 的 runtime 与 macro artifact。

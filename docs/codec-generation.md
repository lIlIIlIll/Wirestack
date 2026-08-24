# `@JsonCodec` 生成指南

`@JsonCodec` 是 `yjson_macros` 提供的 declaration macro。它在消费方 package 编译时展开，生成匹配的 `JsonCodec<T>` 与 `JsonCodecProvider` 实现；它不是扫描 `src/` 的 build script，也不会生成仓库级 `generated_json_codecs.cj`。

## 支持的声明

- class、struct 和 enum；
- generic 声明，但参与字段 codec 推导的类型参数必须满足 `JsonCodecProvider` 约束；
- associated-value enum；
- 通过 `@JsonPolymorphic` 与重复的 `@JsonSubtype` 声明封闭的多态映射。

最小示例：

```cangjie
import yjson_all.*

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

宏会公开 `UserJson: JsonCodec<User>`，并使 `User` 可直接传给 `YJson.toJson` 与 `YJson.fromJson<User>`。

## 字段参与规则

- public 字段默认参与，且必须写出显式类型。
- private 字段不会参与；private 字段不能用 `@JsonProperty` 暴露。
- protected、internal 或默认可见性字段只有标记 `@JsonProperty` 才参与。
- `@JsonIgnore` 排除字段。
- `@JsonName["wire_name"]` 修改写出名称与主读取名称。
- `@JsonAlias["old_name"]` 增加读取 alias；可以重复声明。
- `@JsonIncludeNull` 使值为 `None` 的 `Option` 字段仍写出 `null`。
- `@JsonUsing[codecExpression]` 为字段指定 custom codec。
- `@JsonStatic` 声明字段类型本身由 `@JsonCodec` 生成，用于直接绑定静态 fast bridge；不能与 `@JsonUsing` 组合。

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

## 构造与缺失字段

宏从可用 initializer 中选择参数最多的构造器，并按参数 identifier 匹配字段；构造参数默认值可以处理缺失输入。构造器未覆盖的 mutable 字段会在构造后赋值，immutable 字段必须由构造器接收。

普通必需字段缺失会得到 `JsonException.code == "missing_field"`。`Option<T>` 字段不是必需字段。未知字段默认忽略，可通过 `JsonReadConfig(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject)` 改为拒绝；重复 key 默认 LastWins，也可以改为 Reject。

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

每个 subtype 也必须生成 codec。discriminator 缺失或未知分别产生稳定错误码；根多态对象还受 `maxPolymorphicObjectBytes` 约束。

默认 `maxPolymorphicObjectBytes = 0` 表示不启用这一局部 byte budget；设置正数时，超限
产生 `polymorphic_object_too_large`。负数配置会被拒绝。generated polymorphic decode
通过 `JsonCodecReader.readReplayValue` 捕获一次根值，读取 discriminator 后直接重放给
subtype codec；Native tape 路径不把对象序列化成 JSON 再解析。

宏展开代码依赖当前 runtime 的 generated-code bridge，因此 `yjson_macros` 与 `yjson` 必须使用完全匹配的版本并一起重新编译。

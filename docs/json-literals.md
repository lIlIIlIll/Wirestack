# JSON 字面量

`@Json` 和 `@JsonValue` 是 expression macro，不是 annotation。

## `@Json`: 直接生成文本

```cangjie
let key = "user"
let id: Int64 = 7

let text = @Json({
    "ok": true,
    "items": [1, null, $(id)],
    $(key): $(User(id, "Alice")),
})
```

静态 token 在编译期验证；插入值通过其 `JsonCodecProvider` 写出。每个 `$()` 表达式按源码从左到右求值一次。`@Json` 直接驱动 `JsonDirectWriter`，不会先构造 AST。

对象 key 可以使用 `$(expression)` 动态生成。静态重复 key 是编译错误；存在动态 key 时，
运行时碰撞采用 LastWins。发生碰撞时所有插值表达式仍按源码顺序各执行一次，但只有最终
胜出的字段调用其 codec 写出；不要依赖被覆盖字段的 codec 副作用。

## `@JsonValue`: 构造可修改树

```cangjie
let root = @JsonValue({"name": "Alice", "items": [1, 2]})
root["name"] = "Bob"
root["items"][0] = 9
println(YJson.stringify(root))
```

当结果只需立刻写成 JSON 时使用 `@Json`；后续需要更新、查询或传给 AST API 时使用 `@JsonValue`。

macro 在调用方编译，需依赖 `yjson_all`，或同时依赖匹配版本的 `yjson` 与 `yjson_macros`。

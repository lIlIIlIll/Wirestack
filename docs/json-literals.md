# JSON 字面量

`@Json` 和 `@JsonValue` 是 expression macro。它们在调用方编译，不是 annotation，也不是
运行时字符串模板。

## 直接生成文本：`@Json`

```cangjie
let key = "user"
let id: Int64 = 7

let text = @Json({
    "ok": true,
    "items": [1, null, $(id)],
    $(key): $(User(id, "Alice")),
})
```

静态 token 在编译期验证。插值值通过 `JsonCodecProvider` 写出，`@Json` 直接驱动
`JsonDirectWriter`，不会先创建 AST。

## 构造可修改树：`@JsonValue`

```cangjie
let root = @JsonValue({"name": "Alice", "items": [1, 2]})
root["name"] = "Bob"
root["items"][0] = 9
println(YJson.stringify(root))
```

需要修改、查询、Schema 校验或 Patch 时使用 `@JsonValue`。结果只会立即写成 JSON 时使用
`@Json`，避免不必要的树分配。

## 插值和 key 规则

- `$()` 表达式按源码从左到右各求值一次。
- 对象 key 可以是静态字符串，也可以使用 `$(expression)` 动态生成。
- 静态重复 key 是编译错误。
- 只要对象含动态 key，运行时冲突采用 LastWins。
- 即使字段最终被覆盖，其 key/value 插值表达式仍会执行；不要依赖 codec 写出副作用。

macro 需要 `yjson_all`，或一组完全匹配的 `yjson` 与 `yjson_macros` 依赖。仓库中的
`packages/json_literal_integration` 验证语法、求值顺序、动态冲突和可修改节点行为。

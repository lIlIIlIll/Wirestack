# JSON Schema

yjson 提供常用 JSON Schema 校验子集，但不是完整 draft 2020-12 实现。

```cangjie
let schema = JsonSchema.parse("""
{
  "type": "object",
  "required": ["name"],
  "properties": {
    "name": {"type": "string", "minLength": 1}
  }
}
""")

let instance = YJson.parse("{\"name\":\"Alice\"}")
schema.validateOrThrow(instance)
```

`validate` 返回 `ArrayList<JsonValidationError>`；每个错误包含 `jsonPath` 与 `schemaPath`。`isValid` 只返回布尔值，`validateOrThrow` 抛出第一个错误。

## 当前支持

- boolean schema；
- `type`、`enum`、`const`；
- 数值 minimum/maximum；
- `minLength`、`maxLength`；
- object 的 `required`、`properties`；
- array 的 `items`；
- `allOf`、`anyOf`、`oneOf`、`not`；
- `$defs`/`definitions` 内的本地 `$ref`。

远程 reference、完整 vocabulary、annotation collection 与 draft 2020-12 的其余 keyword 不在当前 contract 内。不要仅凭 `draft` 字段默认值推断完整 draft compliance。

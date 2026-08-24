# 配置与错误

## 读取配置

`JsonReadConfig.defaults` 等价于以下主要策略：

```cangjie
JsonReadConfig(
    unknownFieldPolicy: JsonUnknownFieldPolicy.Ignore,
    duplicateKeyPolicy: JsonDuplicateKeyPolicy.LastWins,
    numberPolicy: JsonNumberPolicy.Int64WhenExact,
    includeErrorLocation: true,
    maxDepth: 256,
    maxPolymorphicObjectBytes: 0,
    maxStringBytes: 0,
    maxBytes: 0
)
```

三个 byte limit 的 `0` 表示 unlimited；`maxDepth` 必须为正数。处理不可信输入时不要依赖 unlimited 默认值，见 [资源限制](resource-limits.md)。

`JsonNumberPolicy.PreserveLiteral` 保留非结构化 number token 的文本表示；默认策略会在精确可表示时产生 Int64。重复 key 与未知 typed 字段可分别改为 Reject。

## 写出配置

`JsonWriteConfig.compact` 生成紧凑文本，`JsonWriteConfig.pretty` 使用换行与四空格缩进。
便利入口 `YJson.stringifyPretty()` 的默认参数是两空格；需要与 `JsonWriteConfig.pretty`
完全一致时应显式传入对应配置或缩进。自定义配置还控制 newline、indent、separator 空格、
HTML-safe escaping、错误位置、最大深度与 `maxBytes`。写出侧 `maxBytes = 0` 表示
unlimited；正数超限产生 `output_too_large`。whole-document Native backend 在写入调用方
stream 前完成检查；默认 Pure backend 可能已经写出前缀，因此失败后不得继续使用该
document 的输出。

## 错误处理

解析、codec 与限制错误使用 `JsonException`。对需要稳定分类的调用方，应判断 `error.code`，不要匹配 message。常见公开 code 包括：

| code | 含义 |
| --- | --- |
| `parse_error` | JSON token 或文档结构无效 |
| `unknown_field` | typed decode 在 Reject 策略下遇到未知字段 |
| `duplicate_key` | Reject 策略下遇到重复 key |
| `missing_field` | generated codec 的必需字段缺失 |
| `missing_discriminator` | generated polymorphic decode 缺少 discriminator |
| `unknown_discriminator` | generated polymorphic decode 遇到未知 discriminator 值 |
| `max_depth` | 读取或写出超过最大嵌套深度 |
| `document_too_large` | `maxBytes` 或 Compact 表示上限被触发 |
| `output_too_large` | 写出结果超过 `JsonWriteConfig.maxBytes` |
| `string_too_large` | decoded UTF-8 string 超过预算 |
| `polymorphic_object_too_large` | 根多态对象超过 replay budget |
| `codec_type_mismatch` | erased codec 收到或返回错误类型 |
| `codec_contract` | 调用了 codec 未提供的 fast contract |
| `missing_key` / `index_out_of_bounds` | AST 查询失败 |

启用 `includeErrorLocation` 时，适用的 parse/limit 错误会附带 offset/location；并非所有语义错误都能提供相同粒度的位置。

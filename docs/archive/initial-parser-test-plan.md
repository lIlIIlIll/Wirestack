# yjson 初始 Parser 测试计划（历史归档）

> 本文是项目早期的 parser/serializer gap 计划，不再代表 yjson 2.0 的当前测试状态、
> public contract 或 release gate。当前测试层级、命令和 CI mapping 见
> [维护者测试指南](../maintainers/testing.md)。本文保留原始计划内容，仅供追溯。

基于 JSONTestSuite 标准的完整测试设计

## 测试目标

确保 yjson JSON 解析器符合 RFC 8259 JSON 规范，覆盖所有核心功能、边界情况和错误路径。

## 测试分类

### 优先级定义
- **P0（必须）**: 正确性关键，直接影响数据完整性
- **P1（重要）**: 边界值和关键错误路径
- **P2（次要）**: 兼容性和特殊场景
- **P3（可选）**: 性能和优化相关

---

## 测试模块划分

### 模块一：基础类型解析（P0）

#### 1.1 Null 值测试
| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| null_valid | 合法 null | `null` | 接受，返回 JsonNullValue | P0 |
| null_invalid_case | 大小写错误 | `Null`, `NULL`, `nul` | 拒绝，抛异常 | P0 |
| null_with_spaces | 空白字符包围 | ` null  `, `\nnull\t` | 接受 | P1 |
| null_in_object | 对象中的 null | `{"a":null}` | 接受，字段值为 null | P0 |
| null_in_array | 数组中的 null | `[null, 1, null]` | 接受 | P0 |

#### 1.2 Boolean 值测试
| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| bool_true | 合法 true | `true` | 接受，返回 JsonBoolValue(true) | P0 |
| bool_false | 合法 false | `false` | 接受，返回 JsonBoolValue(false) | P0 |
| bool_invalid_case | 大小写错误 | `True`, `FALSE`, `tru`, `fals` | 拒绝 | P0 |
| bool_with_spaces | 空白包围 | ` true  `, `\tfalse\n` | 接受 | P1 |

#### 1.3 Number 值测试
| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| number_int_positive | 正整数 | `123`, `0`, `9223372036854775807` | 接受 | P0 |
| number_int_negative | 负整数 | `-123`, `-0`, `-9223372036854775808` | 接受 | P0 |
| number_int_overflow | Int64 溢出 | `9223372036854775808`, `-9223372036854775809` | 接受，返回 NumberLiteral | P1 |
| number_float_basic | 浮点数 | `1.5`, `0.0`, `-12.34` | 接受 | P0 |
| number_float_precision | 精度边界 | `0.123456789012345` | 接受 | P1 |
| number_exponent | 指数形式 | `1e10`, `1E-5`, `1.2e+3` | 接受 | P0 |
| number_leading_zero | 前导零（已覆盖） | `01`, `-01` | 拒绝 | P0 |
| number_missing_digit | 缺失数字 | `-.`, `1.e2`, `1e` | 拒绝 | P0 |
| number_empty_fraction | 空小数 | `1.` | 拒绝 | P0 |
| number_double_minus | 双负号 | `--1` | 拒绝 | P0 |
| number_plus_sign | 正号 | `+1` | 拒绝（JSON 规范不允许） | P0 |

#### 1.4 String 值测试
| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| string_empty | 空字符串 | `""` | 接受 | P0 |
| string_plain_ascii | ASCII 字符串 | `"hello"` | 接受 | P0 |
| string_with_escape | 转义字符 | `"\"\\\b\f\n\r\t"` | 接受，正确解码 | P0 |
| string_unicode_basic | Unicode 转义 | `"\\u0041\\u4e2d"` | 接受，"A中" | P0 |
| string_surrogate_pair | 代理对（已覆盖） | `"\\uD834\\uDD1E"` | 接受，𝄞 | P1 |
| string_surrogate_invalid | 错误代理对（已覆盖） | `"\\uD834"`, `"\\uDD1E"` | 拒绝 | P0 |
| string_control_unescaped | 未转义控制字符（已覆盖） | `"\u0001"` | 拒绝 | P0 |
| string_unterminated | 未闭合字符串 | `"hello` | 拒绝 | P0 |
| string_invalid_escape | 错误转义 | `"\\x"`, `"\\q"` | 拒绝 | P0 |
| string_unicode_invalid | 错误 Unicode | `"\\u00"` | 拒绝 | P0 |

---

### 模块二：结构类型测试（P0）

#### 2.1 Array 测试
| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| array_empty | 空数组 | `[]` | 接受，size=0 | P0 |
| array_single | 单元素 | `[1]` | 接受，size=1 | P0 |
| array_mixed_types | 混合类型 | `[null, true, 1, "a", []]` | 接受 | P0 |
| array_nested | 嵌套数组 | `[[1, 2], [3, 4]]` | 接受 | P0 |
| array_deep_nesting | 深层嵌套 | `[[][][][]...]` (50层) | 接受或栈限制 | P2 |
| array_missing_comma | 缺失逗号 | `[1 2]` | 拒绝 | P0 |
| array_trailing_comma | 尾随逗号 | `[1,]` | 拒绝（JSON 规范） | P0 |
| array_extra_comma | 多余逗号 | `[1,,2]` | 拒绝 | P0 |
| array_unterminated | 未闭合 | `[1, 2` | 拒绝 | P0 |

#### 2.2 Object 测试
| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| object_empty | 空对象 | `{}` | 接受，size=0 | P0 |
| object_single_field | 单字段 | `{"a":1}` | 接受 | P0 |
| object_multiple_fields | 多字段 | `{"a":1, "b":2}` | 接受 | P0 |
| object_nested | 嵌套对象 | `{"a":{"b":2}}` | 接受 | P0 |
| object_duplicate_key | 重复键（已覆盖） | `{"a":1, "a":2}` | 接受，后者覆盖 | P1 |
| object_non_ascii_key | 非 ASCII 键（已覆盖） | `{"名字":1}` | 接受 | P0 |
| object_escaped_key | 转义键（已覆盖） | `{"a\\\"b":1}` | 接受 | P1 |
| object_missing_colon | 缺失冒号 | `{"a"1}` | 拒绝 | P0 |
| object_missing_comma | 缺失逗号 | `{"a":1 "b":2}` | 拒绝 | P0 |
| object_trailing_comma | 尾随逗号 | `{"a":1,}` | 拒绝 | P0 |
| object_unquoted_key | 未引用键 | `{a:1}` | 拒绝 | P0 |
| object_single_quoted_key | 单引号键 | `{'a':1}` | 拒绝 | P0 |
| object_unterminated | 未闭合 | `{"a":1` | 拳回 | P0 |

---

### 模块三：空白字符测试（P1）

| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| whitespace_before | 前导空白 | `\n\t  123` | 接受 | P1 |
| whitespace_after | 尾随空白 | `123\n\t  ` | 接受 | P1 |
| whitespace_between | 中间空白 | `[ 1 , 2 ]` | 接受 | P1 |
| whitespace_object | 对象空白 | `{ "a" : 1 }` | 接受（已覆盖） | P1 |
| whitespace_invalid | 非法空白 | `123\x00`, `123\u0000` | 拒绝 | P0 |

---

### 模块四：错误路径测试（P1）

| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| error_empty | 空输入 | `""` | 拒绝 | P0 |
| error_only_whitespace | 仅空白 | `  \n\t  ` | 拒绝 | P0 |
| error_partial_literal | 部分 literal | `nul`, `tru` | 拒绝 | P0 |
| error_invalid_token | 无效 token | `@`, `#`, `!` | 拒绝 | P0 |
| error_multiple_values | 多值 | `123 456` | 拒绝（已检查） | P1 |
| error_unclosed_comment | 注释（JSON 不支持） | `/* comment */` | 拒绝 | P0 |

---

### 模块五：Unicode 与编码测试（P2）

| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| utf8_valid | 合法 UTF-8 | `"你好世界"` | 接受 | P0 |
| utf8_invalid_bytes | 无效 UTF-8 字节 | 无效字节序列 | 拒绝或报错 | P2 |
| bom_with_json | BOM + JSON | `\uFEFF{"a":1}` | 拒绝或跳过 BOM | P2 |
| unicode_non_character | Unicode 非字符 | `"\\uFFFF"` | 接受（实现相关） | P2 |

---

### 模块六：性能与边界测试（P3）

| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| perf_large_array | 大数组 | `[1,2,3,...10000]` | 接受，性能合理 | P3 |
| perf_large_string | 大字符串 | `"a...a"` (1MB) | 接受，性能合理 | P3 |
| perf_deep_nesting | 深层嵌套 | 递归 200 层 | 接受或栈错误 | P2 |
| perf_memory_efficiency | 内存效率 | 复杂结构 | 检查内存占用 | P3 |

---

### 模块七：序列化测试（P0）

| 用例 ID | 测试内容 | 输入 | 预期输出 | 优先级 |
|---------|----------|------|----------|--------|
| serialize_null | 序列化 null | JsonNullValue() | `null` | P0 |
| serialize_bool | 序列化 boolean | JsonBoolValue(true) | `true` | P0 |
| serialize_int | 序列化整数 | JsonIntValue(123) | `123` | P0 |
| serialize_float | 序列化浮点（已覆盖） | JsonFloatValue(1.5) | `1.5` | P0 |
| serialize_float_non_finite | 非有限浮点（已覆盖） | NaN, Inf | 拒绝 | P0 |
| serialize_string | 序列化字符串 | JsonStringValue("a\"b") | `"a\"b"` | P0 |
| serialize_array | 序列化数组 | JsonArrayValue([1, 2]) | `[1,2]` | P0 |
| serialize_object | 序列化对象 | JsonObjectValue({"a":1}) | `{"a":1}` | P0 |
| serialize_roundtrip |往返测试 | parse → toString | 输入与输出等价 | P0 |

---

### 模块八：FastReader/DirectReader 测试（P1）

这些测试已在 `json_regression_test.cj` 中部分覆盖，需补充：

| 用例 ID | 测试内容 | 输入 | 预期行为 | 优先级 |
|---------|----------|------|----------|--------|
| fastreader_invalid_utf8 | 无效 UTF-8 | 字节级读取 | 错误处理 | P2 |
| fastreader_boundary_values | 边界值数字 | 极大 Int64 | 正确解析 | P1 |
| directreader_missing_fields | 缺失字段 | 结构化解码 | 默认值或错误 | P1 |
| directreader_extra_fields | 多余字段（已覆盖） | 结构化解码 | 跳过 | P1 |

---

## 差距分析结果

### 已覆盖的测试场景
- ✅ 基础类型：null, boolean 部分覆盖
- ✅ 数字：前导零拒绝
- ✅ 字符串：控制字符、代理对
- ✅ 对象：非 ASCII 键、重复键、转义键
- ✅ 空白：对象字段冒号后空白
- ✅ 序列化：非有限值拒绝
- ✅ FastReader：字段名匹配、跳过未知值

### 缺失的关键测试场景（优先级排序）

#### P0 必须补充
1. **基础类型全覆盖**：null/boolean 完整测试、数字各种格式
2. **字符串完整测试**：所有转义序列、错误转义、未闭合
3. **结构完整测试**：空数组/对象、混合类型、嵌套结构
4. **错误路径**：空输入、无效 token、结构错误
5. **序列化往返**：所有类型的 toString 测试

#### P1 重要补充
1. **数字边界值**：Int64 溢出、浮点精度、指数形式
2. **Unicode 边界**：BOM、非字符、无效字节
3. **空白完整测试**：各种位置和类型
4. **深层嵌套**：栈溢出测试

#### P2 次要补充
1. **性能测试**：大数组、大字符串
2. **特殊场景**：极端边界、实现相关行为

---

## 测试实现计划

### 第一批实现（P0 - 正确性关键）
**预计用例数：60+**

- 基础类型解析完整测试
- 字符串完整测试（转义、错误）
- 结构完整测试（数组、对象）
- 序列化往返测试
- 关键错误路径

**文件：**
- `src/test_json_parser_compliance.cj` - 核心解析合规测试
- `src/test_json_serializer.cj` - 序列化测试

### 第二批实现（P1 - 边界值）
**预计用例数：30+**

- 数字边界值（溢出、精度）
- Unicode 边界
- 空白完整覆盖
- 深层嵌套

**文件：**
- `src/test_json_boundary.cj` - 边界值测试

### 第三批实现（P2/P3 - 特殊场景）
**预计用例数：20+**

- 性能测试
- 特殊 Unicode
- 实现相关行为

**文件：**
- `src/test_json_special_cases.cj` - 特殊场景测试

---

## 测试命名规范

遵循仓颉 unittest 规范：

```
@Test
class JsonParserComplianceTest {
    @TestCase
    func parseValidNull(): Unit { ... }

    @TestCase
    func parseInvalidNullCase(): Unit { ... }
}
```

命名原则：
- 以 `parse` / `serialize` / `handle` 开头表示操作
- `Valid` / `Invalid` 表示预期结果
- 描述性名称，不使用编号
- 每个用例聚焦单一测试点

---

## 预期结果

完成全部测试后：
- **测试覆盖率**：核心解析逻辑 > 90%
- **测试用例数**：> 100 个
- **测试质量**：每个用例有明确的输入、预期和验证
- **发现问题**：记录在测试中发现的所有代码问题

---

## 后续建议

1. **持续集成**：将测试加入 CI 流程
2. **测试数据管理**：考虑引用 JSONTestSuite 原始文件
3. **性能基准**：添加基准测试以跟踪性能退化
4. **覆盖率分析**：使用 `cjcov` 分析覆盖率差距
5. **错误报告改进**：改进错误消息的可读性和诊断价值

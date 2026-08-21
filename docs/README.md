# yjson 文档

这里是 README 与维护者证据之间的用户文档入口。用户指南以中文为主，保留 Cangjie API/type 的英文名称；尚未建立逐页双语镜像，维护者历史文档可能仍为英文。

## 开始使用

1. [项目 README](../README.md)：定位、安装和最短 typed codec 示例。
2. [API 选择指南](choosing-an-api.md)：typed、AST、Compact DOM、stream 与 Native 的选择。
3. [Codec 生成](codec-generation.md)：`@JsonCodec` 的声明、字段与构造规则。
4. [JSON 字面量](json-literals.md)：`@Json`、`@JsonValue` 和运行时插值。

## 数据模型与 I/O

- [自定义 Codec](custom-codecs.md)
- [AST 与 Compact DOM](ast-and-compact.md)
- [Stream I/O](streams.md)
- [配置与错误](configuration-and-errors.md)
- [资源限制](resource-limits.md)
- [JSON Schema](schema.md)
- [Backend 使用指南](backends.md)

## 兼容性、迁移与性能

- [1.x → 2.0 迁移](migration/1.x-to-2.0.md)
- [2.0 API/ABI change inventory](public-api-inventory.md)：只记录 2.0 RC 的新增和变化，不是完整 API reference。
- [性能结论、方法与结果](performance/README.md)
- [Release notes](../RELEASE_NOTES.md)

## 维护者文档

- [当前架构](architecture.md)
- [Repository layout](maintainers/repository-layout.md)
- [测试策略与命令](maintainers/testing.md)
- [Native backend 内部契约](maintainers/native-internals.md)
- [发布流程](maintainers/releasing.md)
- [2.0.0 RC1 evidence snapshot](../release/2.0.0-rc1/evidence.md)
- [历史初始 parser test plan](archive/initial-parser-test-plan.md)

当前文档仍有两个明确缺口：完整逐符号 API reference 尚未自动生成；性能原始机器可读结果尚未全部随仓库发布。相应页面会区分“当前公开 contract”和“单次实验或 release evidence”。

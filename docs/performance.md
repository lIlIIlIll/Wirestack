# 性能研究结论

本页记录已经影响 public API 或默认实现的方向性结论，不保存逐次实验流水账。可引用数字
统一从[带日期结果](performance/README.md)进入。

## 已采用

- `@Json` 直接写出 `String`，`@JsonValue` 构造 AST；不为表面统一引入中间树。
- generated codec 保留 canonical fast path，显式 config 继续走完整语义 reader。
- `YJson.fastDecoder` 复用 codec 选择，但不持有输入或跨调用共享可变 parser state。
- Large Map encode 使用单次遍历和 direct output，避免排序/materialization/二次扫描。
- Pure 是未配置时冻结的默认引擎；Native 加速只在首次 `YJson` 调用前由应用基于
  profiling 显式初始化一次。

## 未采用

- 持有 caller buffer 的 reusable decode session：所有权和生命周期成本过高。
- 按 payload 动态切换 session：分支与状态增加，未形成稳定全局收益。
- borrowed view 作为 generated codec 默认路径：扩大 public lifetime contract，收益不稳定。
- 为单一 Person workload 添加专用产品路径：局部收益不足以覆盖回归面。
- Native DOM materialize 成 AST 作为通用 fast path：跨层和完整树分配抵消目标收益。

这些结论不是永久禁令。新的实现可以在等语义、配对、反转顺序和完整回归表下重新验证，
但不能只凭历史 quick run 或 parser 名称推断收益。

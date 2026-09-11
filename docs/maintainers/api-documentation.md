# API 文档注释与 CI

API 站点由固定版本的 cjdoc 从发布包图生成。版本和源码校验和见
[`release/cjdoc-tool.toml`](../../release/cjdoc-tool.toml)，已知解析限制见
[`release/cjdoc-policy.toml`](../../release/cjdoc-policy.toml)。不要用系统中恰好安装的
其他 cjdoc 版本替换这条构建链。

## 写能够进入页面的注释

文档注释放在声明前；带注解的类型应放在注解前。当前固定的 cjdoc 使用
`/** ... */`。普通 `//` 注释和历史 `///` 注释不能代替可绑定的 API 文档注释。
第一段说明行为，后续段落说明约束、所有权和错误；参数使用 `@param`，非 `Unit`
函数使用 `@return`，异常使用 `@throws`。

```cangjie
/**
 * 返回调用方指定的节点数预算。
 *
 * @param maxNodes 必须为正数的节点数预算。
 * @return 原样返回的节点数预算。
 * @throws IllegalArgumentException 预算不为正数。
 */
public func checkedBudget(maxNodes: Int64): Int64 {
    if (maxNodes <= 0) { throw IllegalArgumentException("maxNodes must be positive") }
    maxNodes
}
```

注释应描述实际实现，不以函数名的同义改写充数。重载分别说明字符串、UTF-8 字节、
调用方流和显式 codec 的区别。流不会被库关闭，但失败的输出操作可能已经写入部分
内容。只读视图不等于底层可变节点的不可变快照。内部算法注释仍应解释不变量、
边界和取舍，不必全部作为 API 文档暴露。

## 生成与验证

从仓库根目录执行，环境需提供发布配置要求的 `cjc` 和 `cjpm`：

```bash
python3 scripts/test_check_api_documentation.py
python3 scripts/test_generate_api_docs.py
YJSON_API_DOCS_OUTPUT=target/api-docs scripts/ci_job.sh api-docs
```

生成器拒绝覆盖已存在的输出目录。重跑时使用新的输出路径，或先确认旧目录仅包含
可重新生成的文档再清理它。文档门禁也可以单独检查一个已有站点：

```bash
python3 scripts/check_api_documentation.py target/api-docs
```

主要产物为 `index.html`、各包的 `html/index.html` 和 `docs.json`、构建清单
`api-docs.json`，以及注释门禁报告 `documentation-coverage.json`。
HTML 为静态页面，解压后可直接打开根目录 `index.html`。

## 注释覆盖范围

[`release/api-documentation-required.json`](../../release/api-documentation-required.json)
记录本阶段必须有文档的应用入口类型及已有成员数量，包括 `YJson`、`JsonCodecs`、
读写选项、`JsonDocument`、`JsonCodec`、错误位置和字段注解。
门禁检查 cjdoc 实际生成的 Doc IR，而不是只统计源码中是否出现注释符号：

- 必需类型及其所有直接 public 成员必须具有非空摘要，包括每个重载和新增成员。
- 每个参数必须具有成功绑定的参数说明；返回非 `Unit` 的函数必须具有返回值说明。
- 已有重载不能静默从生成结果中消失。

这不是整个仓库的 100% 文档覆盖承诺。报告同时给出核心包整体的公开摘要覆盖数，
让剩余工作可见。生成代码 SPI、其他可选包和不支持展开的宏仍按现有包图和 cjdoc
策略处理；不得通过隐藏未解析声明或放宽现有 API 清单门禁制造通过结果。

## CI 产物与发布

现有 `API Documentation` job 在 PR、主分支和开发分支构建中运行共享生成命令。
每次成功生成并通过注释门禁后，上传
`yjson-api-docs-<run-id>-<run-attempt>` 普通 Actions artifact，配置保留 30 天；
最终保留时长仍受仓库与组织策略约束。构建不依赖 PR 拥有 Pages 部署权限。

Pages 专用 artifact 只在 `main` 的 push 构建上传。正式部署继续要求
`api-docs` 与 `ci-required` 成功，并验证部署提交仍为 `main` HEAD。
PR 文档构建成功不表示已发布上线，也不替代其他质量门禁。

只修改注释也应运行贡献指南要求的 API 清单和源码暂存测试；更改生成链时还必须
完成真实的九包生成。不要将 `target/api-docs` 或临时生成脚本提交到源码仓库。

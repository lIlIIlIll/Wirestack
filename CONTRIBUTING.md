# 参与 yjson 开发

开始修改前阅读[文档导航](docs/README.md)、[架构](docs/architecture.md)和
[仓库布局](docs/maintainers/repository-layout.md)。

## 确定修改范围

- Pure 运行时修改留在 `src/lib_*.cj`，不要引入无关的 Native 依赖。
- 宏变化同时检查调用方展开代码与匹配的运行时接口。
- 算法通过 `JsonValueView` 工作，不为每种后端存储分别实现算法。
- 可选后端保持独立的命名入口、显式资源管理，以及一致的选项和错误语义。
- 文档只描述当前公开 API、清单、测试或可核对的测试记录。

不要提交 `target`、缓存、临时基准测试语料、凭据、开发机绝对路径或无关格式化。测试文件
统一使用 `*_test.cj` 后缀。

## 验证

按修改内容选择核心包、外部使用方测试、标准、Native、打包、文档、覆盖率或性能
检查。完整矩阵见[测试指南](docs/maintainers/testing.md)。检查命令退出码，也检查输出
中是否存在未处理异常。

只修改文档、API 接口清单或发布暂存时，至少运行：

```terminal
python3 scripts/check_api_inventory.py
python3 scripts/test_stage_source_tree.py
python3 scripts/test_release_temp_tree.py
```

修改 API 文档生成流程时还要运行 cjdoc 验证与生成器单元测试和真实九包生成。修改
运行时或 codec 时运行 `cjpm test --no-color`，并按受影响包增加外部使用方测试。
修改 Markdown 链接时，把全部改动文件传给 `scripts/check_local_markdown_links.py`。

## 公开 API、文档与性能

- 公开声明、C ABI 或包版本配对变化必须同步机器可读的接口清单。
- 生成代码接口变化必须由独立使用方测试证明。
- 用户文档的 API 示例要以当前声明或可运行的示例验证。
- 性能结论必须提供等语义、同环境、固定 CPU、交替/反转 A/B、校验和、RSS 和跨性能配置
  证据，并遵循[性能方法](docs/performance/methodology.md)。
- 基准测试成绩提高不能替代正确性、覆盖率或兼容性测试。

## 提交质量

一个提交只处理一件事，测试与行为修改放在一起。文档、生成产物或机械整理
只有在各自构成完整修改时才拆分。提交前复查最终差异，确保没有包含其他人的并行修改。


## API 文档注释

公开 API 使用 cjdoc 可绑定的 `/** ... */` 注释；每个重载分别说明参数、返回值和约束。
格式、覆盖范围、构建与 CI 产物见[API 文档维护指南](docs/maintainers/api-documentation.md)。

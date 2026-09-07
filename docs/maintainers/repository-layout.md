# 仓库布局与发布文件

源码仓库发布为九个包。运行时关系见[架构说明](../architecture.md)。

## 目录职责

| 路径 | 职责 | 发布行为 |
| --- | --- | --- |
| `src/lib_*.cj` | Pure 运行时、公开 API、生成代码接口 | `yjson` 源码目录 |
| `src/*_test.cj` | 根包白盒测试和接口约定测试 | 由 cjpm 执行测试；不参与普通构建 |
| `packages/yjson_macros` | 声明宏和包装宏 | 独立包，版本同步发布 |
| `packages/yjson_algorithms` | Pointer、Patch、Path、Schema | 可选包 |
| `packages/yjson_backends` | 后端元数据和资源接口 | 高级接口包 |
| `packages/yjson_native_primitives` | 扫描器静态库和第一方 provider 接口 | 第一方内部包 |
| `packages/yjson_native_accel` | 普通 `YJson` 的一次性 Native 初始化 | 可选包 |
| `packages/yjson_native` | Custom Native 命名入口 | 可选包 |
| `packages/yjson_yyjson` | yyjson 命名入口、内置源码及构建脚本 | 可选包 |
| `packages/yjson_schema_formats` | 国际化格式扩展 | 可选包 |
| `packages/*integration*` | 模拟外部使用方的测试 | 仅供仓库使用 |
| `packages/*benchmarks*` | 基准测试程序 | 仅供仓库使用 |
| `native/` | 扫描器、DOM 适配器和 C 测试 | 按发布图复制到 Native 暂存目录 |
| `release/` | 发布图、API 快照、cjdoc 配置、清单 | 发布工具 |
| `scripts/` | CI、覆盖率、暂存、验证 | 发布工具 |

## 开发清单与发布清单

根清单只在 `[test-dependencies]` 中依赖 `yjson_macros`。普通 `cjpm build` 构建
核心包；`cjpm test` 才加入测试所需的宏依赖。发布暂存使用
`scripts/release_package_stage.py` 复制发布图中声明的源码目录，再换入使用统一版本号的
发布清单。

`release/release-files.txt` 是新候选副本的文件清单。对每个收录的 cjpm 项目，
`release_temp_tree.py` 要求全部 `.cj` 源码、依赖锁定文件和构建钩子完整存在，防止文件名或
手写清单遗漏测试、测试数据或产品源码。

所有 cjpm 测试文件统一使用 `*_test.cj` 后缀。cjpm 和 cjdoc 都依赖这条约定排除测试声明；
不要使用 `test_*.cj` 前缀替代。

## 生成代码

仓库不单独构建或提交生成的 codec。所有 `@JsonCodec` 在声明所在包展开。根测试中生成的类型来自 `*_test.cj` 测试数据，
不属于运行时产品声明。

## 构建钩子的职责

- `yjson_native_primitives/build.cj`：Custom 扫描器和 Compact 静态库；
- `yjson_yyjson/build.cj`：扫描器、辅助代码和内置 yyjson 适配器；
- `yjson_schema_formats/build.cj`：libidn2 接口；
- 基准测试构建钩子：仅供仓库使用的工具。

Pure 核心包、宏、算法、后端接口和加速初始化包不应引入 Native 构建钩子。

## API 文档生成

`release/cjdoc-tool.toml` 固定 cjdoc 源码、提交、源码归档校验和、编译器和二进制文件验证要求。`release/cjdoc-policy.toml` 只允许清单中列出的已知不支持项。
`scripts/generate_api_docs.py` 遍历发布图的九个包，不维护第二份包清单。

CI 在 Linux 生成 Pages 产物；Windows/macOS 只运行 Pure 包检查。Pages 只在推送到 `main` 后部署。

## 维护约束

- 包源码目录新增已纳入版本控制的 `.cj` 文件时同步发布文件清单；
- 开发版和暂存发布版都要通过独立使用方测试；
- 不要将测试数据、基准测试辅助函数、后端策略或发布验证参数加入默认 API；
- 包版本配对、许可证、仅含源码的归档和 cjdoc 的版本信息必须通过检查。


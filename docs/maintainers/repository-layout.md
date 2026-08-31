# Repository layout 与发布边界

本页描述源码仓库如何映射成九个发布 package。运行时关系见[架构说明](../architecture.md)。

## 目录职责

| 路径 | 职责 | 发布行为 |
| --- | --- | --- |
| `src/lib_*.cj` | Pure runtime、public API、generated bridge | `yjson` source root |
| `src/*_test.cj` | root white-box 与 contract tests | cjpm test；不进入普通 artifact build |
| `packages/yjson_macros` | declaration/wrapper macros | 独立 lockstep package |
| `packages/yjson_algorithms` | Pointer、Patch、Path、Schema | optional package |
| `packages/yjson_backends` | backend metadata/resource interface | advanced interface package |
| `packages/yjson_native_primitives` | scanner archive 和 closed provider SPI | internal first-party package |
| `packages/yjson_native_accel` | 普通 `YJson` 的一次性 Native 初始化 | optional package |
| `packages/yjson_native` | Custom Native named façade | optional package |
| `packages/yjson_yyjson` | yyjson named façade、vendor、build | optional package |
| `packages/yjson_schema_formats` | international format provider | optional package |
| `packages/*integration*` | external-style consumers | repository-only |
| `packages/*benchmarks*` | benchmark executables | repository-only |
| `native/` | scanner、DOM adapter 和 C tests | 按 graph 复制到 Native stage |
| `release/` | graph、API snapshot、cjdoc policy、manifest | release infrastructure |
| `scripts/` | CI、coverage、staging、qualification | release infrastructure |

## Development 与 publication manifest

根 manifest 只在 `[test-dependencies]` 中依赖 `yjson_macros`。普通 `cjpm build` 构建
core；`cjpm test` 才把 macro 加入测试闭包。发布 staging 使用
`scripts/release_package_stage.py` 整体复制 graph 中声明的 source root，再换入 central-version
manifest。

`release/release-files.txt` 是 fresh-candidate allowlist。对每个被收录 cjpm project，
`release_temp_tree.py` 要求全部 `.cj` source、lockfile 和 build hook 完整存在，防止文件名或
手写清单遗漏测试、fixture 或产品源码。

所有 cjpm 测试文件统一使用 `*_test.cj` 后缀。cjpm 和 cjdoc 都依赖这条约定排除测试声明；
不要使用 `test_*.cj` 前缀替代。

## Generated code

仓库没有 codec-generation build step，也没有 checked-in generated codec。所有
`@JsonCodec` 在声明所在 package 展开。根测试中的 generated 类型来自 `*_test.cj` fixture，
不是 runtime 产品声明。

## Build hook 所有权

- `yjson_native_primitives/build.cj`：Custom scanner/Compact archive；
- `yjson_yyjson/build.cj`：scanner、support 和 vendored yyjson adapter；
- `yjson_schema_formats/build.cj`：窄 libidn2 seam；
- benchmark build hook：repository-only infrastructure。

Pure core、macros、algorithms、backend interface 和 acceleration wrapper 不应引入 Native build
hook。

## 文档生成边界

`release/cjdoc-tool.toml` 固定 cjdoc source、commit、archive checksum、compiler 和 binary
qualification。`release/cjdoc-policy.toml` 只允许精确的已知 0.6 unsupported 项。
`scripts/generate_api_docs.py` 遍历 release graph 的九个 package，不维护第二份 package 清单。

CI 在 Linux 生成 Pages artifact；Windows/macOS 只运行 Pure package gate。Pages deployment
只在 `main` push 发生。

## 维护约束

- package source root 新增 Git-tracked `.cj` 文件时同步 release manifest；
- development graph 和 staged graph 都要有独立 consumer；
- 不把 fixture、benchmark helper、backend strategy 或 qualification knob 推成默认 API；
- package pairing、license、source-only archive 和 cjdoc identity 必须由 gate 验证。


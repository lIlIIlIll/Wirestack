# Repository layout 与发布边界

本页描述源码仓库如何映射成发布包。产品运行时关系见[架构说明](../architecture.md)。

## 目录职责

| 路径 | 职责 | 发布行为 |
| --- | --- | --- |
| `src/*.cj` | Pure runtime、public API 与 cjpm tests | 完整 source root 进入 staging |
| `src/*_test.cj` | white-box、fixture 与 contract tests | 正常 artifact build 不编译 |
| `packages/yjson_macros` | declaration/expression macros | 独立 package |
| `packages/yjson_native_primitives` | scanner archive 与 closed provider SPI | internal package |
| `packages/yjson_native_accel` | 默认 façade 的一次性 Native 初始化 | optional package |
| `packages/yjson_native` | Custom Native 高级 backend | optional package |
| `packages/yjson_yyjson` | yyjson facade、vendor、build 与 tests | optional package |
| `packages/yjson_schema_formats` | international format provider | optional package |
| `packages/*integration*` | external-style consumers | 不发布 |
| `native/` | scanner、DOM、adapter 与 C tests | 按 graph 进入 primitives/yyjson package |
| `release/package-manifests` | 发布 manifest 输入 | staging only |

## Development 与 publication manifest

根 manifest 只在 `[test-dependencies]` 中依赖 `yjson_macros`。普通 `cjpm build` 只构建 core；
`cjpm test` 才按 `yjson → yjson_macros → yjson tests` 的方向加入 macro。发布 staging 使用
`scripts/release_package_stage.py` 整体复制 graph 中声明的 source root，再换入 release manifest。

`yjson_native_primitives` staging 额外复制 `build.cj`、scanner/Compact C source/header 和
build helper。`yjson_native` 只携带高级 Cangjie backend；yyjson package 还携带 adapter、
vendored source 与 license。registry rehearsal 必须拒绝 path dependency、target 和预构建
object/archive/shared library。

## Generated code

仓库没有 codec-generation build step，也没有 `generated_json_codecs.cj`。所有
`@JsonCodec` 都在声明所在 package 编译时展开。根测试中看到的 generated 类型来自
`*_test.cj` fixture，不是 runtime 产品声明。

## Build hook 所有权

- `yjson_native_primitives/build.cj`：Custom Compact 和 scanner archive。
- `yjson_yyjson/build.cj`：scanner、Custom support 与 vendored yyjson adapter。
- `yjson_schema_formats/build.cj`：窄 libidn2 seam。
- `packages/benchmarks/build.cj`：benchmark infrastructure，不是产品依赖。

Pure core、macros、algorithms、backend API 和 acceleration wrapper 不应引入 Native build hook。

## 维护约束

- package source root 中新增的 Git-tracked source 默认进入 staging；测试必须使用 `*_test.cj`。
- Development 与 release graph 都要有独立 consumer 验证。
- 不把 fixture、benchmark helper 或 qualification knob 推成默认应用 API。
- package pairing、license 和 source-only archive 由 release gate 验证，不能靠人工目录检查。

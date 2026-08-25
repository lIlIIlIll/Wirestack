# Repository layout 与发布边界

本页只描述源码仓库如何映射成发布包。产品运行时关系见[架构说明](../architecture.md)。

## 目录职责

| 路径 | 职责 | 是否进入 core 发布包 |
| --- | --- | --- |
| `src/lib_*.cj` | Pure runtime 与 public API | 是 |
| `src/example_support.cj` | fixture / benchmark model | 否 |
| `src/test_*.cj` | white-box 与 contract tests | 否 |
| `packages/yjson_macros` | declaration/expression macros | 独立 package |
| `packages/yjson_all` | aggregate import | 独立 package |
| `packages/yjson_native` | Custom Native facade/build/tests | optional package |
| `packages/yjson_yyjson` | yyjson facade/vendor/build/tests | optional package |
| `packages/yjson_schema_formats` | international format provider | optional package |
| `packages/*integration*` | external-style consumers | 不发布 |
| `native/` | scanner、DOM、adapter 与 C tests | 仅 Native package |
| `release/package-manifests` | 发布 manifest 输入 | staging only |

## Development 与 publication manifest

根 manifest 为了编译仓库 fixture 而依赖 `yjson_macros`。发布 staging 使用
`scripts/release_package_stage.py` 复制 `src/lib_*.cj` 并换入 release manifest；发布态
`yjson` 不依赖 macro package。

Native staging 额外复制 `build.cj`、C source/header 和 build helper。yyjson package 还
携带 vendored source 与 license。registry rehearsal 必须拒绝 path dependency、target 和
预构建 object/archive/shared library。

## Generated code

仓库没有 codec-generation build step，也没有 `generated_json_codecs.cj`。所有
`@JsonCodec` 都在声明所在 package 编译时展开。根构建中看到的 generated 类型来自 fixture
和 test declaration，不是发布源码文件。

## Build hook 所有权

- `yjson_native/build.cj`：Custom Compact 和 scanner archive。
- `yjson_yyjson/build.cj`：scanner、Custom support 与 vendored yyjson adapter。
- `yjson_schema_formats/build.cj`：窄 libidn2 seam。
- `packages/benchmarks/build.cj`：benchmark infrastructure，不是产品依赖。

Pure core、macros 和 aggregate package 不应引入 Native build hook。

## 维护约束

- 新 public source 必须明确是否进入 staging。
- Development 与 release graph 都要有独立 consumer 验证。
- 不把 fixture、benchmark helper 或 qualification knob 推成默认应用 API。
- package pairing、license 和 source-only archive 由 release gate 验证，不能靠人工目录检查。

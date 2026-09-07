# yjson_native_primitives

本包为 `yjson` 提供 Linux x86_64 原生底层操作，供同版本的第一方包内部使用。
应用应依赖 `yjson_native_accel`，不要直接导入本包。

本包构建原生扫描器静态库，并提供进程启动时使用的内部 provider 接口，不提供另一套 JSON API。

## 构建要求

构建主机需要以下环境和工具：

- Linux x86_64；其他主机会被 `scripts/build_native_scanner.py` 拒绝。
- Python 3，用于运行构建脚本。
- C11 编译器，默认使用 `clang`，可通过 `CC` 指定。
- `ar`，可通过 `AR` 指定。

仓库根目录下的 `scripts/build_native_scanner.py` 在编译前检查这三个工具，每次执行都会重新构建扫描器静态库。

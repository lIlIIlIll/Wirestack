# 性能设计结论

本页记录已经影响 `0.1.x` API 或默认实现的方向性结论，不保存逐次实验流水账。可引用数字
统一从[带日期结果](performance/README.md)进入。

## 已采用

- generated codec 直接进入统一 reader/writer，不先构建 AST；
- String、bytes 和 stream 共享 semantic parser，不维护第二套配置或错误语义；
- `JsonValueView` 让 serializer、Pointer、Path 和 Schema 读取不同 storage，而不强制
  materialization；
- `JsonPath.matches()` 返回惰性 cursor，`first()` 在首个匹配后停止；
- Schema resolver 图和 regex 在构造阶段冻结，validation 不再执行外部 I/O 或重复编译；
- ordinary `YJson` 在引擎冻结后只读取原子 frozen flag，不再进入 process-wide Mutex；
- Native/yyjson 的 root serialization 和 document materialization 自动使用一次读锁导出 tape；
  retained 子 view 的细粒度操作仍逐次与 `close()` 线性化；
- Large Map encode 使用单次遍历和 direct output，避免排序、materialization 和二次扫描；
- direct reader 只在 duplicate-key policy 要求拒绝时分配 name set；
- Pure 是默认引擎；Native acceleration 只在首次 `YJson` 调用前显式初始化；
- 高级 Native/yyjson 只通过命名 façade 暴露，普通 API 不承担 strategy dispatch。

## 未采用

- 持有 caller buffer 的 reusable decode session：会扩大生命周期和并发 contract；
- 按 payload 动态切换 parser/backend：会增加热路径分支和不可预测状态；
- borrowed view 作为 generated codec 默认路径：会把输入 lifetime 推入普通 typed API；
- 为单一 benchmark shape 增加产品专用入口；
- 运行期安装、卸载或自动 fallback Native provider；
- 任意 backend strategy 注入到普通 `YJson` API；
- 在 JSONPath `first()` 前先 collect 全部匹配，或在每次 validation 前重新 parse Schema；

这些结论保留后续实现空间，但新的默认路径必须先提供等语义测试、固定 CPU 的交替/反转 A/B、
checksum、RSS 和跨 profile 重复证据。历史 quick run 或 parser 名称不能证明收益。

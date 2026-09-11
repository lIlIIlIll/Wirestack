# CI 失败判据与保护设置迁移

本次修改不调整仓库后台、不合并 PR，也不把历史运行结果当作新配置的通过证据。

## 本次修复

`CI Required` 等待九个质量任务，包括完整 Linux 测试矩阵、Windows/macOS Pure、
API 文档、覆盖率、证据检查、生成代码风险检查和门禁自身的回归测试。
只有每个依赖都明确返回 `success` 才通过；失败、取消、跳过、缺失及意外依赖均失败。
部署任务不属于合并门禁，避免 PR 中正常跳过的部署导致误报。

Pages 等待 `CI Required` 和文档产物，使用同一个部署并发组，并在部署前查询 main HEAD。
已被新提交取代的构建不再部署；这不是对检查之后 main 不会继续变化的原子保证。

UBSan 编译加入 `-fno-sanitize-recover=undefined`，sanitizer 与 fuzz 共用这组参数。
非法 Native 检查模式立即失败。符号检查先单独执行 `nm`，成功后才分析输出；
命令失败不再等价于“没有违禁符号”。

Patch coverage 在求交集前拒绝空行记录和缺失的变更文件。完整报告中的无可执行行改动
显示 `N/A`，不再显示虚假的 `0/0 = 100%`。这项检查不证明编译器生成了完整插桩，
也没有实现四个非核心包的 collector。

Schema adapter 将构造或验证异常计为失败，不再把异常视为正常的 `valid=false`。
标准门禁先运行含两个正常对照和一个错误 Schema 的真实 adapter 回归，再运行官方套件。

CI 不再安装 `harden_llc.sh` 包装器，Pure 检查不重写优化等级、不重试测试失败。
`ci-retry.yml` 自动重跑 watchdog 被移除；手工诊断需要保留第一次失败证据。
覆盖率显式 `-O0` 插桩策略保持不变。

默认 SDK 直接固定为 STS `1.1.0`，不先请求 latest，resolution 为
`pinned-sts`。手工指定版本仍优先。`Cangjie STS (pinned)` 检查名表示
所有 GitHub 托管任务共享同一个 STS 版本。

## 验证命令

```sh
python3 scripts/test_ci_candidate_wiring.py
YJSON_TEST_STANDARDS_ORACLE=1 python3 scripts/test_ci_candidate_wiring.py StandardsOracleTests
```

第一条使用临时目录和受控构建替身验证真实 gate entrypoint，并用真实 Clang 运行 UBSan
正反对照。托管 `ci-guardrails` 安装 Clang，缺少编译器时不允许跳过该探针。
第二条需要仓颉 SDK 和标准 adapter 的原生依赖，由 `standards-conformance` 强制执行；
普通无 SDK 的脚本测试会明确跳过它，不能据此声称仓颉回归已通过。

## 仓库后台迁移（本 PR 不执行）

1. 等新检查在 PR 中实际出现并通过后，给 main 增加 required check `CI Required`，
   来源指定 GitHub Actions。过渡期保留现有 required checks。
2. 验证任一子任务失败、取消或跳过确实阻止合并，再决定是否移除冗余旧检查名。
3. 单独确认 PR 审批、分支保持最新、管理员 bypass、force push、删除保护与 Pages
   environment 规则。不能因为规则读取受限就认定它们关闭。

## 尚未完成

Windows 手工 SDK 安装仍只有摘要记录，需有可信的版本/平台/预期摘要后补执行前校验；
本 PR 不捏造摘要，也不把未知上游下载重新标为已验证。
四组包级覆盖率 collector、完整失败产物上传、GitCode 自托管共享缓存隔离、
dev 分支的集成策略和中央仓端到端发布资格仍需分别完成。
严格恢复原始编译配置可能暴露既有 SDK 问题；失败应保留，不能重新靠降级或取重试成功来放行。

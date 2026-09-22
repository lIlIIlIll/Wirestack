# P1-015 当前版本 Linux 开发基线

本任务执行项目所有者批准的新验收规则。停止追补历史完整资格链，使用当前源码的运行结果决定是否可以继续开发。正式发布资格保持独立。

## 范围与历史记录

- 前置 P1-013、P1-014 均已 COMPLETE，各自证据保留在原任务目录。
- 不改写 M7/M8 历史报告、摘要、签名或审查结论。历史记录不再作为当前开发验收的前置。
- M7-028 审查包和 M7-024 性能验证器的开发回归使用临时输入，执行摘要篡改、缺失、采样不足和源码漂移负例。生产 release validator 和历史 campaign manifest 均未修改。
- 删除只检查 CLI 引导源码写法的测试，改为在 checkout 外实际执行新 CLI 的回归测试。
- 本任务不更改 Cangjie API、协议实现或 SDK。候选生产源码来自已有提交 `26c81160eacc91d7c1726e20d46c9d3aa086addc`。
- M8-007 保持 BLOCKED。开发基线通过不表示独立审查、正式长稳、性能或签名通过。

## 执行当前基线

先按仓库环境约定启用 Cangjie SDK，并提供已固定的 1.1.3 SDK archive。`CANGJIE_HOME`、PATH 与运行时路径必须指向该 SDK。HTML 文档工具沿用已经验证的 cjdoc 0.7.2 环境；SDK 自带的其他版本不作为替代。

```sh
export WIRESTACK_BASELINE_SDK_ARCHIVE=<qualified-sdk-archive>
python3 tools/development_baseline.py capture \
  --revision 26c81160eacc91d7c1726e20d46c9d3aa086addc
python3 tools/development_baseline.py verify
```

`capture` 顺序执行：

1. `scripts/check`，包括全部 Python 回归、架构守卫、文档、Cangjie check/build 和非 Performance 测试。
2. 现有 Linux release collector 的离线双归档构建、依赖扫描、checkout 外安装 consumer、HTTPS client/server 和 runtime-info smoke。
3. 现有十目标 parser fuzz campaign，保留其原阈值。
4. 现有安装制品资源 workload 的 600 秒 preflight，保留原资源与清理判定。

600 秒 preflight 只属于开发门禁。它的正式 soak 判定仍为 INCOMPLETE，不改成 PASS。此入口不运行独立安全审查、86,400 秒 soak、签名或 GitHub 操作。`scripts/check` 本身不隐式运行这些额外资格步骤。

## 绑定与失效

`baseline.json` 是本任务的开发报告，不是 release evidence seal。它记录：

- 实际提交中的 Linux 生产源文件及 release 构建输入，逐文件与工作树匹配；
- 当前测试、工具、native、parser corpus 等执行输入的文本摘要，包含未提交的新工具；
- SDK archive 的 artifact-bytes-v1 摘要、实际安装中每个 archive 普通文件的逐字节匹配及工具版本；
- 当前安装制品的原始字节摘要、payload identity；
- 每条命令、退出码、超时状态、完整脱敏日志及 text-utf8-lf-v1 摘要。

`verify` 不重跑测试，但重验上述输入、日志和制品。新增、删除、修改执行输入都会使旧基线失效，需要重新 capture。它不递归读取历史 M7/M8 qualification、review 或 evidence seal。

工具与测试输入采用当前内容绑定，不声称它们已经包含在选定的生产提交中。新任务合入及发布仍需正常代码审查与提交；本报告不授权 push、PR、受保护 tag 或发布。

日志在保留和计算摘要之前映射为 `<repo>`、`<sdk>`、`<scratch>` 和 `$HOME`。诊断日志内的 producer 原始摘要描述当次临时输入，不冒充脱敏后的历史报告资格。历史机器路径不复制到新报告。

## 后续任务

按 PRD §21.6 和 backlog 的新规则，M9-001 / #170 的开始前置为 P1-015 COMPLETE 加当前基线验证通过，不再依赖 M8-007 正式发布完成。M9-001 仍须自己登记已批准的 16 项任务及 manifest；本任务不领取或实现其中任何一项。

正式发布仍必须取得所选发布候选自身的完整资格。开发 PASS 不能作为 release validator 的输入替代品。

## 验证记录

当前开发基线 PASS，正式发布仍为 NOT_QUALIFIED。

| 验收 | 当前结果 |
|---|---|
| 生产源码及构建输入 | 167 个文件与提交 26c81160eacc91d7c1726e20d46c9d3aa086addc 匹配 |
| 当前执行输入 | 569 个源码、测试、工具、fixture 与文档输入绑定摘要 |
| SDK | 1.1.3；497 个 archive 普通文件与实际安装逐字节匹配 |
| scripts/check | exit 0；Python 467 + 178 + 24 项通过；Cangjie 785 passed、23 Performance exclusions、0 failed/error；架构和文档 PASS |
| 安装 consumer | exit 0；双归档一致、HTTPS client/server、runtime-info、依赖扫描 PASS |
| parser fuzz | exit 0；10 个目标 PASS |
| 资源 preflight | exit 0；完整 600 秒、5,885 cycles；任务、response、pool lease、transport 与 cancellation 终态 owner 均为 0 |
| 身份及范围负例 | 9 项修改均被拒绝；恢复原输入后 verify exit 0 |

当前制品为 dist/p1-015/wirestack-0.1.0-linux-x86_64-glibc.tar.gz，
artifact-bytes-v1 摘要为 2c4d4db3d68a1fb0293fda3b7381818215a5f732ffd6887774f17fc3f55e7643。
报告分别见 [baseline.json](baseline.json)、[verification.json](verification.json)、
[task-check.json](task-check.json) 和 commands/ 中的完整脱敏日志。
初始失败、外层超时和主动取消的尝试均未计为 PASS，原因保留在 verification.json。
测试场景见 [test-plan.md](test-plan.md)。

P1-015 是首次切换的开发基线，不要求每个后续功能任务回写本任务证据。
M9-001 启动时核验本基线，之后各任务按真实功能依赖和各自当前源码验收继续推进。
未来源码变化使本报告失效时，保留它作为历史基线；新的结果归属当时的任务，不补改旧报告。

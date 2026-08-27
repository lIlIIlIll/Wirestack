# M6-025：HTTP/2 facade 并发回归和失败后退出

## 状态

- 规划状态：**READY**
- 责任域：HTTP/2 可靠性
- 影响平台：Linux x86_64 glibc
- 依赖：M6-021、M6-022、M6-023、M6-024，均为 COMPLETE
- 证据目录：`docs/evidence/M6-025/`

## 触发证据

M3-028 的 canonical `scripts/check` 已通过 Python 工具测试、架构检查、
`cjpm check` 和 `cjpm build`。最后的非 Performance Cangjie 全仓测试没有
退出。该进程在约 1 小时 47 分钟后由操作者终止。

下列限定命令在 600 秒硬上限内复现了同一类问题：

```text
cangjie_env; timeout 600s cjpm test src/internal/http1 src/tls src/http -j 1 --parallel 1 --exclude-tags=Performance
```

结果为 exit 124。runner 先在
`HttpFacadeTest.publicHttp2StreamAndConnectionHandlesRespectTheirScopes` 和
`HttpFacadeTest.publicHttp2SlowStreamCannotStarveOneTenOrHundredSiblings`
报告错误，随后停在
`HttpFacadeTest.tlsHttp2StreamLimitIsAppliedAcrossConcurrentPublicRequests`。
超时前只完成 14 个测试。终端输出没有保留首个异常的完整堆栈，因此本任务
不能预设产品死锁、跨用例资源残留或 unittest runner 清理是根因。

同一 checkout 的直接相邻回归均通过：

- TLS engine、trust 和 StdNet transport：94 passed，15 个 Performance-tagged
  测试按命令排除，0 failed。
- Public TLS 和 HTTP/1：112 passed，3 个 Performance-tagged 测试按命令排除，
  0 failed。
- M6-024 的独立真实 TLS h2 race 已有 100/100 PASS 证据。该结果不能替代
  facade 全包连续执行和失败清理证据。

## 实施范围

1. 建立有硬上限的最小复现。相关三个 facade 用例必须在同一进程中按原顺序
   连续执行。
2. 在超时或首个异常时保留完整异常、Cangjie task 状态、进程树、活动连接、
   H2 stream registry、flow-control waiter、write reservation 和 server shutdown
   状态。
3. 判断首个错误和后续不退出是否共享一个根因。若存在多个独立缺陷，任务须
   分别给出复现和修复证据，但仍只修改 M6-025 范围内的 HTTP facade、HTTP/2
   生命周期或对应测试清理代码。
4. 修复实际根因。所有成功、异常、取消和断言失败路径都必须有界地关闭 client、
   server、TLS connection、stream、Future 和 waiter。
5. 增加确定性回归。回归必须证明用例之间不共享可变状态，前一个用例失败后也
   不阻止 runner 和剩余资源退出。

## 语义护栏

- 不提高现有 5 秒 request Deadline，也不新增 timeout owner。
- 不通过 `sleep`、重试失败断言、跳过用例、改变测试顺序或拆分进程隐藏问题。
- 不降低 M6-021 的 stream-limit、GOAWAY 和 graceful shutdown 验收条件。
- 不降低 M6-022 的 request、connection 和 stream cancellation exactly-once
  语义。
- 不降低 M6-024 的 sibling fairness、窗口、队列和 buffer 上限。
- 不用 exception message 作为产品控制流。
- 公共 `wirestack.http` API 保持兼容，除非根因证据证明现有公共契约无法满足
  PRD。任何公共 API 变更须单独完成兼容性审查。

## 验收条件

1. 保存 pre-fix FAIL。证据包含完整首个异常、600 秒内的 bounded termination、
   活动资源快照和根因结论。
2. 三个相关 facade 用例在一个进程中按原顺序连续运行 100 轮。结果须为
   300 passed、0 failed、0 timeout，且每轮结束后活动 server、connection、
   stream、waiter 和后台 task 均为 0。
3. `cjpm test src/http -j 1 --parallel 1 --exclude-tags=Performance` 在 10 分钟
   硬上限内退出 0。不能出现跳过的非 Performance 用例。
4. `scripts/check` 在明确记录的硬上限内退出 0。报告须分列工具测试、架构检查、
   check、build 和 Cangjie test 的结果。
5. 保留 Linux 环境、提交、命令、原始输出、每轮耗时、失败计数、超时计数和
   资源终态。`docs/planning/status.md` 仅在上述条件全部满足后改为 COMPLETE。

## 非目标

- 不重新设计 HTTP/2 flow control、connection pool 或公共 cancellation API。
- 不运行一小时 SSE profile 或 24 小时 soak。
- 不扩展 Windows、macOS、Android、iOS 或 HarmonyOS 完成状态。
- 不修改 Cangjie SDK、runtime、`std.net` 或 `cangjie_stdx`。

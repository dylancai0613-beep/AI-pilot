# AI coding Pilot

这是一个独立的自动化开发试验项目，用于验证：

1. 可配置 Developer Agent 自动修改代码；
2. 程序自动启动；
3. 自动测试发现运行错误；
4. 测试失败后将日志反馈给 Developer Agent；
5. 可配置 Reviewer Agent 通过独立 Review Contract 审查变更；
6. Validation、Review 和 Cleanup 共同形成最终质量门禁；
7. Git 保存每一步修改。

每次运行拥有独立 `RunId`，权威状态和 append-only 轨迹位于
`automation/runs/<RunId>/`。可使用 `-ResumeRunId <RunId>` 在 Task、Config、
branch、HEAD 和 workspace fingerprint 均匹配时安全恢复；latest report 仅供
查看，不是恢复依据。

本项目使用模拟数据，不连接正式小程序、真实数据库或付费 API。

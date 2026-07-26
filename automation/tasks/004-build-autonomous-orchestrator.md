# 任务 004：构建 Codex 自动开发与验收修复总控脚本 V1

## 一、目标

创建总控脚本：

automation/run_autonomous_task.ps1

该脚本负责自动完成：

1. 读取指定任务文件；
2. 调用 Codex 执行开发；
3. 在宿主机运行独立验收脚本；
4. 验收失败时读取真实失败报告；
5. 将失败证据交给 Codex进行修复；
6. 重复验收和修复，直到成功或达到最大次数；
7. 生成完整的自动化运行报告；
8. 保留最终 Git 修改，等待人工确认；
9. 不自动提交或推送代码。

本任务只实现 Codex 开发与自动修复闭环。

Claude Code 独立审查将在后续任务中接入。

## 二、允许修改范围

- automation/run_autonomous_task.ps1
- automation/reports/**
- README.md

## 三、禁止修改范围

- backend/**
- frontend/**
- tests/**
- docker-compose.yml
- requirements.txt
- AGENTS.md
- docs/**
- automation/tasks/**
- automation/run_validation.ps1
- automation/test_validation_failure.ps1
- 当前 Git 分支
- 项目目录之外的文件

## 四、脚本参数

脚本至少支持：

### TaskFile

必填。

示例：

automation/tasks/005-example-task.md

要求：

- 必须存在；
- 必须位于当前项目目录内；
- 默认应位于 automation/tasks 目录；
- 不允许读取仓库外路径。

### MaxAttempts

可选。

- 默认值：3；
- 最小值：1；
- 最大值：5；
- 表示 Codex 开发或修复的最大调用次数。

## 五、执行前检查

1. 确认当前目录是项目根目录；
2. 确认存在：
   - AGENTS.md
   - automation/run_validation.ps1
   - 指定任务文件
3. 确认以下命令可用：
   - git
   - codex
   - powershell.exe
   - docker
4. 确认当前 Git 工作区干净；
5. 记录：
   - 当前分支
   - 当前 HEAD commit
   - 初始 Git 状态
   - 开始时间
6. 如果工作区不干净，立即终止，不得覆盖已有修改。

## 六、第一次 Codex 调用

第一次调用 Codex 时，Prompt 必须要求其：

1. 完整读取：
   - AGENTS.md
   - 指定任务文件
   - 与任务相关的现有代码
2. 严格执行任务文件；
3. 遵守允许和禁止修改范围；
4. 不运行 Docker；
5. 不执行 Git 写操作；
6. 不提交代码；
7. 可以执行不依赖 Docker 的静态检查；
8. 最终输出中文总结。

Codex 必须使用：

codex exec --sandbox workspace-write

## 七、宿主机验收

Codex 调用结束后，总控脚本必须在宿主机运行：

powershell.exe -NoProfile -ExecutionPolicy Bypass -File automation/run_validation.ps1

要求：

1. 使用独立子进程；
2. 使用 Process.ExitCode 获取退出码；
3. 不允许 Codex代替宿主机运行 Docker 验收；
4. 验收日志正常显示；
5. 验收成功退出码必须为 0；
6. 验收失败退出码必须非 0。

## 八、失败自动修复

如果验收失败：

1. 立即读取：
   automation/reports/validation-latest.txt
2. 保存本次失败报告；
3. 再次调用 Codex；
4. 修复 Prompt 必须包含：
   - 原任务文件路径；
   - 当前是第几次修复；
   - 上一次验收报告全文；
   - 当前 Git 修改文件列表；
   - 禁止扩大修改范围；
   - 只修复报告中的真实问题；
   - 不得运行 Docker；
   - 不得提交代码；
5. Codex 修复结束后，再次运行宿主机验收；
6. 重复直到：
   - 验收通过；或
   - 达到 MaxAttempts。

不得在没有运行真实验收的情况下认定修复成功。

## 九、Codex 调用失败

如果 Codex 进程本身返回非 0：

1. 记录 Codex 退出码；
2. 保存标准输出和错误输出；
3. 不运行下一次验收；
4. 如果仍有剩余次数，可以再次调用 Codex；
5. 达到最大次数后终止；
6. 最终结果必须为失败。

## 十、报告文件

总控脚本必须生成：

automation/reports/autonomous-latest.txt

报告至少包含：

1. 项目根目录；
2. 任务文件；
3. 当前分支；
4. 初始 commit；
5. 开始和结束时间；
6. MaxAttempts；
7. 每次 Codex 调用：
   - 调用类型：开发或修复
   - 开始和结束时间
   - 退出码
   - 日志文件路径
8. 每次验收：
   - 退出码
   - PASSED 或 FAILED
   - validation-latest.txt 的快照路径
9. 最终 Git 修改文件列表；
10. 最终 Docker 状态；
11. 最终结论；
12. 下一步需要人工完成的操作。

每次 Codex 调用日志保存为：

automation/reports/current-codex-attempt-01.log
automation/reports/current-codex-attempt-02.log

每次验收报告快照保存为：

automation/reports/current-validation-attempt-01.txt
automation/reports/current-validation-attempt-02.txt

## 十一、最终结果

### 成功

如果最终验收通过：

输出：

AUTONOMOUS TASK PASSED

退出码：

0

并明确提示：

- 代码尚未提交；
- 需要人工查看 Git diff；
- 后续还需 Claude Code 独立审查。

### 失败

如果达到最大次数仍未通过：

输出：

AUTONOMOUS TASK FAILED

退出码必须非 0。

并保留：

- 当前代码修改；
- 所有 Codex 日志；
- 所有验收报告；
- 最终失败原因。

## 十二、安全要求

1. 必须兼容 Windows PowerShell 5.1；
2. 必须使用 try / catch / finally；
3. finally 中执行 docker compose down；
4. 不得执行：
   - git add
   - git commit
   - git push
   - git reset
   - git restore
   - git checkout
   - git clean
5. 不得自动删除 Codex 产生的代码；
6. 不得删除 Docker 镜像；
7. 不得执行 docker system prune；
8. 不得修改当前分支；
9. 不得访问仓库外文件；
10. 不得调用外部业务 API；
11. 必须设置最大重试次数，禁止无限循环；
12. Codex 输出不能作为成功依据，必须以独立验收退出码为准。

## 十三、本任务的静态验收

Codex 完成本任务时：

1. 不得真实运行总控脚本；
2. 不得调用 Codex 子进程；
3. 不得运行 Docker；
4. 只进行：
   - Windows PowerShell 5.1 语法解析；
   - 参数和路径逻辑静态检查；
   - Git 修改范围检查。

## 十四、完成标准

1. 总控脚本能够接收任务文件；
2. 能调用 Codex；
3. 能在宿主机独立运行验收；
4. 能读取失败报告并调用 Codex 修复；
5. 有最大重试次数；
6. 能生成完整报告；
7. 不执行任何 Git 写操作；
8. 成功和失败均有明确退出码；
9. PowerShell 5.1 语法检查通过；
10. 不修改现有产品和验收代码。

Codex 不得自行提交代码。

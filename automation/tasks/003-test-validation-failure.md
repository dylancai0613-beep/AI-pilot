# 任务 003：验证自动验收脚本的失败检测能力

## 一、目标

创建一个安全、可恢复的故障注入脚本：

automation/test_validation_failure.ps1

该脚本用于证明：

1. 项目正常时，run_validation.ps1 返回成功；
2. 人为制造可控故障后，run_validation.ps1 返回失败；
3. 失败报告能够指出真实错误；
4. 故障文件能够自动恢复；
5. 恢复后再次运行验收能够通过；
6. 最终 Git 工作区不遗留业务代码修改。

## 二、允许修改范围

- automation/test_validation_failure.ps1
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
- 当前 Git 分支
- 项目目录之外的文件

## 四、故障注入方式

脚本执行期间可以临时修改：

frontend/index.html

但必须满足：

1. 开始前将原文件内容完整保存在内存中；
2. 不创建仓库外备份文件；
3. 临时删除首页中 id="results" 的元素标识；
4. 运行 automation/run_validation.ps1；
5. 预期验收返回非 0；
6. 预期报告中包含首页缺少必需元素的错误；
7. 在 finally 中无条件恢复 frontend/index.html 原始内容；
8. 恢复后再次运行 run_validation.ps1；
9. 恢复后的验收必须返回 0；
10. 最终确认 frontend/index.html 与执行前完全一致。

## 五、执行流程

1. 确认当前目录为项目根目录；
2. 确认 Git 工作区在执行前干净；
3. 读取 frontend/index.html 原始字节；
4. 运行正常验收，必须通过；
5. 注入首页元素缺失故障；
6. 运行验收，必须失败；
7. 检查失败报告：
   automation/reports/validation-latest.txt
8. 报告必须包含：
   - VALIDATION FAILED
   - The homepage is missing required element
   - id="results"
9. 恢复原始文件；
10. 再次运行正常验收，必须通过；
11. 检查 Docker 容器已停止；
12. 检查 Git 工作区无 backend、frontend、tests 等业务文件修改；
13. 输出测试总结。

## 六、退出码要求

全部预期行为满足时：

- 输出：
  FAILURE PATH TEST PASSED
- 退出码为 0。

任何步骤不符合预期时：

- 输出：
  FAILURE PATH TEST FAILED
- 退出码非 0。

## 七、安全要求

1. 必须使用 try / catch / finally；
2. finally 必须恢复 frontend/index.html；
3. finally 必须执行 docker compose down；
4. 不得执行 git reset、git checkout、git clean；
5. 不得执行 git add、git commit 或 git push；
6. 不得删除 Docker 镜像；
7. 不得调用外部 API；
8. 不得依赖管理员权限；
9. 必须兼容 Windows PowerShell 5.1；
10. 即使中途失败，也不得留下被修改的网页文件。

## 八、完成标准

1. 正常状态验收通过；
2. 故障状态验收失败；
3. 失败报告准确指出首页元素缺失；
4. 文件自动恢复；
5. 恢复后验收再次通过；
6. 最终 Docker 无项目容器；
7. 最终业务代码无修改；
8. 输出明确结果和退出码。

Codex 不得自行执行 Git 提交。

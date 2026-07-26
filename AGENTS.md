# AGENTS.md

## 项目目的

本项目仅用于测试 AI 自动开发、自动测试和自动修复流程。

## 工作范围

AI 只能读取和修改当前 Git 仓库：

D:\AI-Pilot\travel-cost-pilot

禁止读取、修改或删除该目录之外的任何文件。

## 必须遵守的规则

1. 每次只执行当前指定的一个任务。
2. 不得擅自扩大任务范围。
3. 修改完成后必须运行对应测试。
4. 测试失败时不得声明任务完成。
5. 不得使用假测试掩盖真实错误。
6. 不得删除已有测试来让测试通过。
7. 不得吞掉异常或用空 catch 隐藏错误。
8. 不得修改 main 分支。
9. 不得执行 git push。
10. 不得执行 git reset --hard。
11. 不得执行 git clean -fd。
12. 不得执行 docker system prune。
13. 不得安装全局软件或全局依赖。
14. 不得读取或创建真实密钥、密码或 Token。
15. 不得访问正式小程序目录。
16. 不得自动发布或部署任何程序。
17. 遇到不确定的产品决策时必须停止并记录问题。
18. 每个任务必须生成修改说明和测试结果。

## 允许的技术范围

- Python
- FastAPI
- HTML
- CSS
- JavaScript
- Pytest
- Playwright
- Docker
- Docker Compose

不使用 Java，不连接真实数据库，不调用外部付费 API。

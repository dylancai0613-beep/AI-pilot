# 任务 002：建立一键自动验收脚本

## 一、目标

创建一个 PowerShell 自动验收脚本：

automation/run_validation.ps1

执行一次脚本后，自动验证当前项目是否能够正常构建、启动、测试和响应请求。

## 二、允许修改范围

- automation/run_validation.ps1
- automation/reports/**
- README.md
- tests/**

## 三、禁止修改范围

- backend/**
- frontend/**
- docker-compose.yml
- requirements.txt
- AGENTS.md
- docs/**
- automation/tasks/**
- 当前 Git 分支
- 项目目录之外的文件

## 四、脚本执行流程

脚本必须按以下顺序执行：

1. 确认当前工作目录是项目根目录；
2. 检查 Docker 是否可用；
3. 检查 docker compose 是否可用；
4. 记录当前 Git 状态；
5. 执行：
   docker compose down
6. 执行：
   docker compose up --build -d
7. 最多等待 60 秒，检查 app 容器是否进入 healthy 状态；
8. 执行：
   docker compose exec app pytest -q
9. 请求：
   GET http://127.0.0.1:8000/health
10. 请求：
    GET http://127.0.0.1:8000/
11. 使用 UTF-8 请求：
    POST http://127.0.0.1:8000/api/compare
12. 请求参数固定为：
    - origin：广州
    - destination：深圳
    - passengers：2
13. 验证返回结果中存在：
    - 高铁
    - 长途汽车
    - 网约车
14. 验证金额和耗时：
    - 高铁：160 元、60 分钟
    - 长途汽车：130 元、150 分钟
    - 网约车：360 元、120 分钟
15. 读取最近 200 行 Docker 日志；
16. 检查日志中是否存在：
    - Traceback
    - ERROR
    - FATAL
    - Exception
17. 输出完整验收报告；
18. 无论成功或失败，最后都执行：
    docker compose down

## 五、验收结果

成功时：

- PowerShell 退出码为 0；
- 控制台明确输出：
  VALIDATION PASSED
- 报告写入：
  automation/reports/validation-latest.txt

失败时：

- PowerShell 退出码必须为非 0；
- 控制台明确输出：
  VALIDATION FAILED
- 报告必须记录：
  - 失败步骤；
  - 执行命令；
  - 错误信息；
  - Docker 状态；
  - 最近日志。

## 六、安全要求

1. 不得执行 git add、git commit、git push；
2. 不得删除 Git 文件；
3. 不得执行 docker system prune；
4. 不得删除 Docker 镜像；
5. 不得修改项目业务代码；
6. 不得吞掉错误；
7. 必须使用 try / catch / finally；
8. finally 中必须关闭本项目容器；
9. 不得依赖管理员权限；
10. 不得调用外部网络 API。

## 七、兼容性要求

- 必须兼容 Windows PowerShell 5.1；
- 中文 JSON 请求和响应必须显式使用 UTF-8；
- 不依赖 PowerShell 7；
- 不安装额外全局软件；
- 不要求用户修改系统环境变量。

## 八、完成标准

只有同时满足以下条件才算完成：

1. 脚本能够从容器停止状态开始运行；
2. 自动构建并启动项目；
3. 自动等待健康状态；
4. 自动运行 9 项 Pytest；
5. 自动验证首页；
6. 自动验证真实中文接口请求；
7. 自动扫描日志；
8. 自动生成报告；
9. 成功时返回退出码 0；
10. 失败时返回非 0；
11. 结束后容器已停止；
12. 不存在范围外修改。

Codex 不得自行执行 Git 提交。

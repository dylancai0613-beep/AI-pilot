# 任务 001：建立最小可运行应用

## 一、目标

建立一个能够通过 Docker Compose 启动的最小应用，包含：

1. FastAPI 后端；
2. 简单网页；
3. 健康检查接口；
4. 交通成本比较接口；
5. 基础后端测试。

## 二、允许修改的范围

- backend/**
- frontend/**
- tests/**
- docker-compose.yml
- requirements.txt
- README.md

## 三、禁止修改的范围

- AGENTS.md
- docs/PRODUCT_SPEC.md
- automation/tasks/001-build-mvp.md
- 当前 Git 分支
- 项目目录之外的任何文件

## 四、具体要求

### 后端接口

实现：

GET /health

返回：

{
  "status": "ok"
}

实现：

POST /api/compare

请求示例：

{
  "origin": "广州",
  "destination": "深圳",
  "passengers": 2
}

返回三种方案：

- 高铁
- 长途汽车
- 网约车

每种方案必须包含：

- mode
- total_cost
- per_person_cost
- duration_minutes
- tag

### 前端页面

页面包含：

- 出发城市选择
- 目的城市选择
- 出行人数选择
- 查询按钮
- 查询结果区域
- 错误信息区域

页面必须通过后端接口获取查询结果，不得在前端重复编写价格计算逻辑。

### 输入校验

- 出发地和目的地不能相同
- 人数只能是 1 至 4
- 错误请求返回清晰的 4xx 响应
- 前端显示后端返回的错误信息

## 五、测试要求

至少测试：

1. GET /health 正常返回；
2. 广州到深圳、2 人查询成功；
3. 出发地和目的地相同时返回错误；
4. 人数超过 4 时返回错误。

## 六、Docker 要求

执行以下命令后，程序必须能够启动：

docker compose up --build -d

启动后：

- http://127.0.0.1:8000/health 可以访问
- http://127.0.0.1:8000 可以打开网页

停止命令：

docker compose down

## 七、完成标准

只有同时满足以下条件才算完成：

1. Docker 构建成功；
2. 容器启动后持续运行；
3. 健康检查通过；
4. Pytest 全部通过；
5. 首页能够访问；
6. Git 工作区不存在范围外修改；
7. 输出完整的修改文件清单和测试结果。

不得自行执行 git commit。

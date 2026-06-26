# 公司内网 MCP + Hive 自然语言查询技术方案

## 1. 背景与目标

### 1.1 当前资产

当前数据资产集中在公司 Linux 内网服务器和公司 Hive 集群中：

- 数据仓库完整 DDL、DML、ETL 代码。
- 境内、境外各十几张 SLA 关键结果表，作为自然语言查询的优先数据源。
- 境内、境外用户画像数据资产。
- HiveServer2 / Yarn 作为主要 SQL 查询和执行资源。
- 客户在个人电脑上使用 Codex 或其他 MCP 客户端，例如 Hermes、Trea，通过自然语言发起数据查询。

### 1.2 建设目标

建设一个部署在公司内网服务器上的 MCP 查询服务，实现：

- Codex 等客户端可以读取数仓代码、DDL、DML、关键表说明和用户画像资产。
- 用户输入自然语言后，AI 先检索资产上下文，再生成 Hive SQL。
- MCP 服务连接 Hive 执行受控 SQL，返回结果集给客户端。
- Hive 连接地址内置在服务端，用户名和密码由客户每次登录或会话建立时输入。
- 控制对 HiveServer2、Yarn、Git/代码资产的访问强度，避免刷库、刷队列、刷代码仓库。
- MCP 服务只在每天 12:00 到次日 01:00 对外提供查询服务，其他时间让位给数仓调度。
- MCP 服务需要健康检测和自动拉起能力。

### 1.3 选型约束

你们当前使用 Google 的 MCP Toolbox：

- GitHub: https://github.com/googleapis/mcp-toolbox
- MCP Toolbox 是面向数据库的 MCP Server，可通过 `tools.yaml` 定义 source、tool、toolset、prompt。
- 官方 README 显示它支持开箱即用数据库工具、定制工具框架、HTTP MCP 接入、工具集加载、OpenTelemetry 监控等能力。
- 官方支持的常见数据库包括 PostgreSQL、MySQL、Oracle、ClickHouse、Snowflake、Trino 等；未明确把 HiveServer2 作为一等 source。因此本方案不假设它能直接原生连接 HiveServer2。

结论：推荐采用 **MCP Toolbox + Python Hive Query Gateway** 的组合架构。

## 2. 总体架构

### 2.1 推荐架构

```text
个人电脑
  └─ Codex / Hermes / Trea / Claude Code / 其他 MCP Client
       ↓ HTTP MCP
公司内网 MCP Toolbox Server
  ├─ 工具集：资产检索工具
  ├─ 工具集：SQL 生成上下文工具
  ├─ 工具集：受控 SQL 执行工具
  └─ 转发/调用 Python Hive Query Gateway
       ↓
Python Hive Query Gateway
  ├─ 用户登录与会话凭据管理
  ├─ SQL 安全校验
  ├─ 并发控制、超时控制、结果集控制
  ├─ HiveServer2 查询执行
  ├─ Yarn application 监控和查杀
  ├─ ETL 代码 / DDL / DML / 资产索引检索
  └─ 审计日志 / 指标 / 告警
       ↓
公司内网资源
  ├─ HiveServer2
  ├─ Yarn ResourceManager
  ├─ Git / 本地代码镜像
  ├─ DDL / DML / ETL 目录
  ├─ SLA 关键结果表清单
  └─ 用户画像资产文档
```

### 2.2 为什么不建议个人电脑直连 Hive

不建议每个客户本机各自部署 MCP Server 并直连 Hive：

- Hive 地址、用户名密码、Kerberos/JDBC/PyHive 依赖会分散到个人电脑。
- 权限、审计、限流、脱敏无法统一。
- 每个人本地配置不一致，运维成本高。
- 无法集中控制 HiveServer2 和 Yarn 压力。
- 查询结果和中间凭据更容易泄露。

推荐把真实数据访问边界收敛在内网服务器上，个人电脑只访问 MCP HTTP endpoint。

## 3. 核心模块设计

### 3.1 MCP Toolbox 层

MCP Toolbox 作为统一 MCP 入口，负责：

- 向 Codex 等客户端暴露标准 MCP tools。
- 组织 toolset，例如 `asset_context`、`hive_query`、`admin_health`。
- 暴露 HTTP MCP endpoint，例如：

```text
http://mcp-hive.internal:5000/mcp
http://mcp-hive.internal:5000/mcp/hive_query
```

MCP Toolbox 不直接承担复杂 Hive 安全逻辑。它应尽量薄，复杂逻辑放到 Python Gateway。

### 3.2 Python Hive Query Gateway

Python Gateway 是业务核心，建议用 FastAPI 实现。它负责：

- 用户登录认证。
- Hive 用户名密码临时会话保存。
- 资产索引检索。
- 自然语言查询上下文组装。
- SQL 安全校验。
- SQL 执行。
- Yarn application 管理。
- 审计和监控。

推荐内部 API：

```text
POST /api/login
POST /api/logout
GET  /api/health
GET  /api/assets/search
GET  /api/assets/table/{db}/{table}
POST /api/sql/validate
POST /api/sql/execute
POST /api/sql/explain
GET  /api/query/{query_id}
POST /api/admin/kill-timeout-queries
```

MCP Toolbox 暴露给 AI 的 tool 调用这些内部 API。

### 3.3 资产索引层

资产包括：

- DDL：建表语句、字段类型、分区字段、表注释、字段注释。
- DML / ETL：表产出逻辑、依赖表、过滤条件、口径计算。
- SLA 关键结果表：境内、境外各十几张，查询优先使用。
- 用户画像资产：境内、境外画像标签、标签口径、更新频率、敏感等级。

DDL、DML、用户画像资产可以直接在配置文件中以服务器目录形式配置；SLA 关键结果表建议继续用 JSON 精确维护。服务在线检索时可以递归扫描配置目录，但必须做文件大小限制、片段截断和缓存，避免用户每次提问都刷 Git 或全量代码目录。生产高并发阶段建议每日数仓调度结束后构建本地索引。

```text
/data/mcp_hive_assets/
  ├─ raw_repo/                  # 只读代码镜像
  ├─ parsed/
  │   ├─ tables.jsonl
  │   ├─ columns.jsonl
  │   ├─ etl_lineage.jsonl
  │   ├─ sla_tables.json
  │   └─ profile_assets.json
  └─ index/
      ├─ keyword.sqlite
      └─ vector_index/          # 可选，后续增强语义检索
```

第一期建议先做关键词检索 + 元数据结构化检索，不必一开始引入向量库。

目录配置示例：

```yaml
assets:
  ddl_dirs:
    - "/home/dev/51dolphin_git/dolphinscheduler_ddl"
    - "/home/dev/51dolphin_git/ovs_dolphinscheduler_ddl/ovs_hive_ddl"
  dml_dirs:
    - "/home/dev/51dolphin_git/dolphinscheduler_code"
    - "/home/dev/51dolphin_git/ovs_dolphinscheduler_code"
  profile_dirs:
    - "/home/dev/51dolphin_git/lingyun_code"
  sla_table_file: "/opt/mcp-hive/assets/parsed/sla_tables.json"
  scan_extensions:
    - ".sql"
    - ".sh"
    - ".md"
    - ".txt"
    - ".json"
  max_file_bytes: 1048576
  max_snippet_chars: 4000
  directory_cache_ttl_seconds: 300
```

### 3.4 Hive 查询执行层

推荐 Python 侧通过 PyHive / JayDeBeApi / impyla 连接 HiveServer2，具体取决于公司现有认证方式。

如果已有 Trino / Presto 查询入口，优先考虑接 Trino / Presto：

- 交互式查询体验通常好于 HiveServer2。
- Google MCP Toolbox 官方 README 明确列出了 Trino 支持。
- 可以减少自研 Hive source 的成本。

如果必须走 HiveServer2，则使用 Python Gateway 自行封装 Hive 查询，并由 MCP Toolbox 调 Gateway。

## 4. 数据流设计

### 4.1 用户登录数据流

```text
客户在 Codex / 客户端输入 Hive 用户名密码
  ↓
MCP tool: login_hive(username, password)
  ↓
MCP Toolbox
  ↓
Python Gateway /api/login
  ↓
验证 HiveServer2 连接
  ↓
生成 session_id
  ↓
凭据只保存在服务端内存或 Redis，设置 TTL
  ↓
返回登录成功状态给客户端
```

要求：

- Hive 地址、端口、默认库、队列名配置在服务端，不暴露给客户端。
- 用户名密码不写入日志。
- session 默认 TTL 建议 2 小时，最长不超过服务开放窗口。
- 支持用户主动 logout 清除凭据。

### 4.2 自然语言查询数据流

```text
用户：查询境内 6 月高价值用户画像分布
  ↓
Codex 判断需要调用 MCP
  ↓
search_assets("境内 6 月 高价值 用户画像")
  ↓
返回候选 SLA 表、画像表、字段、口径、ETL 片段
  ↓
Codex 基于上下文生成 Hive SQL
  ↓
validate_hive_sql(sql)
  ↓
execute_hive_select(sql, limit, timeout)
  ↓
Python Gateway 连接 HiveServer2 执行
  ↓
轮询状态，监控 Yarn application
  ↓
返回字段、行数据、统计信息、query_id
  ↓
Codex 汇总成自然语言结论
```

### 4.3 查询优先级策略

自然语言转 SQL 时按以下优先级选择数据源：

1. 境内/境外 SLA 关键结果表。
2. 境内/境外用户画像宽表或标签表。
3. 已有 ADS / DWS 汇总层表。
4. DWD 明细表。
5. ODS 原始表，默认不推荐，除非用户明确要求。

MCP 工具返回上下文时应标记表优先级：

```json
{
  "table": "ads_cn_user_profile_sla_di",
  "domain": "cn",
  "priority": "P0",
  "asset_type": "sla_result_table",
  "recommended": true
}
```

## 5. MCP 工具设计

### 5.1 toolset 划分

```text
asset_context
  - search_assets
  - get_table_schema
  - get_table_ddl
  - get_etl_logic
  - get_sla_tables
  - get_profile_assets

hive_query
  - login_hive
  - logout_hive
  - validate_hive_sql
  - explain_hive_sql
  - execute_hive_select
  - get_query_status

admin_health
  - get_service_status
  - get_current_limits
```

### 5.2 面向 AI 的工具说明原则

Tool description 要明确告诉模型：

- 优先查询 SLA 关键结果表。
- SQL 只能是 SELECT / WITH SELECT。
- 必须先检索资产和表结构，再生成 SQL。
- 不要访问未出现在资产检索结果中的表。
- 默认必须带分区过滤。
- 默认必须带 LIMIT。
- 画像敏感字段不能直接返回明文。

### 5.3 示例工具定义

如果 MCP Toolbox 支持 HTTP/OpenAPI 类型工具，可直接把这些 API 包成 tool。如果当前版本不支持 HTTP 类型工具，则建议：

- 方案 A：用 MCP Toolbox 连接 Trino，Python Gateway 只做资产检索和安全校验。
- 方案 B：用 Python FastMCP 实现 Hive MCP Server，和 MCP Toolbox 并行部署。
- 方案 C：扩展 MCP Toolbox 自定义 source/tool，增加 Hive Gateway 调用能力。

从实施风险看，推荐 **方案 B 起步，方案 C 后续融合**。即先用 Python 实现完整可控能力，保留 MCP Toolbox 作为数据库 MCP 标准入口和后续统一入口。

## 6. 自然语言转 SQL 方案

### 6.1 责任边界

自然语言转 SQL 不建议完全放在 MCP Server 内部。更合理的分工：

- Codex / 客户端模型：负责理解用户问题、调用工具、生成 SQL 草案、解释结果。
- MCP Server：负责提供资产上下文、校验 SQL、执行 SQL、返回结果。
- Python Gateway：负责 SQL 安全和资源控制，不信任模型生成的 SQL。

这样可以兼容 Codex、Hermes、Trea 等不同客户端。

### 6.2 推荐提示词约束

在 MCP prompt 或客户端系统提示中加入：

```text
你是公司数仓查询助手。回答数据问题时必须：
1. 先调用 search_assets 检索相关表和口径。
2. 优先使用 SLA 关键结果表，其次用户画像表，再考虑汇总层和明细层。
3. 生成 Hive SQL 前必须调用 get_table_schema 或 get_table_ddl。
4. SQL 只能是 SELECT 或 WITH SELECT。
5. 必须带业务日期或分区过滤条件。
6. 默认 LIMIT 不超过 1000。
7. 不返回手机号、身份证、邮箱、设备号等敏感字段明文。
8. SQL 执行失败时，先根据错误修正 SQL，不要重复提交同一条 SQL。
```

### 6.3 SQL 生成上下文格式

资产工具返回给模型的上下文建议结构化：

```json
{
  "business_question": "境内 6 月高价值用户画像分布",
  "recommended_tables": [
    {
      "db": "ads",
      "table": "ads_cn_user_profile_sla_di",
      "reason": "境内用户画像 SLA 结果表，优先使用",
      "partition_columns": ["dt"],
      "sensitive_columns": ["user_id", "phone_hash"],
      "columns": [
        {"name": "dt", "type": "string", "comment": "业务日期"},
        {"name": "user_level", "type": "string", "comment": "用户价值分层"},
        {"name": "profile_tag", "type": "string", "comment": "画像标签"}
      ]
    }
  ],
  "sql_constraints": {
    "only_select": true,
    "require_limit": true,
    "max_limit": 1000,
    "require_partition_filter": true
  }
}
```

## 7. 安全与资源控制

### 7.1 防止刷 HiveServer2

控制点：

- 全局并发：例如最多 20 个活跃查询。
- 单用户并发：例如最多 2 个活跃查询。
- 单用户 QPS：例如 10 秒内最多提交 3 次。
- 连接池大小：例如 Hive 连接池最大 20。
- 查询队列：超过并发时排队或拒绝。
- SQL 去重：短时间内同一用户提交同一 SQL 直接返回已有 query_id 或拒绝。
- 失败重试限制：同一 SQL 不允许连续重试超过 2 次。

建议默认值：

```yaml
limits:
  global_concurrency: 20
  per_user_concurrency: 2
  per_user_submit_per_minute: 6
  default_limit: 500
  max_limit: 1000
  max_result_bytes: 10MB
  max_sql_length: 20000
  query_timeout_seconds: 300
```

### 7.2 控制返回结果集

SQL 执行前：

- 如果 SQL 没有 LIMIT，自动包一层：

```sql
SELECT * FROM (
  <original_select_sql>
) t
LIMIT 500
```

- 如果 LIMIT 超过最大值，改写为最大值或拒绝。
- 对结果集做最大行数、最大字节数限制。

SQL 返回时：

```json
{
  "query_id": "q_20260626_120001_abcd",
  "columns": ["dt", "user_level", "cnt"],
  "rows": [
    ["2026-06-01", "high", 12345]
  ],
  "row_count": 100,
  "truncated": false,
  "limit": 500,
  "elapsed_ms": 8321
}
```

### 7.3 防止刷 Yarn

控制点：

- 每个 SQL 设置 timeout。
- 查询启动后记录 Hive query id、Yarn application id。
- 定时扫描运行中的查询。
- 超时后先 cancel Hive operation，再调用 Yarn kill application。
- 非服务时间窗口强制拒绝新查询，并可选择查杀 MCP 提交的未完成查询。

建议定时任务：

```text
每 30 秒：
  - 扫描 active_queries
  - now - start_time > query_timeout_seconds 时 cancel
  - cancel 失败时 yarn application -kill
  - 写审计日志
```

### 7.4 防止刷 Git / 代码资产

不建议每次用户提问都实时扫 Git。推荐：

- 服务器上维护只读代码镜像。
- 定时 `git pull --ff-only`，例如每天 01:30 调度结束后。
- 解析 DDL、DML、ETL 生成结构化索引。
- 在线查询只读索引，不直接大范围 grep Git。

限制：

- `search_assets` 返回最多 20 条资产。
- `get_etl_logic` 返回最多 N KB 代码片段。
- SQL / 关键词长度限制，例如 20000 字符。
- 单用户资产检索频率限制。

用户提到的“限制执行 SQL 长度”应放在 SQL 校验层，不直接等同 Git 限制；Git 侧主要限制代码读取范围和检索频次。

### 7.5 SQL 安全校验

必须拒绝：

- `INSERT`
- `OVERWRITE`
- `DROP`
- `ALTER`
- `CREATE`
- `TRUNCATE`
- `DELETE`
- `UPDATE`
- `MSCK`
- `LOAD DATA`
- `ADD JAR`
- `TRANSFORM`
- 多语句 SQL
- 访问黑名单库表

建议要求：

- 只允许 `SELECT` 或 `WITH ... SELECT`。
- 必须有分区过滤，例如 `dt` / `biz_date`。
- 默认必须 LIMIT。
- 不允许 `SELECT *` 查询大表，除非外层强制 LIMIT 且表在白名单。
- 敏感字段默认拒绝返回或脱敏。

推荐使用 `sqlglot` 做 SQL AST 解析，避免只靠字符串匹配。

## 8. 服务时间窗口与自动拉起

### 8.1 服务窗口

服务对外开放时间：

```text
每天 12:00 到次日 01:00
```

策略：

- 12:00 启动或允许查询。
- 01:00 停止接受新查询。
- 01:00 后等待宽限期，例如 10 分钟。
- 超过宽限期仍未完成的 MCP 查询由 Gateway 查杀。
- 01:10 后完全让位给数仓调度。

### 8.2 systemd 部署建议

推荐把 Python Gateway 和 MCP Toolbox 分成两个 systemd 服务：

```text
mcp-hive-gateway.service
mcp-toolbox.service
```

通过 systemd timer 控制启停：

```text
mcp-hive-start.timer  每天 12:00 start
mcp-hive-stop.timer   每天 01:00 stop 或切 readonly/closed mode
```

`Restart=always` 负责服务窗口内自动拉起。

Gateway 内部还要检查当前时间。如果服务被误启动在非服务窗口，也应拒绝执行 SQL。

### 8.3 健康检测

健康检测分三层：

```text
L1: 进程存活
L2: /api/health 返回正常
L3: HiveServer2 轻量探活，例如 SELECT 1
```

探活频率：

- 进程级：systemd 持续守护。
- HTTP 级：Nginx / Prometheus 每 30 秒。
- Hive 级：每 5 分钟，避免探活本身刷 Hive。

## 9. 部署方案

### 9.1 推荐目录

```text
/opt/mcp-hive/
  ├─ gateway/
  │   ├─ app.py
  │   ├─ config.yaml
  │   ├─ requirements.txt
  │   └─ sql_guard.py
  ├─ toolbox/
  │   ├─ toolbox
  │   └─ tools.yaml
  ├─ assets/
  │   ├─ raw_repo/
  │   ├─ parsed/
  │   └─ index/
  ├─ logs/
  └─ scripts/
      ├─ refresh_assets.sh
      ├─ kill_timeout_queries.sh
      └─ healthcheck.sh
```

### 9.2 配置文件

`config.yaml` 示例：

```yaml
server:
  host: 0.0.0.0
  port: 8088
  service_window:
    start: "12:00"
    end: "01:00"
    timezone: "Asia/Shanghai"
  session_ttl_seconds: 7200

hive:
  host: "hiveserver2.internal"
  port: 10000
  auth: "LDAP"
  database: "default"
  queue: "ai_mcp_query"
  connect_timeout_seconds: 10
  query_timeout_seconds: 300

limits:
  global_concurrency: 20
  per_user_concurrency: 2
  per_user_submit_per_minute: 6
  default_limit: 500
  max_limit: 1000
  max_result_bytes: 10485760
  max_sql_length: 20000
  max_asset_hits: 20

assets:
  ddl_dirs:
    - "/home/dev/51dolphin_git/dolphinscheduler_ddl"
    - "/home/dev/51dolphin_git/ovs_dolphinscheduler_ddl/ovs_hive_ddl"
  dml_dirs:
    - "/home/dev/51dolphin_git/dolphinscheduler_code"
    - "/home/dev/51dolphin_git/ovs_dolphinscheduler_code"
  profile_dirs:
    - "/home/dev/51dolphin_git/lingyun_code"
  scan_extensions:
    - ".sql"
    - ".sh"
    - ".md"
    - ".txt"
    - ".json"
  max_file_bytes: 1048576
  max_snippet_chars: 4000
  directory_cache_ttl_seconds: 300
  repo_path: "/opt/mcp-hive/assets/raw_repo"
  parsed_path: "/opt/mcp-hive/assets/parsed"
  index_path: "/opt/mcp-hive/assets/index"
  sla_table_file: "/opt/mcp-hive/assets/parsed/sla_tables.json"
  profile_asset_file: "/opt/mcp-hive/assets/parsed/profile_assets.json"

security:
  require_partition_filter: true
  sensitive_columns:
    - phone
    - mobile
    - id_card
    - email
    - device_id
    - imei
    - idfa
  blocked_databases:
    - ods_raw_sensitive
```

### 9.3 客户端接入

Codex 或其他 MCP Client 配置：

```json
{
  "mcpServers": {
    "company-hive": {
      "type": "http",
      "url": "http://mcp-hive.internal:5000/mcp/hive_query"
    }
  }
}
```

如果客户端和服务器跨网段，建议走：

```text
客户端 -> VPN/办公网 -> Nginx/API Gateway -> MCP Toolbox -> Gateway
```

## 10. Python Gateway 参考实现骨架

### 10.1 requirements.txt

```text
fastapi
uvicorn[standard]
pydantic
pyyaml
sqlglot
pyhive[hive]
thrift
requests
redis
```

如果公司 Hive 使用 Kerberos，需增加：

```text
pure-sasl
thrift-sasl
```

### 10.2 FastAPI 骨架

```python
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Any
import time
import uuid

app = FastAPI(title="MCP Hive Query Gateway")

SESSIONS: dict[str, dict[str, Any]] = {}
ACTIVE_QUERIES: dict[str, dict[str, Any]] = {}


class LoginRequest(BaseModel):
    username: str
    password: str


class SqlRequest(BaseModel):
    session_id: str
    sql: str
    limit: int | None = None
    timeout_seconds: int | None = None


@app.get("/api/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "ts": int(time.time())}


@app.post("/api/login")
def login(req: LoginRequest) -> dict[str, Any]:
    # TODO: use req.username / req.password to open a lightweight Hive connection.
    # Do not log password.
    session_id = uuid.uuid4().hex
    SESSIONS[session_id] = {
        "username": req.username,
        "password": req.password,
        "created_at": time.time(),
        "expires_at": time.time() + 7200,
    }
    return {"session_id": session_id, "expires_in": 7200}


@app.post("/api/sql/validate")
def validate_sql(req: SqlRequest) -> dict[str, Any]:
    session = SESSIONS.get(req.session_id)
    if not session:
        raise HTTPException(status_code=401, detail="invalid session")
    # TODO: sqlglot parse, only SELECT/WITH SELECT, limit, partition filter,
    # blocked keywords, blocked databases, sensitive columns.
    return {"valid": True, "normalized_sql": req.sql}


@app.post("/api/sql/execute")
def execute_sql(req: SqlRequest) -> dict[str, Any]:
    session = SESSIONS.get(req.session_id)
    if not session:
        raise HTTPException(status_code=401, detail="invalid session")
    # TODO:
    # 1. check service window
    # 2. check concurrency / rate limit
    # 3. validate SQL
    # 4. execute through HiveServer2
    # 5. fetch limited result set
    # 6. record audit log
    query_id = "q_" + uuid.uuid4().hex
    return {
        "query_id": query_id,
        "columns": [],
        "rows": [],
        "row_count": 0,
        "truncated": False,
        "elapsed_ms": 0,
    }
```

### 10.3 SQL Guard 示例

```python
import sqlglot
from sqlglot import exp

BLOCKED_KEYWORDS = {
    "insert", "overwrite", "drop", "alter", "create", "truncate",
    "delete", "update", "load", "msck", "add jar", "transform",
}


def validate_select_only(sql: str, max_sql_length: int) -> None:
    lowered = sql.lower()
    if len(sql) > max_sql_length:
        raise ValueError("SQL exceeds max length")
    if ";" in sql.strip().rstrip(";"):
        raise ValueError("Multiple statements are not allowed")
    for keyword in BLOCKED_KEYWORDS:
        if keyword in lowered:
            raise ValueError(f"Blocked SQL keyword: {keyword}")

    parsed = sqlglot.parse_one(sql, read="hive")
    if not isinstance(parsed, (exp.Select, exp.With)):
        raise ValueError("Only SELECT or WITH SELECT is allowed")


def ensure_limit(sql: str, default_limit: int, max_limit: int) -> str:
    parsed = sqlglot.parse_one(sql, read="hive")
    limit = parsed.args.get("limit")
    if limit is None:
        return f"SELECT * FROM ({sql}) mcp_limited_result LIMIT {default_limit}"
    # Production code should parse numeric limit and clamp it.
    return sql
```

### 10.4 Hive 执行示例

```python
from pyhive import hive


def run_hive_query(
    host: str,
    port: int,
    username: str,
    password: str,
    database: str,
    sql: str,
    max_rows: int,
) -> dict:
    conn = hive.Connection(
        host=host,
        port=port,
        username=username,
        password=password,
        database=database,
        auth="LDAP",
    )
    try:
        cursor = conn.cursor()
        cursor.execute(sql)
        columns = [desc[0] for desc in cursor.description or []]
        rows = cursor.fetchmany(max_rows)
        return {
            "columns": columns,
            "rows": rows,
            "row_count": len(rows),
            "truncated": len(rows) >= max_rows,
        }
    finally:
        conn.close()
```

## 11. 审计、监控与告警

### 11.1 审计日志

每次工具调用记录：

```json
{
  "ts": "2026-06-26T12:00:01+08:00",
  "user": "zhangsan",
  "client": "codex",
  "tool": "execute_hive_select",
  "query_id": "q_xxx",
  "sql_hash": "sha256:xxx",
  "sql_preview": "select dt, user_level, count(*) ...",
  "tables": ["ads.ads_cn_user_profile_sla_di"],
  "elapsed_ms": 8321,
  "row_count": 100,
  "status": "success",
  "yarn_application_id": "application_xxx"
}
```

注意：

- 不记录密码。
- 敏感字段值不进日志。
- SQL 全文可以单独落受控审计表，普通日志只放 preview + hash。

### 11.2 监控指标

核心指标：

- MCP tool 调用次数。
- SQL 执行次数、成功率、失败率。
- 当前活跃查询数。
- 单用户并发。
- Hive 查询耗时 P50/P90/P99。
- 超时查杀次数。
- Yarn kill 次数。
- 结果集截断次数。
- 非服务窗口拒绝次数。

### 11.3 告警

建议告警条件：

- Gateway 进程不可用超过 1 分钟。
- MCP Toolbox 不可用超过 1 分钟。
- Hive 探活连续失败 3 次。
- 当前活跃查询达到全局上限 80%。
- 10 分钟内 kill Yarn application 超过阈值。
- 单用户触发限流超过阈值。

## 12. 实施路线

### 第一期：资产上下文 + 只读 SQL 执行闭环

目标：可用、受控、能回答简单问题。

- 部署 Python Gateway。
- 实现登录、会话、Hive SELECT 执行。
- 实现 SQL 只读校验、LIMIT、超时。
- 整理 SLA 关键表清单和画像表清单。
- 构建 DDL / DML / ETL 结构化索引。
- 暴露 MCP tools。
- Codex 端完成联调。

验收：

- 用户可登录。
- 可问自然语言问题。
- AI 能检索资产、生成 SQL、执行并返回结果。
- 非 SELECT 被拒绝。
- 超过 LIMIT 被截断。
- 非服务窗口被拒绝。

### 第二期：资源保护与生产化

目标：防刷 HiveServer2、Yarn、Git。

- 全局并发、单用户并发、QPS 限制。
- 查询队列。
- Yarn application id 追踪。
- 超时查杀任务。
- systemd 自动拉起。
- 服务窗口 timer。
- 审计日志和监控告警。

验收：

- 并发压测不打满 HiveServer2。
- 超时 SQL 自动 cancel / kill。
- 服务宕机后自动拉起。
- 01:00 后不再接受新查询。

### 第三期：SQL 质量和智能化增强

目标：更准、更懂数仓口径。

- 引入 SQL explain 风险评估。
- 加强分区过滤识别。
- 引入表血缘和指标口径。
- 支持向量检索资产文档。
- 支持常见问题模板。
- 支持查询结果缓存。
- 敏感字段自动脱敏。

## 13. 关键风险与应对

| 风险 | 应对 |
|---|---|
| MCP Toolbox 不原生支持 HiveServer2 | 用 Python Gateway 封装 Hive，Toolbox 做 MCP 入口；或优先接 Trino |
| LLM 生成错误 SQL | 必须先查资产，再 SQL Guard 校验，再 explain，可失败修正 |
| 查询拖垮 HiveServer2 | 并发、QPS、连接池、超时、结果集、SQL 长度多层限制 |
| 查询拖垮 Yarn | 记录 application id，定时 kill 超时 SQL |
| 扫 Git 太重 | 离线构建资产索引，在线只查索引 |
| 非服务时间影响调度 | 服务窗口硬校验，01:00 后拒绝新查询 |
| 用户密码泄露 | 只在服务端临时会话保存，不落日志，TTL 自动清除 |
| 敏感数据泄露 | 敏感字段黑名单、脱敏、审计、权限表白名单 |

## 14. 最终效果

最终使用方式：

```text
客户在 Codex 问：
  “帮我查一下境内 6 月高价值用户画像分布，按画像标签聚合”

Codex 自动调用：
  1. search_assets
  2. get_table_schema
  3. get_etl_logic
  4. validate_hive_sql
  5. execute_hive_select

MCP 服务：
  - 使用服务器上的 DDL / DML / ETL / SLA 表清单作为上下文
  - 拼接或辅助生成 Hive SQL
  - 使用客户本次登录输入的 Hive 用户名密码连接 Hive
  - 执行受控 SELECT
  - 返回有限结果集

Codex 返回：
  - 查询口径
  - SQL
  - 结果表格
  - 简要分析结论
```

推荐一句话落地原则：

```text
MCP Toolbox 做标准 MCP 入口，Python Gateway 做 Hive 和数仓安全网关，资产索引离线构建，SQL 在线受控执行。
```

## 15. 参考资料

- Google MCP Toolbox GitHub: https://github.com/googleapis/mcp-toolbox
- MCP Toolbox README: https://raw.githubusercontent.com/googleapis/mcp-toolbox/main/README.md
- MCP 官方文档: https://modelcontextprotocol.io/docs/getting-started/intro
- MCP 传输规范: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

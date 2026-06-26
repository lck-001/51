# MCP Hive Query Gateway

这是公司内网 MCP + Hive 自然语言查询方案的落地骨架。

## 目录

- `mcp_hive_technical_solution.md`: 完整技术方案。
- `gateway/`: Python FastAPI Hive Query Gateway。
- `assets/parsed/`: DDL、DML、SLA 关键表、用户画像资产的结构化索引示例。
- `toolbox/`: Google MCP Toolbox 配置样例。
- `scripts/`: 运维脚本样例。

## 本地启动 Gateway

```powershell
cd gateway
python -m pip install -r requirements.txt
python -m uvicorn app:app --host 0.0.0.0 --port 8088
```

健康检查：

```powershell
Invoke-RestMethod http://127.0.0.1:8088/api/health
```

## 生产落地步骤

1. 修改 `gateway/config.yaml` 中 HiveServer2、认证、队列、限制参数。
2. 在 `gateway/config.yaml` 配置服务器上的 DDL、DML、用户画像目录；SLA 关键表继续维护为 JSON。
3. 部署 `gateway` 到内网 Linux 服务器。
4. 部署 Google MCP Toolbox，并让 tools 调用 Gateway API。
5. 配置 systemd 和 timer，控制每天 12:00 到次日 01:00 服务窗口。
6. Codex / Hermes / Trea 通过 MCP HTTP endpoint 接入。

服务器目录配置示例：

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
  sla_table_file: "../assets/parsed/sla_tables.json"
```

在线检索会递归扫描这些目录下的 `.sql/.sh/.md/.txt/.json` 文件，并按 `max_file_bytes` 和 `max_snippet_chars` 截断，避免一次性把大文件塞给模型。扫描结果会按 `directory_cache_ttl_seconds` 在内存缓存，避免每次提问都刷文件目录。生产高并发时建议再增加离线索引任务，把扫描结果落到 `assets/parsed/*.jsonl`。

## 重要安全边界

- Hive 地址内置在服务端。
- 客户用户名密码只通过登录接口传入并临时保存在服务端会话，不写日志。
- SQL 只允许 `SELECT` 或 `WITH SELECT`。
- 默认补 `LIMIT`，限制最大返回行数。
- 非服务窗口拒绝执行 SQL。
- 并发、QPS、SQL 长度、结果集大小都在 Gateway 统一控制。

# 51talk Hive MCP 企业接入说明

## 架构

```text
员工 MCP 客户端
  -> npx @51talk/hive-mcp-server --stdio
  -> 企业 Hive Gateway
  -> HiveServer2
```

员工电脑不需要直接连接 HiveServer2，也不需要本地启动 Gateway。Gateway 由企业在内网服务器统一部署。

## 服务端部署

在能访问 HiveServer2 的内网服务器上启动 Gateway：

```bash
cd /opt/mcp-hive/gateway
python -m uvicorn app:app --host 0.0.0.0 --port 8088
```

员工电脑需要能访问：

```bash
curl http://mcp-hive.internal:8088/api/health
```

生产环境建议用 systemd 托管 Gateway，并通过内网 DNS 暴露固定地址，例如：

```text
http://mcp-hive.internal:8088
```

## 员工客户端配置

统一使用下面这一种配置方式，把 Hive 用户名和密码直接写入 MCP 配置的 `env`：

```json
{
  "mcpServers": {
    "company-hive": {
      "command": "npx",
      "args": [
        "-y",
        "@51talk/hive-mcp-server",
        "--stdio"
      ],
      "env": {
        "HIVE_GATEWAY_URL": "http://mcp-hive.internal:8088",
        "HIVE_USER": "请替换为我的 Hive 用户名",
        "HIVE_PASSWORD": "请替换为我的 Hive 密码"
      }
    }
  }
}
```

## 工具列表

- `hive_gateway_health`: 检查 Gateway 状态
- `login_hive`: 登录 Hive，返回临时 session
- `validate_hive_sql`: 校验 Hive SQL
- `execute_hive_select`: 执行受控 SELECT 查询
- `search_hive_assets`: 搜索 DDL、DML、SLA、画像资产
- `get_hive_table_schema`: 查询表结构

## 安全边界

Gateway 服务端统一控制：

- 只允许 `SELECT` / `WITH SELECT`
- 阻断 `INSERT`、`UPDATE`、`DELETE`、`DROP`、`ALTER`、`CREATE` 等写操作
- 禁止多语句
- 自动限制返回行数
- 控制服务窗口、并发、频率和查询超时
- 支持敏感库阻断

客户端的 `Always allow` 是 MCP 客户端自己的权限机制，不能由 Gateway 服务端统一关闭。

## 内部 npm 包发布

包目录：

```text
packages/hive-mcp-server
```

发布到企业 npm registry：

```bash
cd packages/hive-mcp-server
npm publish --registry http://your-internal-npm-registry
```

员工使用时，如果企业 npm registry 不是默认源，需要在员工机器或客户端环境中配置 npm registry。


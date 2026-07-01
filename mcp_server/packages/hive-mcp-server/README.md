# @51talk/hive-mcp-server

51talk 内部 Hive MCP Server。它通过企业 Hive Gateway 执行受控 `SELECT` 查询，不直接在员工电脑连接 HiveServer2。

这个包只负责 MCP stdio 协议和 HTTP 转发，SQL 安全校验、限流、服务窗口、Hive 连接都在企业 Hive Gateway 服务端完成。

## MCP 客户端配置

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

## 工具

- `list_hive_databases`
- `list_hive_tables`
- `check_hive_sql`
- `execute_hive_select`
- `search_hive_resources`
- `get_hive_table_schema`

## 环境变量

- `HIVE_GATEWAY_URL`: Hive Gateway 地址，默认 `http://127.0.0.1:8088`
- `HIVE_USER` / `HIVE_USERNAME`: Hive 用户名
- `HIVE_PASSWORD`: Hive 密码

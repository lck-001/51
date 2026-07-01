# 51talk Hive MCP 查询服务

这是 51talk 内部使用的 Hive MCP 查询服务。它把 Hive 查询能力包装成 MCP 工具，并通过服务端统一做 SQL 安全校验、限流、服务窗口和 Hive 连接管理。

## 目录说明

```text
gateway/                 FastAPI Hive Gateway，部署在企业内网服务器
assets/parsed/           表、SLA、画像、血缘等解析后的资产索引
packages/hive-mcp-server 员工 MCP 客户端通过 npx 启动的内部 npm 包
scripts/systemd/         Linux 服务器 systemd 托管示例
scripts/healthcheck.sh   Linux 健康检查脚本，配合 systemd timer 使用
scripts/healthcheck.ps1  Windows 本地调试健康检查脚本
docs/                    企业接入和运维说明
```

## 服务端启动

```bash
cd /opt/mcp-hive/gateway
python -m pip install -r requirements.txt
python -m uvicorn app:app --host 0.0.0.0 --port 8088
```

健康检查：

```bash
curl http://127.0.0.1:8088/api/health
```

生产环境建议使用 `scripts/systemd/mcp-hive-gateway.service` 托管。

## 自动拉起

`mcp-hive-gateway.service` 已配置：

```text
Restart=always
RestartSec=5
```

进程异常退出时，systemd 会自动拉起。

如果进程没退出但 HTTP 健康检查异常，可以启用健康检查 timer：

```bash
sudo cp scripts/healthcheck.sh /opt/mcp-hive/scripts/healthcheck.sh
sudo chmod +x /opt/mcp-hive/scripts/healthcheck.sh
sudo cp scripts/systemd/mcp-hive-*.service /etc/systemd/system/
sudo cp scripts/systemd/mcp-hive-*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mcp-hive-gateway.service
sudo systemctl enable --now mcp-hive-healthcheck.timer
```

## 超时任务查杀

普通 MCP 和 HTTP 查询接口不暴露 YARN kill 能力，避免员工误杀任务。

如果确实需要运维人员查杀超大或超时任务，先在 `gateway/config.yaml` 配置：

```yaml
yarn:
  resource_manager_url: "http://yarn-rm.internal:8088"
```

然后在服务器上执行：

```bash
python scripts/kill_yarn_application.py application_1710000000000_12345
```

## 核心配置

服务端默认读取：

```text
gateway/config.yaml
```

也可以通过环境变量指定其他配置文件：

```bash
export HIVE_GATEWAY_CONFIG=/opt/mcp-hive/gateway/config.prod.yaml
```

## 员工 MCP 客户端配置

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

## 安全边界

Gateway 服务端会统一执行这些限制：

- 只允许 `SELECT` / `WITH SELECT`
- 阻断 `INSERT`、`UPDATE`、`DELETE`、`DROP`、`ALTER`、`CREATE`、`TRUNCATE`
- 禁止多语句
- 自动补充或限制 `LIMIT`
- 控制服务窗口、用户频率、用户并发和全局并发
- 支持敏感库阻断

员工客户端是否弹出 `Always allow` 是 MCP 客户端权限机制，不由 Gateway 服务端控制。

## npm 包发布

```bash
cd packages/hive-mcp-server
npm publish --registry http://your-internal-npm-registry
```

员工机器如果默认 npm registry 不是企业源，需要配置 npm registry，否则 `npx @51talk/hive-mcp-server` 拉不到包。


$ErrorActionPreference = "Stop"
# Windows 本地调试健康检查脚本。Linux 生产环境使用 scripts/healthcheck.sh 和 systemd timer。
$response = Invoke-RestMethod -Uri "http://127.0.0.1:8088/api/health" -TimeoutSec 5
if ($response.status -ne "ok") {
  throw "Gateway health check failed"
}
Write-Output "ok"

$ErrorActionPreference = "Stop"
$response = Invoke-RestMethod -Uri "http://127.0.0.1:8088/api/health" -TimeoutSec 5
if ($response.status -ne "ok") {
  throw "Gateway health check failed"
}
Write-Output "ok"

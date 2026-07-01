#!/usr/bin/env bash
set -euo pipefail

# Linux 生产健康检查脚本。失败时 systemd timer 会触发 restart service 拉起网关。
GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-http://127.0.0.1:8088/api/health}"

response="$(curl -fsS --max-time 5 "$GATEWAY_HEALTH_URL")"
printf '%s\n' "$response" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'
echo "ok"

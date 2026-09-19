#!/usr/bin/env bash
# 启动 thinking-proxy（前台）。Grok CLI 的密钥不写进代理，
# 代理只转发 CLI 带来的 Authorization / x-api-key。
set -euo pipefail
cd "$(dirname "$0")"

export UPSTREAM_HOST="${UPSTREAM_HOST:-runanytime.hxi.me}"
export PROXY_PORT="${PROXY_PORT:-8899}"

echo "[start] http://127.0.0.1:${PROXY_PORT} → https://${UPSTREAM_HOST}"
exec python3 ./thinking-proxy.py

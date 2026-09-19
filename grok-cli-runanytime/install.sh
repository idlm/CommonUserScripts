#!/usr/bin/env bash
# install.sh — curl/wget 一键入口。从 GitHub raw 拉齐文件后调用 setup-runanytime.sh。
#
#   curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash
#   wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash
#
# 带参数（管道必须用 bash -s --）：
#   curl -fsSL .../install.sh | bash -s -- --start
#   wget -qO- .../install.sh | bash -s -- --help
#
# 环境变量 GROK_RUNANYTIME_RAW_BASE 可覆盖 raw 根地址（测试用）。
set -euo pipefail
umask 077

RAW_BASE="${GROK_RUNANYTIME_RAW_BASE:-https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime}"

fetch() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    echo "需要 curl 或 wget。" >&2
    exit 1
  fi
  if [ ! -s "$dest" ]; then
    echo "下载失败或文件为空: $url" >&2
    exit 1
  fi
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 python3。" >&2
  exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/grok-runanytime.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

mkdir -p "$WORKDIR/examples"
echo "从 $RAW_BASE 拉取安装文件 …"

fetch "$RAW_BASE/setup-runanytime.sh" "$WORKDIR/setup-runanytime.sh"
fetch "$RAW_BASE/thinking-proxy.py" "$WORKDIR/thinking-proxy.py"
fetch "$RAW_BASE/thinking-proxy.test.py" "$WORKDIR/thinking-proxy.test.py"
fetch "$RAW_BASE/examples/config.runanytime-thinking-proxy.toml" \
  "$WORKDIR/examples/config.runanytime-thinking-proxy.toml"

chmod +x "$WORKDIR/setup-runanytime.sh"
bash "$WORKDIR/setup-runanytime.sh" "$@"

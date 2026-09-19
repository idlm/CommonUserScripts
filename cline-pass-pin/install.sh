#!/usr/bin/env bash
# install.sh — curl/wget 一键入口。从 GitHub raw 拉 pin-ds.sh 再执行。
#
#   curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
#   wget -qO-  https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
#
# 管道带参必须用 bash -s --（不要漏 --）：
#   curl -fsSL .../install.sh | bash -s -- --daemon
#   wget -qO-  .../install.sh | bash -s -- --help
#
# 环境变量 CLINE_PASS_PIN_RAW_BASE 可覆盖 raw 根地址（测试用）。
set -euo pipefail
umask 077

RAW_BASE="${CLINE_PASS_PIN_RAW_BASE:-https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin}"

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
  if [[ ! -s "$dest" ]]; then
    echo "下载失败或文件为空: $url" >&2
    exit 1
  fi
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 python3。" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "需要 Node.js ≥ 18。" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "需要 git（用来 clone cline-pass-switcher）。" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "${HERE:-}" && -f "$HERE/pin-ds.sh" ]]; then
  # 本仓工作树 / 已 clone：直接跑旁边的 pin-ds.sh，不依赖 GitHub raw
  exec bash "$HERE/pin-ds.sh" "$@"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cline-pass-pin.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "从 $RAW_BASE 拉取 pin-ds.sh …"
fetch "$RAW_BASE/pin-ds.sh" "$WORKDIR/pin-ds.sh"
chmod +x "$WORKDIR/pin-ds.sh"
bash "$WORKDIR/pin-ds.sh" "$@"

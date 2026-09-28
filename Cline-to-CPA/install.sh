#!/usr/bin/env bash
# install.sh — curl/wget 一键入口。拉 expose.sh 再执行。
#
#   curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/Cline-to-CPA/install.sh | bash
#   wget -qO-  https://raw.githubusercontent.com/idlm/CommonUserScripts/main/Cline-to-CPA/install.sh | bash
#
# 管道带参必须用 bash -s --（不要漏 --）：
#   curl -fsSL .../install.sh | bash -s -- --yes --install-service
#   wget -qO-  .../install.sh | bash -s -- --help
#
# 环境变量 CLINE_TO_CPA_RAW_BASE 可覆盖 raw 根地址（测试用）。
set -euo pipefail
umask 077

RAW_BASE="${CLINE_TO_CPA_RAW_BASE:-https://raw.githubusercontent.com/idlm/CommonUserScripts/main/Cline-to-CPA}"

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
if [[ -n "${HERE:-}" && -f "$HERE/expose.sh" ]]; then
  exec bash "$HERE/expose.sh" "$@"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cline-to-cpa.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "从 $RAW_BASE 拉取 expose.sh …"
fetch "$RAW_BASE/expose.sh" "$WORKDIR/expose.sh"
chmod +x "$WORKDIR/expose.sh"
bash "$WORKDIR/expose.sh" "$@"

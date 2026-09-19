#!/usr/bin/env bash
# pin-ds.sh — 本机启动 cline-pass-switcher，并把 DeepSeek V4.1 Flash 钉在 Vercel 的 deepseek 官转。
#
#   curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
#   wget -qO-  https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
#
# 管道带参必须用 bash -s --（不要漏 --）：
#   curl -fsSL .../install.sh | bash -s -- --start
#   curl -fsSL .../install.sh | bash -s -- --help
#
# 环境变量：
#   CLINE_PASS_KEY              上游 Cline Pass Key（sk_…）。也可事后在控制台填
#   PROXY_KEY                   下游代理密钥；本地默认可空
#   CLINE_PASS_PIN_HOME         安装目录，默认 ~/.cline-pass-switcher
#   CLINE_PASS_PIN_PORT         监听端口，默认 3123
#   CLINE_PASS_PIN_BIND         绑定地址，默认 127.0.0.1
#   CLINE_PASS_PIN_UPSTREAM     钉住的渠道 slug，默认 deepseek
#   CLINE_PASS_PIN_MODEL        主模型，默认 cline-pass/deepseek-v4.1-flash
#   CLINE_PASS_SWITCHER_REPO    switcher git URL
#   CLINE_PASS_SWITCHER_REF     git ref，默认 HEAD
set -euo pipefail
umask 077

HOME_DIR="${CLINE_PASS_PIN_HOME:-$HOME/.cline-pass-switcher}"
PORT="${CLINE_PASS_PIN_PORT:-3123}"
BIND="${CLINE_PASS_PIN_BIND:-127.0.0.1}"
UPSTREAM="${CLINE_PASS_PIN_UPSTREAM:-deepseek}"
MODEL="${CLINE_PASS_PIN_MODEL:-cline-pass/deepseek-v4.1-flash}"
SWITCHER_REPO="${CLINE_PASS_SWITCHER_REPO:-https://github.com/munmunjaklin458-afk/cline-pass-switcher.git}"
SWITCHER_REF="${CLINE_PASS_SWITCHER_REF:-HEAD}"
PID_FILE="$HOME_DIR/switcher.pid"
LOG_FILE="$HOME_DIR/switcher.log"
CONFIG_PATH="$HOME_DIR/config.json"
SRC_DIR="$HOME_DIR/src"

info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!! \033[0m %s\n' "$*" >&2; }
die()   { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: pin-ds.sh [选项]

  --start              配完后在前台启动（管道场景用 --daemon）
  --daemon             配完后后台启动，pid 写 ~/.cline-pass-switcher/switcher.pid
  --stop               停后台进程
  --status             看端口 / pid / 钉住配置
  --probe              GET 本机 /v1/models（需要已启动）
  --print-config       只打印将要写入的 config.json，不写盘
  --yes / -y           已有 config.json 时覆盖 perModel 钉住段（保留 accounts / proxyKey）
  --no-clone           已有 src/ 时不 git pull
  --help / -h          本帮助

环境变量见脚本头注释。Key 不要写进 git。
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少 $1"
}

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "${pid:-}" && -d "/proc/$pid" ]] && return 0
  fi
  return 1
}

stop_daemon() {
  if is_running; then
    local pid
    pid="$(cat "$PID_FILE")"
    info "停止 pid $pid"
    kill "$pid" 2>/dev/null || true
    sleep 0.4
    if [[ -d "/proc/$pid" ]]; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  else
    info "没有在跑的 daemon"
    rm -f "$PID_FILE"
  fi
}

status_cmd() {
  printf 'home      %s\n' "$HOME_DIR"
  printf 'config    %s\n' "$CONFIG_PATH"
  printf 'src       %s\n' "$SRC_DIR"
  printf 'listen    %s:%s\n' "$BIND" "$PORT"
  printf 'model     %s\n' "$MODEL"
  printf 'upstream  %s\n' "$UPSTREAM"
  if is_running; then
    printf 'daemon    pid %s\n' "$(cat "$PID_FILE")"
  else
    printf 'daemon    未运行\n'
  fi
  if [[ -f "$CONFIG_PATH" ]]; then
    python3 - "$CONFIG_PATH" "$MODEL" <<'PY' || true
import json, sys
p, model = sys.argv[1], sys.argv[2]
cfg = json.load(open(p))
pm = (cfg.get("perModel") or {}).get(model) or {}
print("pinMode   ", pm.get("pinMode"))
print("upstreams ", pm.get("upstreams"))
nacc = len(cfg.get("accounts") or [])
print("accounts  ", nacc, "(keys hidden)")
print("proxyKey  ", "set" if cfg.get("proxyKey") else "empty")
PY
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -E ":${PORT}\\b" || true
  fi
}

probe_cmd() {
  local url="http://${BIND}:${PORT}/v1/models"
  info "GET $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 20 "$url" | python3 -m json.tool | head -80
  else
    wget -qO- --timeout=20 "$url" | python3 -m json.tool | head -80
  fi
}

build_config_json() {
  python3 - "$1" "$PORT" "$BIND" "$UPSTREAM" "$MODEL" "${CLINE_PASS_KEY:-}" "${PROXY_KEY:-}" <<'PY'
import json, os, sys
path, port, bind, upstream, model, key, proxy = sys.argv[1:8]
port = int(port)
existing = {}
if os.path.isfile(path):
    try:
        existing = json.load(open(path))
    except Exception:
        existing = {}

cfg = {
    "port": port,
    "bindHost": bind,
    "apiKey": existing.get("apiKey", ""),
    "proxyKey": proxy or existing.get("proxyKey", ""),
    "publicBaseUrl": existing.get("publicBaseUrl", ""),
    "exposeCatalog": existing.get("exposeCatalog", False),
    "upstreamBase": existing.get("upstreamBase") or "https://api.cline.bot/api/v1",
    "accounts": existing.get("accounts") or [],
    "accountMode": existing.get("accountMode") or "single",
    "activeAccount": existing.get("activeAccount", 0),
    "knownModels": existing.get("knownModels") or [],
    "perModel": existing.get("perModel") or {},
}

wanted = [
    model,
    "cline-pass/deepseek-v4-flash",
    "cline-pass/glm-5.3",
    "cline-pass/glm-5.3-flash",
    "cline-pass/kimi-k3",
    "cline-pass/qwen3.8-max",
]
seen = set(cfg["knownModels"])
for m in wanted:
    if m not in seen:
        cfg["knownModels"].append(m)
        seen.add(m)

pin = {
    "upstreams": [upstream],
    "exclude": [],
    "pinMode": "strict",
    "sort": None,
}
# 同族 flash 一并钉死，避免客户端切短名又随机路由
for m in (model, "cline-pass/deepseek-v4-flash"):
    cfg["perModel"][m] = pin

if key:
    accs = cfg["accounts"] if isinstance(cfg["accounts"], list) else []
    if not accs:
        cfg["accounts"] = [{"name": "default", "key": key, "enabled": True}]
        cfg["accountMode"] = "single"
        cfg["activeAccount"] = 0
    else:
        # 不覆盖已有 key；只在全空时写入
        pass

json.dump(cfg, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
PY
}

clone_switcher() {
  need_cmd git
  mkdir -p "$HOME_DIR"
  if [[ -d "$SRC_DIR/.git" ]]; then
    if [[ "${NO_CLONE:-0}" == 1 ]]; then
      info "跳过 git pull（--no-clone）"
      return
    fi
    info "更新 $SRC_DIR"
    git -C "$SRC_DIR" fetch --depth 1 origin 2>/dev/null || git -C "$SRC_DIR" fetch --depth 1
    if [[ "$SWITCHER_REF" == "HEAD" ]]; then
      git -C "$SRC_DIR" reset --hard "origin/main" >/dev/null 2>&1 \
        || git -C "$SRC_DIR" reset --hard "origin/master"
    else
      git -C "$SRC_DIR" reset --hard "${SWITCHER_REF}" >/dev/null 2>&1 \
        || git -C "$SRC_DIR" reset --hard "origin/main" >/dev/null 2>&1 \
        || git -C "$SRC_DIR" reset --hard "origin/master"
    fi
  else
    info "clone $SWITCHER_REPO → $SRC_DIR"
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$SWITCHER_REPO" "$SRC_DIR"
    if [[ "$SWITCHER_REF" != "HEAD" ]]; then
      git -C "$SRC_DIR" fetch --depth 1 origin "$SWITCHER_REF" || true
      git -C "$SRC_DIR" checkout "$SWITCHER_REF" || true
    fi
  fi
  [[ -f "$SRC_DIR/server.js" ]] || die "switcher 没有 server.js，clone 失败？"
}

write_config() {
  mkdir -p "$HOME_DIR"
  local tmp
  tmp="$(mktemp)"
  build_config_json "$CONFIG_PATH" > "$tmp"
  if [[ -f "$CONFIG_PATH" && "${YES:-0}" != 1 ]]; then
    if ! python3 - "$CONFIG_PATH" "$tmp" <<'PY'
import json, sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
# 比较钉住段
sys.exit(0 if a.get("perModel")==b.get("perModel") and a.get("knownModels")==b.get("knownModels")
           and a.get("port")==b.get("port") and a.get("bindHost")==b.get("bindHost") else 1)
PY
    then
      warn "已有 $CONFIG_PATH。加 --yes 才会改 perModel / 端口（accounts 会保留）。"
      warn "本次只保证目录和源码，不覆盖配置。"
      rm -f "$tmp"
      return
    fi
  fi
  mv "$tmp" "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"
  info "写入 $CONFIG_PATH"
  info "钉住 $MODEL → $UPSTREAM (strict / Vercel gateway.only)"
}

start_fg() {
  need_cmd node
  [[ -f "$SRC_DIR/server.js" ]] || die "先安装源码"
  [[ -f "$CONFIG_PATH" ]] || die "没有 config.json"
  export DATA_DIR="$HOME_DIR"
  export PORT
  export BIND_HOST="$BIND"
  info "前台启动  http://${BIND}:${PORT}/"
  info "客户端 Base URL = http://${BIND}:${PORT}/v1"
  info "模型 = $MODEL"
  exec node "$SRC_DIR/server.js"
}

start_daemon() {
  need_cmd node
  if is_running; then
    info "已在跑 pid $(cat "$PID_FILE")"
    return
  fi
  export DATA_DIR="$HOME_DIR"
  export PORT
  export BIND_HOST="$BIND"
  nohup node "$SRC_DIR/server.js" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  sleep 0.5
  if is_running; then
    info "daemon pid $(cat "$PID_FILE")  log $LOG_FILE"
    info "控制台  http://${BIND}:${PORT}/"
    info "Base URL http://${BIND}:${PORT}/v1   model $MODEL"
  else
    rm -f "$PID_FILE"
    die "启动失败，看 $LOG_FILE"
  fi
}

DO_START=0
DO_DAEMON=0
DO_STOP=0
DO_STATUS=0
DO_PROBE=0
DO_PRINT=0
YES=0
NO_CLONE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) DO_START=1 ;;
    --daemon) DO_DAEMON=1 ;;
    --stop) DO_STOP=1 ;;
    --status) DO_STATUS=1 ;;
    --probe) DO_PROBE=1 ;;
    --print-config) DO_PRINT=1 ;;
    --yes|-y) YES=1 ;;
    --no-clone) NO_CLONE=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知参数: $1  （--help）" ;;
  esac
  shift
done

if [[ "$DO_STOP" == 1 ]]; then
  stop_daemon
  exit 0
fi
if [[ "$DO_STATUS" == 1 ]]; then
  status_cmd
  exit 0
fi
if [[ "$DO_PROBE" == 1 ]]; then
  probe_cmd
  exit 0
fi
if [[ "$DO_PRINT" == 1 ]]; then
  mkdir -p "$HOME_DIR"
  build_config_json "$CONFIG_PATH"
  exit 0
fi

need_cmd python3
need_cmd node
command -v git >/dev/null 2>&1 || die "缺少 git（用来拉 cline-pass-switcher）"
NODE_MAJ="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[[ "$NODE_MAJ" -ge 18 ]] || die "需要 Node.js ≥ 18，当前 $(node -v 2>/dev/null || echo unknown)"

clone_switcher
write_config

if [[ "$DO_START" == 1 ]]; then
  start_fg
elif [[ "$DO_DAEMON" == 1 ]]; then
  start_daemon
else
  info "源码 $SRC_DIR"
  info "配置 $CONFIG_PATH"
  info "启动："
  printf '  DATA_DIR=%q PORT=%q BIND_HOST=%q node %q\n' "$HOME_DIR" "$PORT" "$BIND" "$SRC_DIR/server.js"
  info "或："
  echo "  bash $0 --daemon"
  info "客户端："
  echo "  Base URL  http://${BIND}:${PORT}/v1"
  echo "  Model     $MODEL"
  echo "  API Key   控制台「访问与安全」的 proxyKey；本地空 = 不鉴权"
  info "Cline Pass 上游 Key 用环境变量 CLINE_PASS_KEY 或打开 http://${BIND}:${PORT}/ 在账号管理里填。"
  info "官方 /v1/models 不含 cline-pass/*，模型清单以本目录 examples/pi-models.json 为准。"
fi

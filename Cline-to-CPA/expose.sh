#!/usr/bin/env bash
# expose.sh — 把本机 Cline Pass 观测代理反带出去，给远程 CPA 当一条 OpenAI 上游。
#
# 钉上游已经失效。这个脚本不做 only/order。它装的是只观测的 switcher：
#   远程 CPA  --Bearer 下游密钥-->  本机 :3123/v1  -->  api.cline.bot
#   本机 Cline CLI 继续打 127.0.0.1，不要求这把密钥。
#
#   curl -fsSL .../Cline-to-CPA/install.sh | bash -s -- --yes --install-service
#
# 环境变量：
#   CLINE_TO_CPA_HOME     安装目录，默认 ~/.cline-pass-switcher
#   CLINE_TO_CPA_PORT     监听端口，默认 3123
#   CLINE_TO_CPA_BIND     绑定地址，默认 0.0.0.0
#   CLINE_TO_CPA_PUBLIC   公网根地址，不带 /v1。空则用探测到的公网 IP
#   CLINE_TO_CPA_REPO     switcher git URL
#   CLINE_TO_CPA_REF      git ref，默认 main
#   PROXY_KEY             已有下游密钥时沿用；空则生成 cps- 开头的新密钥
set -euo pipefail
umask 077

HOME_DIR="${CLINE_TO_CPA_HOME:-$HOME/.cline-pass-switcher}"
PORT="${CLINE_TO_CPA_PORT:-3123}"
BIND="${CLINE_TO_CPA_BIND:-0.0.0.0}"
PUBLIC="${CLINE_TO_CPA_PUBLIC:-}"
SWITCHER_REPO="${CLINE_TO_CPA_REPO:-https://github.com/idlm/cline-pass-switcher.git}"
SWITCHER_REF="${CLINE_TO_CPA_REF:-main}"
PROXY_KEY="${PROXY_KEY:-}"
YES=0
DO_SERVICE=0
STATUS_ONLY=0
UNIT_NAME="cline-pass-switcher.service"
SYSTEM_UNIT="/etc/systemd/system/${UNIT_NAME}"
USER_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${UNIT_NAME}"
CONFIG_PATH="$HOME_DIR/config.json"
SRC_DIR="$HOME_DIR/src"
LOG_FILE="$HOME_DIR/switcher.log"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
用法: expose.sh [--yes] [--install-service] [--status] [--port N] [--public URL]

  --yes               已有 config.json 时也改端口 / 公网地址 / 监听（保留 accounts）
  --install-service   写 systemd 并 enable --now（root 写系统单元，否则写 user 单元）
  --status            只打印地址、端口、密钥是否已设，不改文件
  --port N            监听端口，默认 3123
  --public URL        公网根地址，不带 /v1，例如 http://1.2.3.4:3123

密钥写在 $CONFIG_PATH 的 proxyKey，不打印到仓库。
Cline Pass 登录沿用已有 accounts，或本机 Cline CLI 的 OAuth。脚本不接收 sk_。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --install-service) DO_SERVICE=1 ;;
    --status) STATUS_ONLY=1 ;;
    --port) PORT="${2:?}"; shift ;;
    --public) PUBLIC="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1 （--help）" ;;
  esac
  shift
done

need() { command -v "$1" >/dev/null 2>&1 || die "需要 $1"; }
need python3
need node
need git

node_major="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$node_major" -ge 18 ]] || die "需要 Node.js ≥ 18，当前 $(node -v)"

detect_public() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4 -fsS -m 8 https://api.ipify.org || true)"
  elif command -v wget >/dev/null 2>&1; then
    ip="$(wget -qO- -T 8 https://api.ipify.org || true)"
  fi
  ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip=""
  printf '%s' "$ip"
}

if [[ "$STATUS_ONLY" == 1 ]]; then
  python3 - "$CONFIG_PATH" "$PORT" <<'PY'
import json, sys
path, port = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(path))
except Exception:
    print("config   未安装", path)
    raise SystemExit(0)
base = (cfg.get("publicBaseUrl") or "").rstrip("/")
key = cfg.get("proxyKey") or ""
print("listen   ", cfg.get("bindHost") or "127.0.0.1", cfg.get("port") or port)
print("base url ", (base + "/v1") if base else "(未设公网地址)")
print("proxyKey ", "已设置 %d 字符" % len(key) if key else "空（公网等于不鉴权）")
print("accounts ", len(cfg.get("accounts") or []))
PY
  exit 0
fi

if [[ -z "$PUBLIC" ]]; then
  ip="$(detect_public)"
  [[ -n "$ip" ]] || die "探测不到公网 IP。用 --public http://你的IP:${PORT} 指定。"
  PUBLIC="http://${ip}:${PORT}"
fi
PUBLIC="${PUBLIC%/}"

mkdir -p "$HOME_DIR"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  info "clone $SWITCHER_REPO ($SWITCHER_REF)"
  git clone --depth 1 --branch "$SWITCHER_REF" "$SWITCHER_REPO" "$SRC_DIR"
else
  info "更新 $SRC_DIR"
  git -C "$SRC_DIR" fetch --depth 1 origin "$SWITCHER_REF"
  git -C "$SRC_DIR" checkout -q "$SWITCHER_REF" || git -C "$SRC_DIR" reset --hard "origin/$SWITCHER_REF"
fi

if [[ -f "$CONFIG_PATH" && "$YES" != 1 ]]; then
  warn "已有 $CONFIG_PATH。加 --yes 才会改端口、公网地址和监听（accounts 会保留）。"
else
  info "写 $CONFIG_PATH （保留已有 Cline 账号，生成或沿用下游密钥）"
  PROXY_KEY="$PROXY_KEY" python3 - "$CONFIG_PATH" "$PORT" "$BIND" "$PUBLIC" <<'PY'
import json, os, secrets, sys
path, port, bind, public = sys.argv[1:]
try:
    cfg = json.load(open(path))
except Exception:
    cfg = {}
key = os.environ.get("PROXY_KEY") or cfg.get("proxyKey") or ("cps-" + secrets.token_hex(24))
cfg.update({
    "port": int(port),
    "bindHost": bind,
    "proxyKey": key,
    "publicBaseUrl": public,
    "upstreamBase": cfg.get("upstreamBase") or "https://api.cline.bot/api/v1",
    "accountMode": cfg.get("accountMode") or "single",
    "activeAccount": cfg.get("activeAccount", 0),
    "accounts": cfg.get("accounts") or [],
    "exposeCatalog": bool(cfg.get("exposeCatalog", False)),
})
cfg.setdefault("apiKey", "")
cfg.setdefault("knownModels", [
    "cline-pass/deepseek-v4.1-flash",
    "cline-pass/deepseek-v4-flash",
    "cline-pass/glm-5.3",
    "cline-pass/glm-5.3-flash",
    "cline-pass/kimi-k3",
    "cline-pass/qwen3.8-max",
])
cfg.setdefault("perModel", {})
json.dump(cfg, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
os.chmod(path, 0o600)
print(key)
PY
fi

KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("proxyKey") or "")' "$CONFIG_PATH")"
[[ -n "$KEY" ]] || die "proxyKey 为空。公网监听不能没有下游密钥。"

have_systemd() { command -v systemctl >/dev/null 2>&1; }

render_unit() {
  local node="$1" wanted_by="$2" user_line="$3"
  cat <<EOF
[Unit]
Description=cline-pass-switcher (observe only, expose to CPA)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
${user_line}
WorkingDirectory=${HOME_DIR}
Environment=DATA_DIR=${HOME_DIR}
Environment=PORT=${PORT}
Environment=BIND_HOST=${BIND}
ExecStart=${node} ${SRC_DIR}/server.js
Restart=always
RestartSec=2
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=${wanted_by}
EOF
}

if [[ "$DO_SERVICE" == 1 ]]; then
  have_systemd || die "没有 systemd，去掉 --install-service 后手动启动 node。"
  node_bin="$(command -v node)"
  if [[ "$(id -u)" == 0 ]]; then
    render_unit "$node_bin" multi-user.target "User=root" > "$SYSTEM_UNIT"
    systemctl daemon-reload
    systemctl enable --now "$UNIT_NAME"
    info "systemd 已启用 $SYSTEM_UNIT"
  else
    mkdir -p "$(dirname "$USER_UNIT")"
    render_unit "$node_bin" default.target "" > "$USER_UNIT"
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT_NAME"
    info "user systemd 已启用 $USER_UNIT"
  fi
else
  warn "这次没有装 systemd。已有服务在跑的话，改完配置需要自行重启。"
fi

cat <<EOF

反带出去已写好。把下面两行给远程 CPA 或 OpenAI 客户端，不要写进 git。

  Base URL   ${PUBLIC}/v1
  API Key    ${KEY}
  Model      cline-pass/deepseek-v4.1-flash

CPA config.yaml:

  openai-compatibility:
    - name: "cline-pass"
      base-url: "${PUBLIC}/v1"
      api-key-entries:
        - api-key: "${KEY}"
      models:
        - name: "cline-pass/deepseek-v4.1-flash"
          alias: "ds-flash"

本机 Cline CLI 继续用 http://127.0.0.1:${PORT}/v1，环回不要求这把密钥。
控制台（只在本机开）：http://127.0.0.1:${PORT}/
这是明文 HTTP。要长期给别人用，前面再加一层 HTTPS。
EOF

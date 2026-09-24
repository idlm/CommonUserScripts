#!/usr/bin/env bash
# pin-ds.sh — 本机启动 cline-pass-switcher，并把 DeepSeek V4.1 Flash 钉在 Vercel 的 deepseek 官转。
#
#   curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
#   wget -qO-  https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
#
# 管道带参必须用 bash -s --（不要漏 --）：
#   curl -fsSL .../install.sh | bash -s -- --yes --install-service
#   curl -fsSL .../install.sh | bash -s -- --help
#
# 环境变量：
#   CLINE_PASS_USE_OAUTH        1（默认）用本机 Cline 登录态打上游并自动续期。
#                               设为 0 才回退到静态 sk_（容易过期并报 Unauthorized）。
#   CLINE_PASS_KEY              仅 CLINE_PASS_USE_OAUTH=0 时使用的静态 sk_
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
UNIT_NAME="cline-pass-switcher.service"
SYSTEM_UNIT="/etc/systemd/system/${UNIT_NAME}"
USER_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${UNIT_NAME}"
CLINE_PROVIDERS="${CLINE_PROVIDERS:-$HOME/.cline/data/settings/providers.json}"
# 默认走本机已登录的 Cline Pass，不依赖会过期的静态 sk_。
USE_OAUTH="${CLINE_PASS_USE_OAUTH:-1}"
case "${USE_OAUTH}" in
  0|false|no|off) USE_OAUTH=0 ;;
  *) USE_OAUTH=1 ;;
esac

info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!! \033[0m %s\n' "$*" >&2; }
die()   { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: pin-ds.sh [选项]

  --install-service    配完后装 systemd，enable --now（开机自启，推荐）
  --uninstall-service  关掉开机自启并删 unit（不停改 config）
  --pin-cline          把已登录的 Cline CLI 指到本机 :3123（只改 baseUrl / 模型）
  --static-key         不用登录态，改回静态 sk_（需要 CLINE_PASS_KEY，容易过期）
  --start              配完后在前台启动（管道场景用 --daemon / --install-service）
  --daemon             配完后 nohup 后台启动（reboot 会丢，能装 systemd 请用 --install-service）
  --stop               停 nohup；若 systemd 在跑则 systemctl stop（不 disable）
  --status             看端口 / pid / systemd / 钉住配置
  --probe              GET 本机 /v1/models（需要已启动）
  --print-config       只打印将要写入的 config.json，不写盘
  --yes / -y           已有 config.json 时覆盖 perModel 钉住段（保留 accounts / proxyKey）
  --no-clone           已有 src/ 时不 git pull
  --help / -h          本帮助

默认 CLINE_PASS_USE_OAUTH=1：上游用 ~/.cline 的登录态，过期前自动续期。
不要再填 sk_。静态 key 被网关拒绝时会返回：
  Unauthorized: Please make sure you're using the latest version of Cline
  and re-authenticate your Cline account.
Key 不要写进 git / systemd unit。
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少 $1"
}

have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "${pid:-}" && -d "/proc/$pid" ]] && return 0
  fi
  return 1
}

port_pids() {
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -E ":${PORT}\\b" || true
  fi
}

systemd_kind() {
  if [[ -f "$SYSTEM_UNIT" ]]; then
    echo system
  elif [[ -f "$USER_UNIT" ]]; then
    echo user
  else
    echo none
  fi
}

systemd_cmd() {
  local kind="${1:-}"
  shift || true
  if [[ "$kind" == "user" ]]; then
    systemctl --user "$@"
  else
    if [[ "$(id -u)" -eq 0 ]]; then
      systemctl "$@"
    elif command -v sudo >/dev/null 2>&1; then
      sudo systemctl "$@"
    else
      systemctl "$@"
    fi
  fi
}

write_via() {
  local dest="$1"
  if [[ "$dest" == /etc/* && "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "写 $dest 需要 root 或 sudo"
    sudo tee "$dest" >/dev/null
  else
    cat > "$dest"
  fi
}

rm_via() {
  local dest="$1"
  if [[ "$dest" == /etc/* && "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "删 $dest 需要 root 或 sudo"
    sudo rm -f "$dest"
  else
    rm -f "$dest"
  fi
}

pick_unit_path() {
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "$SYSTEM_UNIT"
  elif [[ -f "$SYSTEM_UNIT" ]]; then
    echo "$SYSTEM_UNIT"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    echo "$SYSTEM_UNIT"
  else
    echo "$USER_UNIT"
  fi
}

node_bin() {
  local n
  n="$(command -v node)"
  readlink -f "$n" 2>/dev/null || echo "$n"
}

stop_daemon() {
  local kind
  kind="$(systemd_kind)"
  if [[ "$kind" != none ]] && have_systemd; then
    if systemd_cmd "$kind" is-active --quiet "$UNIT_NAME" 2>/dev/null; then
      info "systemctl stop $UNIT_NAME  ($kind)"
      systemd_cmd "$kind" stop "$UNIT_NAME" || true
    fi
  fi
  if is_running; then
    local pid
    pid="$(cat "$PID_FILE")"
    info "停止 nohup pid $pid"
    kill "$pid" 2>/dev/null || true
    sleep 0.4
    if [[ -d "/proc/$pid" ]]; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  else
    rm -f "$PID_FILE"
    if [[ "$kind" == none ]]; then
      info "没有在跑的 daemon"
    fi
  fi
}

status_cmd() {
  local kind
  printf 'home      %s\n' "$HOME_DIR"
  printf 'config    %s\n' "$CONFIG_PATH"
  printf 'src       %s\n' "$SRC_DIR"
  printf 'listen    %s:%s\n' "$BIND" "$PORT"
  printf 'model     %s\n' "$MODEL"
  printf 'upstream  %s\n' "$UPSTREAM"
  if is_running; then
    printf 'nohup     pid %s\n' "$(cat "$PID_FILE")"
  else
    printf 'nohup     未运行\n'
  fi
  kind="$(systemd_kind)"
  if have_systemd; then
    if [[ "$kind" == none ]]; then
      printf 'systemd   not-installed\n'
    else
      printf 'systemd   %s  enabled=%s  active=%s\n' \
        "$kind" \
        "$(systemd_cmd "$kind" is-enabled "$UNIT_NAME" 2>/dev/null || echo unknown)" \
        "$(systemd_cmd "$kind" is-active "$UNIT_NAME" 2>/dev/null || echo unknown)"
    fi
  else
    printf 'systemd   unavailable\n'
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
print("oauth     ", "on" if cfg.get("useClineOAuth") else "off")
print("proxyKey  ", "set" if cfg.get("proxyKey") else "empty")
PY
  fi
  if [[ -f "$CLINE_PROVIDERS" ]]; then
    python3 - "$CLINE_PROVIDERS" <<'PY' || true
import json, sys
d = json.load(open(sys.argv[1]))
st = ((d.get("providers") or {}).get("cline-pass") or {}).get("settings") or {}
print("cline     baseUrl=", st.get("baseUrl") or "(unset)", " model=", st.get("model") or "(unset)")
PY
  else
    printf 'cline     providers.json 不存在\n'
  fi
  port_pids
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
  python3 - "$1" "$PORT" "$BIND" "$UPSTREAM" "$MODEL" "${CLINE_PASS_KEY:-}" "${PROXY_KEY:-}" "$USE_OAUTH" <<'PY'
import json, os, sys
path, port, bind, upstream, model, key, proxy, use_oauth = sys.argv[1:9]
port = int(port)
use_oauth = use_oauth == "1"
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
    "useClineOAuth": use_oauth,
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

if key and not use_oauth:
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
    else
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
  ensure_oauth_support
}

# 上游仓库还没合并登录续期时，clone 下来的 server.js 仍用静态 sk_。
# 缺 useClineOAuth 就补上同一段逻辑，否则下次拉代码又会 Unauthorized。
ensure_oauth_support() {
  python3 - "$SRC_DIR/server.js" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "useClineOAuth" in text and "async function clineBearer" in text:
    print("oauth     server.js 已支持 useClineOAuth")
    sys.exit(0)
old = """const chatHeaders = (key) => ({
  'Content-Type': 'application/json',
  Authorization: `Bearer ${key}`,
});"""
new = r'''const CLINE_PROVIDERS_PATH = process.env.CLINE_PROVIDERS_PATH
  || path.join(process.env.HOME || '/root', '.cline/data/settings/providers.json');
const OAUTH_REFRESH_BUFFER_MS = 5 * 60 * 1000;
let oauthCache = null;
let oauthRefreshPromise = null;

function readClineAuth() {
  const providers = loadJson(CLINE_PROVIDERS_PATH, null);
  const map = providers?.providers || {};
  return map.cline?.settings?.auth || map['cline-pass']?.settings?.auth || null;
}

function jwtExpiryMs(token) {
  const raw = String(token || '').replace(/^workos:/i, '');
  const part = raw.split('.')[1];
  if (!part) return 0;
  try {
    const payload = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
    return typeof payload.exp === 'number' ? payload.exp * 1000 : 0;
  } catch {
    return 0;
  }
}

async function refreshClineOAuth(refreshToken) {
  const res = await fetch(`${config.upstreamBase}/auth/refresh`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': 'Cline/3.0.64',
      'HTTP-Referer': 'https://cline.bot',
      'X-Title': 'Cline',
    },
    body: JSON.stringify({ refreshToken, grantType: 'refresh_token' }),
    signal: AbortSignal.timeout(30000),
  });
  const json = await res.json().catch(() => null);
  const data = json?.data || json || {};
  if (!res.ok || !data.accessToken) {
    const msg = data?.message || json?.error?.message || `oauth refresh failed (${res.status})`;
    throw new Error(msg);
  }
  const token = String(data.accessToken).replace(/^workos:/i, '');
  return {
    token,
    refreshToken: data.refreshToken || refreshToken,
    expiresAt: Date.parse(data.expiresAt) || jwtExpiryMs(token),
  };
}

function persistClineAuth(next) {
  try {
    const providers = loadJson(CLINE_PROVIDERS_PATH, null);
    if (!providers?.providers) return;
    const now = new Date().toISOString();
    for (const id of ['cline', 'cline-pass']) {
      const auth = providers.providers[id]?.settings?.auth;
      if (!auth) continue;
      auth.accessToken = `workos:${next.token}`;
      auth.refreshToken = next.refreshToken;
      auth.expiresAt = next.expiresAt;
      providers.providers[id].updatedAt = now;
    }
    fs.writeFileSync(CLINE_PROVIDERS_PATH, JSON.stringify(providers, null, 2) + '\n', { mode: 0o600 });
  } catch (e) {
    console.warn('[oauth] 写回登录态失败:', e.message);
  }
}

async function clineBearer() {
  if (oauthCache && oauthCache.expiresAt - Date.now() > OAUTH_REFRESH_BUFFER_MS) return oauthCache.token;
  if (!oauthRefreshPromise) {
    oauthRefreshPromise = (async () => {
      const auth = readClineAuth();
      const stored = String(auth?.accessToken || '').replace(/^workos:/i, '');
      const expiresAt = Number(auth?.expiresAt) || jwtExpiryMs(stored);
      if (stored && expiresAt - Date.now() > OAUTH_REFRESH_BUFFER_MS) {
        oauthCache = { token: stored, expiresAt, refreshToken: auth.refreshToken };
        return stored;
      }
      if (!auth?.refreshToken) throw new Error('Cline 登录态缺失，无法续期');
      const next = await refreshClineOAuth(auth.refreshToken);
      oauthCache = next;
      persistClineAuth(next);
      return next.token;
    })().finally(() => { oauthRefreshPromise = null; });
  }
  return oauthRefreshPromise;
}

async function chatHeaders(key, { oauth = !!config.useClineOAuth } = {}) {
  const headers = {
    'Content-Type': 'application/json',
    'User-Agent': 'Cline/3.0.64',
    'HTTP-Referer': 'https://cline.bot',
    'X-Title': 'Cline',
    'X-CLIENT-TYPE': 'cline-cli',
    'X-CLIENT-VERSION': '3.0.64',
    'X-PLATFORM': 'cli',
    'X-PLATFORM-VERSION': '3.0.64',
  };
  if (oauth) {
    headers.Authorization = `Bearer workos:${await clineBearer()}`;
    return headers;
  }
  headers.Authorization = `Bearer ${key}`;
  return headers;
}'''
if old not in text:
    sys.exit("server.js 里没有预期的 chatHeaders，无法补登录续期。")
text = text.replace(old, new, 1)
text = text.replace("headers: chatHeaders(", "headers: await chatHeaders(")
needle = "headers: await chatHeaders(k),"
repl = "headers: await chatHeaders(k, { oauth: false }),"
if needle not in text:
    sys.exit("server.js 账号测试请求没对上，无法保持「测试密钥」测的是填入的 key。")
text = text.replace(needle, repl, 1)
path.write_text(text, encoding="utf-8")
print("oauth     已给 server.js 补上 useClineOAuth（上游仓库尚未合并该修复）")
PY
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
# 比较钉住段和鉴权方式。useClineOAuth 变了也要写回，否则下次还用过期 sk_。
sys.exit(0 if a.get("perModel")==b.get("perModel") and a.get("knownModels")==b.get("knownModels")
           and a.get("port")==b.get("port") and a.get("bindHost")==b.get("bindHost")
           and bool(a.get("useClineOAuth"))==bool(b.get("useClineOAuth")) else 1)
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
  if [[ "$USE_OAUTH" == 1 ]]; then
    info "上游鉴权 = 本机 Cline 登录态（自动续期）。不要再填 sk_。"
  else
    warn "上游鉴权 = 静态 sk_。过期后会 Unauthorized，建议去掉 --static-key。"
  fi
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
  local kind
  kind="$(systemd_kind)"
  if [[ "$kind" != none ]] && have_systemd && systemd_cmd "$kind" is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    info "systemd 已在跑（$kind），不启 nohup。停掉用: systemctl stop $UNIT_NAME"
    return
  fi
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
    warn "nohup 不能开机自启。要 reboot 也钉住： bash $0 --install-service"
  else
    rm -f "$PID_FILE"
    die "启动失败，看 $LOG_FILE"
  fi
}

render_unit() {
  local node="$1" wanted_by="$2" user_line="$3"
  cat <<EOF
[Unit]
Description=cline-pass-switcher (pin DeepSeek V4.1 Flash to Vercel deepseek)
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

install_service() {
  need_cmd node
  [[ -f "$SRC_DIR/server.js" ]] || die "先安装源码"
  [[ -f "$CONFIG_PATH" ]] || die "没有 config.json"
  have_systemd || die "本机没有 systemd。改用 --daemon（reboot 不会自动拉起）"

  local unit_path kind node wanted user_line
  unit_path="$(pick_unit_path)"
  node="$(node_bin)"
  [[ -x "$node" ]] || die "找不到 node"

  if [[ "$unit_path" == "$SYSTEM_UNIT" ]]; then
    kind=system
    wanted=multi-user.target
    user_line="User=$(id -un)"
  else
    kind=user
    wanted=default.target
    user_line=""
    mkdir -p "$(dirname "$unit_path")"
  fi

  stop_daemon

  info "写入 $unit_path"
  render_unit "$node" "$wanted" "$user_line" | write_via "$unit_path"

  systemd_cmd "$kind" daemon-reload
  systemd_cmd "$kind" enable --now "$UNIT_NAME"

  if [[ "$kind" == user ]]; then
    if command -v loginctl >/dev/null 2>&1; then
      local linger
      linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo no)"
      if [[ "$linger" != yes ]]; then
        if [[ "$(id -u)" -eq 0 ]] || command -v sudo >/dev/null 2>&1; then
          info "打开 linger，logout 后 user unit 也能起来"
          if [[ "$(id -u)" -eq 0 ]]; then
            loginctl enable-linger "$(id -un)" || warn "enable-linger 失败，reboot 可能要再登录一次"
          else
            sudo loginctl enable-linger "$(id -un)" || warn "enable-linger 失败，reboot 可能要再登录一次"
          fi
        else
          warn "user systemd 且 Linger=no：没登录时不会拉起。有 root 时跑: loginctl enable-linger $(id -un)"
        fi
      fi
    fi
  fi

  sleep 0.6
  if systemd_cmd "$kind" is-active --quiet "$UNIT_NAME"; then
    info "systemd $kind  $UNIT_NAME  active  enabled=$(systemd_cmd "$kind" is-enabled "$UNIT_NAME" 2>/dev/null || true)"
    info "Base URL http://${BIND}:${PORT}/v1   model $MODEL"
  else
    systemd_cmd "$kind" status "$UNIT_NAME" --no-pager -l | tail -30 || true
    die "systemd 启动失败"
  fi
}

uninstall_service() {
  local kind
  kind="$(systemd_kind)"
  if [[ "$kind" == none ]]; then
    info "没有安装 $UNIT_NAME"
    return
  fi
  have_systemd || die "没有 systemd"
  info "disable --now $UNIT_NAME  ($kind)"
  systemd_cmd "$kind" disable --now "$UNIT_NAME" || true
  if [[ "$kind" == system ]]; then
    rm_via "$SYSTEM_UNIT"
  else
    rm -f "$USER_UNIT"
  fi
  systemd_cmd "$kind" daemon-reload || true
  info "已卸载 unit。config / src 还在 $HOME_DIR"
}

pin_cline() {
  if [[ ! -f "$CLINE_PROVIDERS" ]]; then
    warn "没有 $CLINE_PROVIDERS —— Cline CLI 还没登录，跳过 --pin-cline"
    warn "登录后再跑: bash $0 --pin-cline"
    return 0
  fi
  python3 - "$CLINE_PROVIDERS" "$BIND" "$PORT" "$MODEL" <<'PY'
import json, os, shutil, sys, time
path, bind, port, model = sys.argv[1:5]
base = f"http://{bind}:{port}/v1"
with open(path, encoding="utf-8") as f:
    data = json.load(f)
provs = data.setdefault("providers", {})
if "cline-pass" not in provs:
    print("!!  providers.json 里没有 cline-pass，不新建（先 cline auth 再 --pin-cline）", file=sys.stderr)
    sys.exit(0)
st = provs["cline-pass"].setdefault("settings", {})
old_base = st.get("baseUrl")
old_model = st.get("model")
if old_base == base and old_model == model:
    print(f"cline     已指向 {base}  model {model}")
    sys.exit(0)
bak = path + ".bak-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
shutil.copy2(path, bak)
st["baseUrl"] = base
st["model"] = model
data["lastUsedProvider"] = "cline-pass"
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
os.chmod(path, 0o600)
print(f"cline     baseUrl {old_base!r} → {base}")
print(f"cline     model   {old_model!r} → {model}")
print(f"cline     backup  {bak}")
PY
}

DO_START=0
DO_DAEMON=0
DO_STOP=0
DO_STATUS=0
DO_PROBE=0
DO_PRINT=0
DO_INSTALL_SERVICE=0
DO_UNINSTALL_SERVICE=0
DO_PIN_CLINE=0
YES=0
NO_CLONE=0
DO_STATIC_KEY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) DO_START=1 ;;
    --daemon) DO_DAEMON=1 ;;
    --stop) DO_STOP=1 ;;
    --status) DO_STATUS=1 ;;
    --probe) DO_PROBE=1 ;;
    --print-config) DO_PRINT=1 ;;
    --install-service) DO_INSTALL_SERVICE=1 ;;
    --uninstall-service) DO_UNINSTALL_SERVICE=1 ;;
    --pin-cline) DO_PIN_CLINE=1 ;;
    --static-key) DO_STATIC_KEY=1 ;;
    --yes|-y) YES=1 ;;
    --no-clone) NO_CLONE=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知参数: $1  （--help）" ;;
  esac
  shift
done

if [[ "$DO_STATIC_KEY" == 1 ]]; then
  USE_OAUTH=0
fi

if [[ "$DO_UNINSTALL_SERVICE" == 1 ]]; then
  uninstall_service
  exit 0
fi
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

# 只改 Cline CLI 指向，不动 switcher 安装
if [[ "$DO_PIN_CLINE" == 1 && "$DO_START" != 1 && "$DO_DAEMON" != 1 && "$DO_INSTALL_SERVICE" != 1 ]]; then
  pin_cline
  exit 0
fi

need_cmd python3
need_cmd node
command -v git >/dev/null 2>&1 || die "缺少 git（用来拉 cline-pass-switcher）"
NODE_MAJ="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[[ "$NODE_MAJ" -ge 18 ]] || die "需要 Node.js ≥ 18，当前 $(node -v 2>/dev/null || echo unknown)"

clone_switcher
write_config

if [[ "$DO_INSTALL_SERVICE" == 1 ]]; then
  install_service
elif [[ "$DO_START" == 1 ]]; then
  start_fg
elif [[ "$DO_DAEMON" == 1 ]]; then
  start_daemon
else
  info "源码 $SRC_DIR"
  info "配置 $CONFIG_PATH"
  info "开机自启（推荐）："
  echo "  bash $0 --install-service"
  info "或临时后台："
  echo "  bash $0 --daemon"
  info "客户端："
  echo "  Base URL  http://${BIND}:${PORT}/v1"
  echo "  Model     $MODEL"
  echo "  API Key   控制台「访问与安全」的 proxyKey；本地空 = 不鉴权"
  info "Cline CLI 已登录时："
  echo "  bash $0 --pin-cline"
  if [[ "$USE_OAUTH" == 1 ]]; then
    info "先 cline auth 登录 Cline Pass。代理会读 ~/.cline 并自动续期，不要填 sk_。"
  else
    info "静态 key 模式：用 CLINE_PASS_KEY 或打开 http://${BIND}:${PORT}/ 填写。过期会 Unauthorized。"
  fi
  info "官方 /v1/models 不含 cline-pass/*，模型清单以本目录 examples/pi-models.json 为准。"
fi

if [[ "$DO_PIN_CLINE" == 1 ]]; then
  pin_cline
fi

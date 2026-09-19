#!/usr/bin/env bash
# setup-runanytime.sh
# 一键把本机 Grok CLI 接到 runanytime.hxi.me 的 grok-4.6（经 thinking-proxy）。
#
# 脚本会：
#   1. 备份 ~/.grok/config.toml 和 ~/.bashrc
#   2. 安装 thinking-proxy.py 到 ~/.grok/
#   3. 写入 grok-4.6 的 messages + 127.0.0.1:8899 配置
#   4. 在 ~/.bashrc 里写入 GROK_MODELS_BASE_URL（指向代理）
#      GROK_RELAY_API_KEY 若已有则保留，否则放占位符
#
# 你只需要：
#   nano ~/.bashrc          # 改 GROK_RELAY_API_KEY
#   source ~/.bashrc
#   ~/.grok/start-thinking-proxy.sh
#   grok -m grok-4.6
#
# 可选：
#   bash setup-runanytime.sh --start     配完后后台拉起代理
#   bash setup-runanytime.sh --no-bashrc 只写 ~/.grok，不动 bashrc
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GROK_DIR="${GROK_HOME:-$HOME/.grok}"
BASHRC="${HOME}/.bashrc"
UPSTREAM_HOST="${UPSTREAM_HOST:-runanytime.hxi.me}"
PROXY_PORT="${PROXY_PORT:-8899}"
MARKER_BEGIN="# >>> grok-cli runanytime >>>"
MARKER_END="# <<< grok-cli runanytime <<<"
PLACEHOLDER_KEY="你的runanytime密钥"

START_PROXY=0
TOUCH_BASHRC=1
for arg in "$@"; do
  case "$arg" in
    --start) START_PROXY=1 ;;
    --no-bashrc) TOUCH_BASHRC=0 ;;
    -h|--help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数: $arg  （支持 --start / --no-bashrc / --help）" >&2
      exit 1
      ;;
  esac
done

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令: $1" >&2
    exit 1
  fi
}

need python3
if ! command -v grok >/dev/null 2>&1; then
  echo "提示: 未找到 grok。配置仍会写好，装 CLI："
  echo "  curl -fsSL https://x.ai/cli/install.sh | bash"
fi

if [ ! -f "$HERE/thinking-proxy.py" ]; then
  echo "找不到 $HERE/thinking-proxy.py" >&2
  exit 1
fi
if [ ! -f "$HERE/examples/config.runanytime-thinking-proxy.toml" ]; then
  echo "找不到 $HERE/examples/config.runanytime-thinking-proxy.toml" >&2
  exit 1
fi

stamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$GROK_DIR"

backup() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "${f}.bak.${stamp}"
    echo "已备份 $f -> ${f}.bak.${stamp}"
  fi
}

backup "$GROK_DIR/config.toml"
if [ "$TOUCH_BASHRC" = 1 ]; then
  backup "$BASHRC"
fi

install -m 644 "$HERE/thinking-proxy.py" "$GROK_DIR/thinking-proxy.py"
if [ -f "$HERE/thinking-proxy.test.py" ]; then
  install -m 644 "$HERE/thinking-proxy.test.py" "$GROK_DIR/thinking-proxy.test.py"
fi
install -m 644 "$HERE/examples/config.runanytime-thinking-proxy.toml" \
  "$GROK_DIR/config.toml"

cat > "$GROK_DIR/start-thinking-proxy.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export UPSTREAM_HOST="\${UPSTREAM_HOST:-${UPSTREAM_HOST}}"
export PROXY_PORT="\${PROXY_PORT:-${PROXY_PORT}}"
cd "\$(dirname "\$0")"
echo "[start] http://127.0.0.1:\${PROXY_PORT} → https://\${UPSTREAM_HOST}"
exec python3 ./thinking-proxy.py
EOF
chmod 755 "$GROK_DIR/start-thinking-proxy.sh"

extract_existing_key() {
  local val=""
  if [ -n "${GROK_RELAY_API_KEY:-}" ] && [ "${GROK_RELAY_API_KEY}" != "$PLACEHOLDER_KEY" ]; then
    printf '%s' "$GROK_RELAY_API_KEY"
    return 0
  fi
  if [ -f "$BASHRC" ]; then
    val="$(
      python3 - "$BASHRC" "$PLACEHOLDER_KEY" <<'PY'
import re, sys
path, placeholder = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
# 优先取标记块里的值
block = re.search(
    r"# >>> grok-cli runanytime >>>.*?export GROK_RELAY_API_KEY=([^\n]+)",
    text, re.S)
candidates = []
if block:
    candidates.append(block.group(1))
for m in re.finditer(r'^\s*(?:export\s+)?GROK_RELAY_API_KEY=(.*)$', text, re.M):
    candidates.append(m.group(1))
def unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        s = s[1:-1]
    return s
for raw in candidates:
    v = unquote(raw)
    if v and v != placeholder:
        print(v)
        break
PY
    )"
  fi
  printf '%s' "${val:-}"
}

EXISTING_KEY="$(extract_existing_key || true)"
KEY_TO_WRITE="${EXISTING_KEY:-$PLACEHOLDER_KEY}"

if [ "$TOUCH_BASHRC" = 1 ]; then
  touch "$BASHRC"
  python3 - "$BASHRC" "$KEY_TO_WRITE" "$PROXY_PORT" "$MARKER_BEGIN" "$MARKER_END" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
key, port, begin, end = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
text = re.sub(
    re.escape(begin) + r".*?" + re.escape(end) + r"\n?",
    "",
    text,
    flags=re.S,
)

# 注释掉标记块外旧的 GROK_* 行，避免和末尾新块抢先后顺序
def comment_old(line):
    stripped = line.lstrip()
    if stripped.startswith("#"):
        return line
    if re.match(r"\s*(export\s+)?GROK_(RELAY_API_KEY|MODELS_BASE_URL)=", line):
        if line.endswith("\n"):
            return "# " + line[:-1].lstrip() + "  # superseded by grok-cli runanytime\n"
        return "# " + line.lstrip() + "  # superseded by grok-cli runanytime"
    return line

text = "".join(comment_old(line) for line in text.splitlines(keepends=True))
quoted = "'" + key.replace("'", "'\\''") + "'"
block = (
    begin + "\n"
    "# Grok CLI -> thinking-proxy -> runanytime.hxi.me\n"
    "# 只改下一行的 Key。GROK_MODELS_BASE_URL 必须指向本机代理，不要改回网关。\n"
    "export GROK_RELAY_API_KEY=" + quoted + "\n"
    "export GROK_MODELS_BASE_URL='http://127.0.0.1:" + port + "/v1'\n"
    + end + "\n"
)
if text and not text.endswith("\n"):
    text += "\n"
path.write_text(text + "\n" + block, encoding="utf-8")
PY
  echo "已更新 $BASHRC （标记块 grok-cli runanytime）"
fi

proxy_running() {
  python3 - "$PROXY_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
}

if [ "$START_PROXY" = 1 ]; then
  if proxy_running; then
    echo "代理已在 127.0.0.1:${PROXY_PORT} 监听，跳过启动"
  else
    nohup python3 "$GROK_DIR/thinking-proxy.py" \
      >> "$GROK_DIR/thinking-proxy.log" 2>&1 &
    echo $! > "$GROK_DIR/thinking-proxy.pid"
    sleep 0.3
    if proxy_running; then
      echo "已后台启动 thinking-proxy  pid=$(cat "$GROK_DIR/thinking-proxy.pid")"
    else
      echo "代理启动失败，看 $GROK_DIR/thinking-proxy.log" >&2
      exit 1
    fi
  fi
fi

echo
echo "========== 已完成 =========="
echo "  配置: $GROK_DIR/config.toml"
echo "  代理脚本: $GROK_DIR/thinking-proxy.py"
echo "  启动: $GROK_DIR/start-thinking-proxy.sh"
if [ "$KEY_TO_WRITE" = "$PLACEHOLDER_KEY" ]; then
  echo
  echo "下一步（只改 Key）："
  echo "  1. nano ~/.bashrc"
  echo "     找到 GROK_RELAY_API_KEY，把「${PLACEHOLDER_KEY}」换成 runanytime 的 sk"
  echo "  2. source ~/.bashrc"
  echo "  3. ~/.grok/start-thinking-proxy.sh    # 另开一个终端常驻"
  echo "  4. grok -m grok-4.6"
else
  echo "  已保留现有 GROK_RELAY_API_KEY（未写入仓库、未打印全文）"
  echo
  echo "下一步："
  echo "  source ~/.bashrc"
  if [ "$START_PROXY" != 1 ]; then
    echo "  ~/.grok/start-thinking-proxy.sh    # 另开一个终端常驻"
  fi
  echo "  grok -m grok-4.6"
fi
echo
echo "说明：不接 thinking-proxy 时 Grok CLI 打这个站的 grok-4.6 会直接报错。"
echo "      代理窗口不能关。换 Key 只改 ~/.bashrc 里那一行即可。"

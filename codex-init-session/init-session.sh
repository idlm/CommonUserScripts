#!/usr/bin/env bash
# Codex 开会话：向 anyrouter.top 发 init，成功才打印回话 ID。
#
# 针对 anyrouter（New API）的实测结论（2026-09-19, Codex CLI 0.155.1）：
#   - 高峰时 /v1/responses 直接 500：当前模型 gpt-6-astra 负载已经达到上限
#     (new_api_error / get_channel_failed)
#   - Codex 把同一错误翻成 TUI/JSONL：
#       Reconnecting... N/5 (We're currently experiencing high demand...)
#       turn.failed + last_agent_message=None
#   - 会话 thread 会先建出来。有 thread_id ≠ init 成功。
#   - 并行多开会话只会把同一条满载通道打得更满。
#   - 换 chat/completions、换 Claude 模型名挤不进去：anyrouter 的 Codex
#     通道只认配置里的 responses 模型。
#   - 最好的挤法：廉价 HTTP 探针 → 通了再单发 codex exec --json →
#     失败退避。不要先开 TUI 再撞 5 次重连。
#
# 默认模式（--exec，推荐）：
#   1. 用 ~/.codex/auth.json 的 ANY_API_KEY（或 OPENAI_API_KEY）探
#      {base_url}/responses，模型默认 gpt-6-astra
#   2. 过载/429/5xx → 等 --wait 秒（默认 120），不启动 Codex
#   3. 探针通过或 --no-probe → 单发：
#        codex exec --json --skip-git-repo-check --color never \
#          -C DIR --sandbox workspace-write -c 'approval_policy="never"' \
#          -m MODEL "init"
#   4. JSONL 出现 turn.completed 且有助手消息才算成功
#   5. 打印 SESSION_ID；可选再塞 task.md（同一 exec 会话 resume）
#
# 兼容模式（--tui）：旧的 screen + 交互式 TUI 路径，留给必须盯屏幕的场景。
set -uo pipefail

WAIT_SECS="${WAIT_SECS:-120}"
WORKDIR="${WORKDIR:-$(pwd)}"
TASK_FILE=""
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"
RUN_TASK=1
AFTER_WAIT=0
CODEX_BIN="${CODEX_BIN:-codex}"
OUT_DIR="${OUT_DIR:-$HOME/.codex/init-session}"
SESSION_FILE=""
LOG_FILE=""
INIT_TIMEOUT="${INIT_TIMEOUT:-180}"
SCREEN_NAME=""
MODE="${MODE:-exec}"
MODEL="${MODEL:-}"
PROVIDER="${PROVIDER:-}"
PROBE=1
PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"
JITTER_SECS="${JITTER_SECS:-15}"
SANDBOX_MODE="${SANDBOX_MODE:-workspace-write}"

usage() {
  cat <<'EOF'
用法:
  init-session.sh [选项]

默认（--exec，针对 anyrouter.top）:
  1. 廉价探 /v1/responses；过载就等，不启动 Codex
  2. 单发:  codex exec --json ... "init"
  3. 只有 turn.completed + 助手回复才算成功，才打印回话 ID
  4. 有 thread_id 但 turn.failed 不算成功

选项:
  -C DIR          工作目录（默认当前目录）
  --task FILE     task.md 路径（默认: DIR/task.md）
  --wait SEC      失败重试间隔，默认 120
  --timeout SEC   单次 init 最长等待，默认 180
  --model NAME    覆盖模型（默认读 ~/.codex/config.toml 的 model）
  --provider NAME 覆盖 model_provider（默认读 config.toml）
  --no-probe      跳过 HTTP 探针，直接 exec（不推荐高峰期）
  --probe-only    只探 /v1/responses，不启动 Codex；0=通，2=过载，3=致命
  --exec          非交互 JSONL（默认，anyrouter 推荐）
  --tui           旧路径：screen + 交互式 TUI
  --no-task       init 成功后不跑 task.md
  --after-wait    init 成功且不跑 task.md 时，再额外等一轮
  --no-after-wait 默认行为；保留兼容
  --max N         最多尝试 N 次 init，0=无限
  --out FILE      成功后把会话 ID 写到这个文件
  --name NAME     --tui 时的 screen 名
  --jitter SEC    重试额外随机抖动上限，默认 15
  --self-test     不联网，用样例 JSONL 校验成功/失败判定
  -h, --help      帮助

一键:
  curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
    | bash -s -- -C "$(pwd)" --no-task

示例:
  ./init-session.sh -C /path/to/proj --no-task
  ./init-session.sh -C /path/to/proj --max 12 --wait 120
  ./init-session.sh -C /path/to/proj --tui          # 旧交互式路径
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -C) WORKDIR="$2"; shift 2 ;;
    --task) TASK_FILE="$2"; shift 2 ;;
    --wait) WAIT_SECS="$2"; shift 2 ;;
    --timeout) INIT_TIMEOUT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --no-probe) PROBE=0; shift ;;
    --probe-only) MODE=probe; shift ;;
    --exec) MODE=exec; shift ;;
    --tui) MODE=tui; shift ;;
    --no-task) RUN_TASK=0; shift ;;
    --after-wait) AFTER_WAIT=1; shift ;;
    --no-after-wait) AFTER_WAIT=0; shift ;;
    --max) MAX_ATTEMPTS="$2"; shift 2 ;;
    --out) SESSION_FILE="$2"; shift 2 ;;
    --name) SCREEN_NAME="$2"; shift 2 ;;
    --jitter) JITTER_SECS="$2"; shift 2 ;;
    --self-test) MODE=selftest; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }
if [ "$MODE" != "probe" ] && [ "$MODE" != "selftest" ]; then
  command -v "$CODEX_BIN" >/dev/null || { echo "找不到 codex: $CODEX_BIN" >&2; exit 1; }
  command -v timeout >/dev/null || { echo "需要 GNU timeout（coreutils）" >&2; exit 1; }
fi
if [ "$MODE" = "tui" ]; then
  command -v screen >/dev/null || { echo "--tui 需要 screen" >&2; exit 1; }
fi

WORKDIR="$(cd "$WORKDIR" && pwd)" || { echo "工作目录不存在: $WORKDIR" >&2; exit 1; }
[ -n "$TASK_FILE" ] || TASK_FILE="$WORKDIR/task.md"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_FILE:-$OUT_DIR/run-$STAMP.log}"
[ -n "$SESSION_FILE" ] || SESSION_FILE="$OUT_DIR/last-session-id.txt"
ATTEMPT_DIR="$OUT_DIR/attempts"
mkdir -p "$ATTEMPT_DIR"
SCREEN_FILE="$OUT_DIR/last-screen.txt"
LAST_JSONL="$OUT_DIR/last-exec.jsonl"
LAST_ERR="$OUT_DIR/last-exec.err"
LAST_MSG="$OUT_DIR/last-message.txt"

say() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

fmt_dur() {
  local s=$1 h m
  [ "$s" -lt 0 ] && s=0
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  else printf '%dm%02ds' "$m" "$((s % 60))"
  fi
}

wait_retry() {
  local extra=0
  if [ "${JITTER_SECS:-0}" -gt 0 ] 2>/dev/null; then
    extra=$((RANDOM % (JITTER_SECS + 1)))
  fi
  local left=$((WAIT_SECS + extra))
  say "等待 $(fmt_dur "$left") 后重试（基线 $(fmt_dur "$WAIT_SECS") + jitter ${extra}s）…"
  while [ "$left" -gt 0 ]; do
    step=30
    [ "$step" -gt "$left" ] && step=$left
    sleep "$step"
    left=$((left - step))
    [ "$left" -gt 0 ] && say "还剩 $(fmt_dur "$left")"
  done
}

load_codex_settings() {
  python3 - "$MODEL" "$PROVIDER" <<'PY'
import re, sys
from pathlib import Path
cli_model, cli_provider = sys.argv[1], sys.argv[2]
cfg = Path.home() / ".codex" / "config.toml"
text = cfg.read_text(encoding="utf-8", errors="replace") if cfg.exists() else ""

def top_level(key):
    m = re.search(rf'(?m)^\s*{re.escape(key)}\s*=\s*"([^"]+)"', text)
    return m.group(1) if m else ""

provider = cli_provider or top_level("model_provider") or "any"
model = cli_model or top_level("model") or "gpt-6-astra"
base_url = ""
env_key = ""
sec = re.search(
    rf'(?ms)^\[model_providers\.{re.escape(provider)}\](.*?)(?=^\[|\Z)',
    text,
)
if sec:
    body = sec.group(1)
    m = re.search(r'(?m)^\s*base_url\s*=\s*"([^"]+)"', body)
    if m:
        base_url = m.group(1).rstrip("/")
    m = re.search(r'(?m)^\s*(?:temp_env_key|env_key)\s*=\s*"([^"]+)"', body)
    if m:
        env_key = m.group(1)
    m = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"', body)
    if m and not cli_model and not top_level("model"):
        model = m.group(1)
if not base_url:
    base_url = "https://anyrouter.top/v1"
print(provider)
print(model)
print(base_url)
print(env_key)
PY
}

read_api_key() {
  local env_name="$1"
  python3 - "$env_name" <<'PY'
import json, os, sys
from pathlib import Path
name = sys.argv[1]
val = os.environ.get(name) or ""
auth = Path.home() / ".codex" / "auth.json"
if not val and auth.exists():
    try:
        data = json.loads(auth.read_text(encoding="utf-8"))
    except Exception:
        data = {}
    if isinstance(data, dict):
        for k in (name, "ANY_API_KEY", "OPENAI_API_KEY"):
            v = data.get(k)
            if isinstance(v, str) and v.strip():
                val = v.strip()
                break
print(val)
PY
}

probe_anyrouter() {
  local key="$1" base="$2" model="$3"
  python3 - "$key" "$base" "$model" "$PROBE_TIMEOUT" <<'PY'
import json, sys, urllib.error, urllib.request

def overloaded(blob: str) -> bool:
    s = blob.lower()
    ascii_keys = (
        "get_channel_failed", "high demand", "temporarily overloaded",
        "no available channel", "usage_limit_reached", "model_cooldown",
        "too many requests", "server_overloaded", "internal_server_error",
        "server error",
    )
    cjk_keys = ("负载已经达到上限", "请稍后重试", "无可用渠道")
    return any(k in s for k in ascii_keys) or any(k in blob for k in cjk_keys)

def fatal_auth(blob: str) -> bool:
    s = blob.lower()
    return any(k in s for k in (
        "invalid api key", "unauthorized", "authentication",
        "未提供令牌", "无效的令牌", "不支持所选模型",
    )) or any(k in blob for k in ("未提供令牌", "无效的令牌", "不支持所选模型"))

def classify(http: int, blob: str) -> str:
    if fatal_auth(blob) or http in (401, 403):
        return "fatal"
    if overloaded(blob) or http in (408, 409, 425, 429) or http >= 500:
        return "overload"
    if http == 404:
        return "fatal"
    return "fatal"

key, base, model, timeout = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3], float(sys.argv[4])
url = base + "/responses"
body = json.dumps({
    "model": model,
    "input": "ping",
    "store": False,
    "max_output_tokens": 16,
}).encode()
req = urllib.request.Request(
    url, data=body,
    headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        try:
            d = json.loads(raw)
        except Exception:
            print("ok\n%s\n" % r.status)
            raise SystemExit
        err = d.get("error") if isinstance(d, dict) else None
        if err:
            msg = err.get("message") if isinstance(err, dict) else str(err)
            blob = json.dumps(d, ensure_ascii=False)
            kind = classify(int(r.status), blob)
            print("%s\n%s\n%s" % (kind, r.status, (msg or "")[:240].replace("\n", " ")))
        else:
            print("ok\n%s\n%s" % (r.status, d.get("status") or ""))
except urllib.error.HTTPError as e:
    raw = e.read().decode("utf-8", "replace")
    kind = classify(int(e.code), raw)
    print("%s\n%s\n%s" % (kind, e.code, raw[:240].replace("\n", " ")))
except Exception as e:
    print("retry\n0\n%s" % (f"{type(e).__name__}: {e}"[:240].replace("\n", " ")))
PY
}

parse_exec_jsonl() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path
jsonl, last_path = Path(sys.argv[1]), Path(sys.argv[2])
tid = None
completed = False
failed = None
fatal = False
retryable = False
texts = []

def mark_retry(msg: str):
    global retryable
    s = (msg or "").lower()
    keys = (
        "high demand", "reconnecting", "temporary errors",
        "get_channel_failed", "overloaded", "too many requests",
        "usage_limit", "model_cooldown", "internal_server_error",
        "负载已经达到上限", "请稍后重试", "无可用渠道",
    )
    blob = msg or ""
    if any(k in s for k in keys if k.isascii()) or any(k in blob for k in ("负载已经达到上限", "请稍后重试", "无可用渠道")):
        retryable = True

if jsonl.exists():
    for line in jsonl.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        t = ev.get("type")
        if t == "thread.started":
            tid = ev.get("thread_id") or tid
        if t == "turn.completed":
            completed = True
        if t == "turn.failed":
            failed = ((ev.get("error") or {}) or {}).get("message") or "turn.failed"
            mark_retry(failed)
        if t == "error":
            msg = ev.get("message") or ""
            mark_retry(msg)
            if any(x in msg.lower() for x in ("invalid api key", "unauthorized", "未提供令牌", "无效的令牌")) \
               or any(x in msg for x in ("未提供令牌", "无效的令牌")):
                fatal = True
            if "不支持所选模型" in msg or "model metadata" in msg.lower():
                fatal = True
        item = ev.get("item") if isinstance(ev.get("item"), dict) else {}
        if t == "item.completed" and item.get("type") in ("agent_message", "message"):
            txt = item.get("text") or ""
            if not txt:
                content = item.get("content")
                if isinstance(content, str):
                    txt = content
                elif isinstance(content, list):
                    parts = []
                    for c in content:
                        if isinstance(c, dict) and c.get("type") in ("output_text", "text"):
                            parts.append(c.get("text") or "")
                    txt = "".join(parts)
            if txt:
                texts.append(txt)

last = last_path.read_text(encoding="utf-8", errors="replace").strip() if last_path.exists() else ""
if last:
    texts.append(last)
assistant = "\n".join(t for t in texts if t).strip()
ok = bool(completed and tid and assistant and not failed)
if ok:
    kind = "success"
elif fatal:
    kind = "fatal"
elif retryable or failed:
    kind = "retryable"
else:
    kind = "retryable"
print(kind)
print(tid or "")
print(failed or "")
print(assistant.replace("\n", "\\n")[:800])
PY
}

print_success() {
  local sid="$1" extra="$2"
  printf '%s\n' "$sid" >"$SESSION_FILE"
  printf '%s\n' "$sid" >"$WORKDIR/.codex-init-session-id"
  {
    echo
    echo "========================================"
    echo "Codex 会话已就绪"
    echo "SESSION_ID=$sid"
    [ -n "$extra" ] && echo "$extra"
    echo "工作目录: $WORKDIR"
    echo "日志: $LOG_FILE"
    echo "会话文件: $SESSION_FILE"
    echo "========================================"
  } | tee -a "$LOG_FILE"
}

# ---------- TUI 兼容路径 ----------
screen_alive() {
  screen -ls 2>/dev/null | grep -qE "[0-9]+\.${1}[[:space:]]"
}

kill_screen() {
  local name="$1"
  screen_alive "$name" || return 0
  screen -S "$name" -X quit >/dev/null 2>&1 || true
  sleep 0.4
  if screen_alive "$name"; then
    pkill -f "SCREEN.*${name}" >/dev/null 2>&1 || true
  fi
}

stuff() {
  local name="$1" text="$2"
  python3 - "$name" "$text" <<'PY'
import sys, subprocess, time
name, text = sys.argv[1], sys.argv[2]
chunk = 80
i = 0
while i < len(text):
    part = text[i:i+chunk]
    subprocess.run(["screen", "-S", name, "-X", "stuff", part], check=False)
    i += chunk
    time.sleep(0.05)
subprocess.run(["screen", "-S", name, "-X", "stuff", "\r"], check=False)
PY
}

strip_ansi_and_classify() {
  python3 - "$1" <<'PY'
import re, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace") if Path(sys.argv[1]).exists() else ""
text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()].|\x0f|\x0e", "", raw)
text = text.replace("\r", "\n")
low = text.lower()
compact = re.sub(r"\s+", " ", low)

high = any(s in compact for s in [
    "we're currently experiencing high demand",
    "currently experiencing high demand",
    "which may cause temporary errors",
    "may cause temporary errors",
    "get_channel_failed",
]) or ("负载已经达到上限" in text) or ("无可用渠道" in text)
reconnecting = "reconnecting" in compact
usage = any(s in compact for s in [
    "hit your usage limit",
    "usage limit",
    "429 too many requests",
    "exceeded retry limit",
    "usage_limit_reached",
    "model_cooldown",
])
ready = any(s in compact for s in [
    "ask codex to do anything",
]) or "›" in text
success = any(s in compact for s in [
    "initialized at",
    "detected git repositories",
    "no `/home/agents.md`",
    "no agents.md",
    "tell me which project",
    "what you’d like done",
    "what you'd like done",
    "i'm ready",
    "i am ready",
    "ready to work",
])
working = any(s in compact for s in [
    "thinking",
    "ran for",
    "explored",
    "edited ",
    "listed ",
]) and not reconnecting and not high

m = re.search(r"reconnecting\D{0,12}([1-5])\s*/\s*5", compact)
retry_n = int(m.group(1)) if m else 0

if high or usage:
    print("retryable")
elif reconnecting and (high or retry_n >= 2):
    print("retryable")
elif reconnecting and retry_n >= 5:
    print("retryable")
elif success and not high and not reconnecting:
    print("success")
elif working:
    print("wait")
elif ready:
    print("ready")
else:
    print("wait")
PY
}

dump_tui() {
  local name="$1" tui_log="$2" out="$3"
  local hc
  hc="$(mktemp)"
  screen -S "$name" -X hardcopy -h "$hc" >/dev/null 2>&1 || true
  sleep 0.2
  {
    echo "===== logfile ====="
    [ -f "$tui_log" ] && cat "$tui_log"
    echo
    echo "===== hardcopy ====="
    [ -f "$hc" ] && tr -d '\000' < "$hc"
  } >"$out" 2>/dev/null || true
  rm -f "$hc"
}

classify_tui() {
  local name="$1" tui_log="$2"
  local snap="$ATTEMPT_DIR/last-snap.txt"
  dump_tui "$name" "$tui_log" "$snap"
  strip_ansi_and_classify "$snap"
}

extract_id() {
  python3 - "$1" <<'PY'
import json, re, sys
from pathlib import Path
uuid_re = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)
ulidish = re.compile(r"\b01[0-9a-f]{6}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)
found = []
p = Path(sys.argv[1])
if p.exists():
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            o = json.loads(line)
        except Exception:
            m = ulidish.search(line) or uuid_re.search(line)
            if m:
                found.append(m.group(0))
            continue
        payload = o.get("payload") if isinstance(o, dict) else None
        if isinstance(payload, dict):
            for k in ("session_id", "id", "thread_id"):
                v = payload.get(k)
                if isinstance(v, str) and (ulidish.fullmatch(v) or uuid_re.fullmatch(v)):
                    found.append(v)
        if isinstance(o, dict) and isinstance(o.get("thread_id"), str):
            found.append(o["thread_id"])
        m = ulidish.search(p.name)
        if m:
            found.append(m.group(0))
print(found[-1] if found else "")
PY
}

newest_rollout() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path
cutoff = float(sys.argv[1])
root = Path.home() / ".codex" / "sessions"
best = None
best_mtime = 0.0
if root.exists():
    for p in root.rglob("rollout-*.jsonl"):
        try:
            m = p.stat().st_mtime
        except OSError:
            continue
        if m >= cutoff - 2 and m >= best_mtime:
            best, best_mtime = p, m
print(str(best) if best else "")
PY
}

start_tui() {
  local name="$1" tui_log="$2"
  : >"$tui_log"
  screen -L -Logfile "$tui_log" -dmS "$name" \
    bash -lc "cd $(printf '%q' "$WORKDIR") && export TERM=xterm-256color && exec $(printf '%q' "$CODEX_BIN") --dangerously-bypass-approvals-and-sandbox -C $(printf '%q' "$WORKDIR") --no-alt-screen"
  sleep 0.5
  screen -S "$name" -X logfile flush 1 >/dev/null 2>&1 || true
  screen_alive "$name"
}

wait_status() {
  local name="$1" tui_log="$2" timeout="$3" want="$4"
  local start now elapsed st
  start="$(date +%s)"
  while :; do
    if ! screen_alive "$name"; then
      echo retryable
      return 0
    fi
    st="$(classify_tui "$name" "$tui_log")"
    case "$st" in
      retryable) echo retryable; return 0 ;;
      success) echo success; return 0 ;;
      ready)
        if [ "$want" = "ready" ]; then echo ready; return 0; fi
        ;;
    esac
    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo timeout
      return 0
    fi
    sleep 2
  done
}

run_tui_loop() {
  local attempt=0 session_id="" live_screen=""
  if [ "$PROBE" = "1" ]; then
    load_runtime
    say "tui 模式仍先探 /v1/responses，过载不开 screen"
  fi
  while :; do
    attempt=$((attempt + 1))
    if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
      say "已达 init 尝试上限 $MAX_ATTEMPTS，放弃"
      exit 2
    fi
    if [ "$PROBE" = "1" ]; then
      probe_out="$(probe_anyrouter "$API_KEY_R" "$BASE_URL_R" "$MODEL_R")"
      probe_kind="$(printf '%s\n' "$probe_out" | sed -n '1p')"
      probe_http="$(printf '%s\n' "$probe_out" | sed -n '2p')"
      probe_msg="$(printf '%s\n' "$probe_out" | sed -n '3p')"
      say "探针: kind=$probe_kind http=$probe_http msg=${probe_msg:0:180}"
      case "$probe_kind" in
        ok) ;;
        overload|retry)
          say "上游过载，不开 TUI"
          wait_retry
          continue
          ;;
        fatal)
          say "探针判定为不可重试错误，停止。检查 Key / 模型 / 渠道。"
          exit 3
          ;;
        *)
          wait_retry
          continue
          ;;
      esac
    fi
    tag="init-$(date +%Y%m%d-%H%M%S)-$attempt"
    live_screen="${SCREEN_NAME:-codex-init-$STAMP-$attempt}"
    tui_log="$ATTEMPT_DIR/${tag}-tui.log"
    say "第 $attempt 次（tui）：新开 TUI 会话 $live_screen 并发送 init"

    if screen_alive "$live_screen"; then
      say "screen 名 $live_screen 已存在，先关掉"
      kill_screen "$live_screen"
    fi

    before="$(date +%s)"
    if ! start_tui "$live_screen" "$tui_log"; then
      say "screen 启动失败，等后再试"
      wait_retry
      continue
    fi

    st="$(wait_status "$live_screen" "$tui_log" 60 ready)"
    if [ "$st" = "retryable" ]; then
      say "启动阶段就碰到高峰/重连错误，关掉这次会话"
      kill_screen "$live_screen"
      wait_retry
      continue
    fi
    if [ "$st" != "ready" ] && [ "$st" != "success" ]; then
      say "未明确看到输入框，仍然发送 init（当前状态: $st）"
    fi

    stuff "$live_screen" "init"
    say "已向 TUI 发送: init"

    st="$(wait_status "$live_screen" "$tui_log" "$INIT_TIMEOUT" success)"
    rollout="$(newest_rollout "$before")"
    session_id=""
    [ -n "$rollout" ] && session_id="$(extract_id "$rollout")"
    say "判定=$st session_id=${session_id:-<空>} rollout=${rollout:-<无>}"

    if [ "$st" = "retryable" ] || [ "$st" = "timeout" ]; then
      say "判定为高峰/重连/超时错误，关掉这次会话后重开"
      kill_screen "$live_screen"
      wait_retry
      continue
    fi
    if [ "$st" != "success" ]; then
      st="$(classify_tui "$live_screen" "$tui_log")"
    fi
    if [ "$st" != "success" ]; then
      say "init 没有成功迹象（有 thread 也不算），关掉这次会话后重开"
      kill_screen "$live_screen"
      wait_retry
      continue
    fi
    if [ -z "$session_id" ]; then
      sleep 2
      rollout="$(newest_rollout "$before")"
      [ -n "$rollout" ] && session_id="$(extract_id "$rollout")"
    fi
    if [ -z "$session_id" ]; then
      say "init 看起来成功，但没解析到会话 ID，关掉后重开"
      kill_screen "$live_screen"
      wait_retry
      continue
    fi
    say "init 成功: $session_id  (screen $live_screen)"
    printf '%s\n' "$live_screen" >"$SCREEN_FILE"
    if [ "$RUN_TASK" = "1" ] && [ -f "$TASK_FILE" ]; then
      task_prompt="请严格按照文件执行任务：${TASK_FILE}。先完整阅读该文件，按其中步骤顺序执行直到做完。不要另起新会话，就在当前会话继续。完成后用简短中文汇报做了什么、还有什么没做完。"
      say "向同一 TUI 发送 task.md 指令"
      stuff "$live_screen" "$task_prompt"
    elif [ "$AFTER_WAIT" = "1" ]; then
      say "没有可执行的 task.md，按约定再等 $(fmt_dur "$WAIT_SECS")"
      wait_retry
    fi
    print_success "$session_id" "SCREEN=$live_screen"$'\n'"进入 TUI:  screen -r $live_screen"
    echo "$session_id"
    exit 0
  done
}

run_exec_once() {
  local model="$1"
  : >"$LAST_JSONL"
  : >"$LAST_ERR"
  rm -f "$LAST_MSG"
  # stdin 必须断开，否则 CLI 会打印 Reading additional input from stdin...
  # 不要同时给 --sandbox 和 --approve-for-me（互斥）。
  # 不要用 -a never（0.155 的 exec 没有这个 flag）。
  timeout "$INIT_TIMEOUT" "$CODEX_BIN" exec \
    --json --skip-git-repo-check --color never \
    -C "$WORKDIR" \
    --sandbox "$SANDBOX_MODE" \
    -c 'approval_policy="never"' \
    -m "$model" \
    -o "$LAST_MSG" \
    "init" </dev/null >"$LAST_JSONL" 2>"$LAST_ERR"
}

load_runtime() {
  local settings
  settings="$(load_codex_settings)"
  PROVIDER_R="$(printf '%s\n' "$settings" | sed -n '1p')"
  MODEL_R="$(printf '%s\n' "$settings" | sed -n '2p')"
  BASE_URL_R="$(printf '%s\n' "$settings" | sed -n '3p')"
  ENV_KEY_R="$(printf '%s\n' "$settings" | sed -n '4p')"
  [ -n "$ENV_KEY_R" ] || ENV_KEY_R="ANY_API_KEY"
  API_KEY_R="$(read_api_key "$ENV_KEY_R")"
  if [ -z "$API_KEY_R" ]; then
    say "找不到 API Key（环境变量 $ENV_KEY_R / ANY_API_KEY / OPENAI_API_KEY 或 ~/.codex/auth.json）"
    exit 1
  fi
  export ANY_API_KEY="$API_KEY_R"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-$API_KEY_R}"
  export "$ENV_KEY_R=$API_KEY_R"
}

run_probe_only() {
  load_runtime
  say "模式: probe-only"
  say "provider=$PROVIDER_R model=$MODEL_R base_url=$BASE_URL_R"
  probe_out="$(probe_anyrouter "$API_KEY_R" "$BASE_URL_R" "$MODEL_R")"
  probe_kind="$(printf '%s\n' "$probe_out" | sed -n '1p')"
  probe_http="$(printf '%s\n' "$probe_out" | sed -n '2p')"
  probe_msg="$(printf '%s\n' "$probe_out" | sed -n '3p')"
  say "探针: kind=$probe_kind http=$probe_http msg=${probe_msg:0:180}"
  case "$probe_kind" in
    ok) exit 0 ;;
    overload|retry) exit 2 ;;
    *) exit 3 ;;
  esac
}

run_exec_loop() {
  load_runtime
  local provider="$PROVIDER_R" model="$MODEL_R" base_url="$BASE_URL_R" api_key="$API_KEY_R"

  say "模式: exec（anyrouter 推荐）"
  say "provider=$provider model=$model base_url=$base_url"

  local attempt=0
  while :; do
    attempt=$((attempt + 1))
    if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
      say "已达 init 尝试上限 $MAX_ATTEMPTS，放弃"
      exit 2
    fi
    say "第 $attempt 次（exec）"

    if [ "$PROBE" = "1" ]; then
      probe_out="$(probe_anyrouter "$api_key" "$base_url" "$model")"
      probe_kind="$(printf '%s\n' "$probe_out" | sed -n '1p')"
      probe_http="$(printf '%s\n' "$probe_out" | sed -n '2p')"
      probe_msg="$(printf '%s\n' "$probe_out" | sed -n '3p')"
      say "探针: kind=$probe_kind http=$probe_http msg=${probe_msg:0:180}"
      case "$probe_kind" in
        ok) ;;
        overload|retry)
          say "上游过载/瞬时失败，不启动 Codex（避免 5 次 Reconnecting 打满通道）"
          wait_retry
          continue
          ;;
        fatal)
          say "探针判定为不可重试错误，停止。检查 Key / 模型 / 渠道。"
          exit 3
          ;;
        *)
          say "探针未知结果，按过载退避"
          wait_retry
          continue
          ;;
      esac
    fi

    set +e
    run_exec_once "$model"
    exec_rc=$?
    set -uo pipefail
    cp "$LAST_JSONL" "$ATTEMPT_DIR/exec-$attempt.jsonl" 2>/dev/null || true
    parsed="$(parse_exec_jsonl "$LAST_JSONL" "$LAST_MSG")"
    kind="$(printf '%s\n' "$parsed" | sed -n '1p')"
    tid="$(printf '%s\n' "$parsed" | sed -n '2p')"
    failmsg="$(printf '%s\n' "$parsed" | sed -n '3p')"
    assistant="$(printf '%s\n' "$parsed" | sed -n '4p')"
    say "exec_rc=$exec_rc kind=$kind thread_id=${tid:-<空>} fail=${failmsg:0:160}"

    case "$kind" in
      success)
        if [ "$RUN_TASK" = "1" ] && [ -f "$TASK_FILE" ]; then
          say "init 成功，resume 同一会话执行 task.md"
          task_prompt="请严格按照文件执行任务：${TASK_FILE}。先完整阅读该文件，按其中步骤顺序执行直到做完。不要另起新会话，就在当前会话继续。完成后用简短中文汇报做了什么、还有什么没做完。"
          timeout "$INIT_TIMEOUT" "$CODEX_BIN" exec resume "$tid" \
            --json --skip-git-repo-check --color never \
            -c 'approval_policy="never"' \
            -o "$OUT_DIR/last-task-message.txt" \
            "$task_prompt" </dev/null >>"$LAST_JSONL" 2>>"$LAST_ERR" || true
        elif [ "$AFTER_WAIT" = "1" ]; then
          say "没有可执行的 task.md，按约定再等 $(fmt_dur "$WAIT_SECS")"
          wait_retry
        fi
        print_success "$tid" "MODE=exec"$'\n'"续跑: codex exec resume $tid"
        echo "$tid"
        exit 0
        ;;
      fatal)
        say "不可重试失败（Key / 模型 / 鉴权）。thread_id=${tid:-<空>} 不算成功。"
        exit 3
        ;;
      *)
        say "init 未成功（有 thread_id 也不报告）。退避后单发重试，不开并行窗口。"
        wait_retry
        ;;
    esac
  done
}

run_self_test() {
  local tmp dir fail=0
  tmp="$(mktemp -d)"
  dir="$tmp"

  write_case() {
    printf '%s\n' "$1" >"$dir/in.jsonl"
    : >"$dir/last.txt"
    [ -n "${2:-}" ] && printf '%s\n' "$2" >"$dir/last.txt"
  }

  expect() {
    local want="$1" label="$2"
    local got
    got="$(parse_exec_jsonl "$dir/in.jsonl" "$dir/last.txt" | sed -n '1p')"
    if [ "$got" = "$want" ]; then
      echo "ok  $label -> $got"
    else
      echo "FAIL $label: want=$want got=$got" >&2
      fail=1
    fi
  }

  write_case '{"type":"thread.started","thread_id":"01aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
{"type":"turn.started"}
{"type":"item.completed","item":{"type":"agent_message","text":"initialized at /tmp"}}
{"type":"turn.completed"}'
  expect success "turn.completed + 助手消息"

  write_case '{"type":"thread.started","thread_id":"01aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
{"type":"turn.started"}
{"type":"error","message":"Reconnecting... 1/5 (We’re currently experiencing high demand, which may cause temporary errors.)"}
{"type":"turn.failed","error":{"message":"We’re currently experiencing high demand, which may cause temporary errors."}}'
  expect retryable "JSONL high demand / turn.failed（有 thread 也不算成功）"

  write_case '{"type":"thread.started","thread_id":"01aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
{"type":"error","message":"Invalid API key"}'
  expect fatal "Invalid API key"

  write_case '{"type":"thread.started","thread_id":"01aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
{"type":"error","message":"当前模型 gpt-6-astra 负载已经达到上限，请稍后重试"}
{"type":"turn.failed","error":{"message":"get_channel_failed"}}'
  expect retryable "中文 new_api_error / 负载上限"

  write_case '{"type":"thread.started","thread_id":"01aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
{"type":"turn.started"}'
  expect retryable "只有 thread.started，无助手消息"

  rm -rf "$tmp"
  if [ "$fail" -ne 0 ]; then
    echo "self-test failed" >&2
    exit 1
  fi
  echo "self-test passed"
  exit 0
}

if [ "$MODE" = "selftest" ]; then
  run_self_test
fi

say "工作目录: $WORKDIR"
say "日志: $LOG_FILE"
say "重试间隔: $(fmt_dur "$WAIT_SECS")"
if [ "$RUN_TASK" = "1" ] && [ -f "$TASK_FILE" ]; then
  say "init 成功后将按: $TASK_FILE"
elif [ "$RUN_TASK" = "1" ]; then
  say "未找到 task.md"
else
  say "已关闭 task.md 执行"
fi

if [ "$MODE" = "tui" ]; then
  run_tui_loop
elif [ "$MODE" = "probe" ]; then
  run_probe_only
elif [ "$MODE" = "selftest" ]; then
  run_self_test
else
  run_exec_loop
fi

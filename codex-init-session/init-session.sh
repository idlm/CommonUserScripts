#!/usr/bin/env bash
# 用交互式 Codex TUI 新开会话，输入 init。
# 启动格式：codex --dangerously-bypass-approvals-and-sandbox
#
# 下面这种也算失败，等 5 分钟后重新开新会话：
#   › init
#   ◦ Reconnecting... 2/5 (8s • esc to interrupt)
#     └ We're currently experiencing high demand, which may
#       cause temporary errors.
#
# init 成功后：有 task.md 就在同一会话里按它跑；没有就再等 5 分钟。
# 成功时打印会话 ID，并写入文件。TUI 留在 screen 里，可 screen -r 进去。
set -uo pipefail

WAIT_SECS="${WAIT_SECS:-300}"
WORKDIR="${WORKDIR:-$(pwd)}"
TASK_FILE=""
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"
RUN_TASK=1
AFTER_WAIT=1
CODEX_BIN="${CODEX_BIN:-codex}"
OUT_DIR="${OUT_DIR:-$HOME/.codex/init-session}"
SESSION_FILE=""
LOG_FILE=""
INIT_TIMEOUT="${INIT_TIMEOUT:-180}"
SCREEN_NAME=""

usage() {
  cat <<'EOF'
用法:
  init-session.sh [选项]

行为:
  1. 新开交互式 Codex：codex --dangerously-bypass-approvals-and-sandbox
  2. 在 TUI 里输入 init
  3. 若出现高峰/重连错误（包括）
       Reconnecting... N/5
       We're currently experiencing high demand, which may cause temporary errors.
     关掉这次会话，等 5 分钟，再新开一个
  4. init 成功后：
       - 有 task.md → 同一会话里按 task.md 执行
       - 没有 → 再等 5 分钟
  5. 打印会话 ID；TUI 留在 screen 里

选项:
  -C DIR          工作目录（默认当前目录）
  --task FILE     task.md 路径（默认: DIR/task.md）
  --wait SEC      失败重试间隔，默认 300（5 分钟）
  --timeout SEC   单次 init 最长等待，默认 180
  --no-task       init 成功后不跑 task.md
  --no-after-wait init 成功且不跑 task.md 时，不再额外等 5 分钟
  --max N         最多尝试 N 次 init，0=无限
  --out FILE      成功后把会话 ID 写到这个文件
  --name NAME     screen 会话名（默认自动生成）
  -h, --help      帮助

一键:
  curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
    | bash -s -- -C "$(pwd)"

示例:
  ./init-session.sh -C /home
  ./init-session.sh -C /path/to/proj --task /path/to/proj/task.md

进去看 TUI:
  screen -r <screen名>
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -C) WORKDIR="$2"; shift 2 ;;
    --task) TASK_FILE="$2"; shift 2 ;;
    --wait) WAIT_SECS="$2"; shift 2 ;;
    --timeout) INIT_TIMEOUT="$2"; shift 2 ;;
    --no-task) RUN_TASK=0; shift ;;
    --no-after-wait) AFTER_WAIT=0; shift ;;
    --max) MAX_ATTEMPTS="$2"; shift 2 ;;
    --out) SESSION_FILE="$2"; shift 2 ;;
    --name) SCREEN_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

command -v "$CODEX_BIN" >/dev/null || { echo "找不到 codex: $CODEX_BIN" >&2; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }
command -v screen >/dev/null || { echo "需要 screen" >&2; exit 1; }

WORKDIR="$(cd "$WORKDIR" && pwd)" || { echo "工作目录不存在: $WORKDIR" >&2; exit 1; }
[ -n "$TASK_FILE" ] || TASK_FILE="$WORKDIR/task.md"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_FILE:-$OUT_DIR/run-$STAMP.log}"
[ -n "$SESSION_FILE" ] || SESSION_FILE="$OUT_DIR/last-session-id.txt"
ATTEMPT_DIR="$OUT_DIR/attempts"
mkdir -p "$ATTEMPT_DIR"
SCREEN_FILE="$OUT_DIR/last-screen.txt"

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
  local left=$WAIT_SECS step
  say "等待 $(fmt_dur "$WAIT_SECS") 后重试…"
  while [ "$left" -gt 0 ]; do
    step=60
    [ "$step" -gt "$left" ] && step=$left
    sleep "$step"
    left=$((left - step))
    [ "$left" -gt 0 ] && say "还剩 $(fmt_dur "$left")"
  done
}

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
  # 分小段，避免 screen stuff 一次塞太长
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
])
reconnecting = "reconnecting" in compact
usage = any(s in compact for s in [
    "hit your usage limit",
    "usage limit",
    "429 too many requests",
    "exceeded retry limit",
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
    # Reconnecting... 2/5 + high demand 就是用户给的那种错误
    print("retryable")
elif reconnecting and retry_n >= 5:
    print("retryable")
elif success and not high and not reconnecting:
    print("success")
elif working:
    print("success")
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

print_success() {
  local sid="$1" sname="$2"
  printf '%s\n' "$sid" >"$SESSION_FILE"
  printf '%s\n' "$sid" >"$WORKDIR/.codex-init-session-id"
  printf '%s\n' "$sname" >"$SCREEN_FILE"
  {
    echo
    echo "========================================"
    echo "Codex 会话已就绪"
    echo "SESSION_ID=$sid"
    echo "SCREEN=$sname"
    echo "工作目录: $WORKDIR"
    echo "日志: $LOG_FILE"
    echo "会话文件: $SESSION_FILE"
    echo "进入 TUI:  screen -r $sname"
    echo "续跑:      screen -r $sname   然后直接打字"
    echo "========================================"
  } | tee -a "$LOG_FILE"
}

start_tui() {
  local name="$1" tui_log="$2"
  : >"$tui_log"
  # 用户指定的新开会话格式；--no-alt-screen 只为了 screen 日志能抓住 Reconnecting
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

say "工作目录: $WORKDIR"
say "日志: $LOG_FILE"
say "启动命令: $CODEX_BIN --dangerously-bypass-approvals-and-sandbox -C $WORKDIR"
say "重试间隔: $(fmt_dur "$WAIT_SECS")"
if [ "$RUN_TASK" = "1" ] && [ -f "$TASK_FILE" ]; then
  say "init 成功后将按: $TASK_FILE"
elif [ "$RUN_TASK" = "1" ]; then
  say "未找到 task.md，init 成功后等待 $(fmt_dur "$WAIT_SECS")"
else
  say "已关闭 task.md 执行"
fi

attempt=0
session_id=""
live_screen=""

while :; do
  attempt=$((attempt + 1))
  if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
    say "已达 init 尝试上限 $MAX_ATTEMPTS，放弃"
    exit 2
  fi

  tag="init-$(date +%Y%m%d-%H%M%S)-$attempt"
  live_screen="${SCREEN_NAME:-codex-init-$STAMP-$attempt}"
  tui_log="$ATTEMPT_DIR/${tag}-tui.log"
  say "第 $attempt 次：新开 TUI 会话 $live_screen 并发送 init"

  if screen_alive "$live_screen"; then
    say "screen 名 $live_screen 已存在，先关掉"
    kill_screen "$live_screen"
  fi

  before="$(date +%s)"
  if ! start_tui "$live_screen" "$tui_log"; then
    say "screen 启动失败，等 5 分钟再试"
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

  if [ "$st" != "success" ] && [ -z "$session_id" ]; then
    say "init 没有成功迹象，关掉这次会话后重开"
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
  break
done

if [ "$RUN_TASK" = "1" ] && [ -f "$TASK_FILE" ]; then
  task_prompt="请严格按照文件执行任务：${TASK_FILE}。先完整阅读该文件，按其中步骤顺序执行直到做完。不要另起新会话，就在当前会话继续。完成后用简短中文汇报做了什么、还有什么没做完。"
  say "向同一 TUI 发送 task.md 指令"
  stuff "$live_screen" "$task_prompt"
elif [ "$AFTER_WAIT" = "1" ]; then
  say "没有可执行的 task.md，按约定再等 $(fmt_dur "$WAIT_SECS")"
  wait_retry
fi

print_success "$session_id" "$live_screen"
echo "$session_id"
exit 0

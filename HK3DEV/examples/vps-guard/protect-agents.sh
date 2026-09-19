#!/usr/bin/env bash
# 给交互 agent 上 oom_score_adj=-800，内核挑 MEMCG 受害者时优先杀构建侧。
# 本机 20:01:15 的 CONSTRAINT_MEMCG 先杀 7za 再杀 cline；cline 当时 adj=0。
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "需要 root" >&2; exit 1; }
ADJ="${OOM_SCORE_ADJ:--800}"
pat='(^|/)(cline|claude|codex|grok)( |$)'
changed=0
for pid in $(ps -eo pid=,args= | awk -v p="$pat" '$0 ~ p {print $1}'); do
  [[ -w /proc/$pid/oom_score_adj ]] || continue
  echo "$ADJ" > "/proc/$pid/oom_score_adj" || continue
  echo "pid=$pid adj=$ADJ cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" | cut -c1-80)"
  changed=$((changed + 1))
done
echo "updated=$changed adj=$ADJ"
# 注意：这是进程属性，重启后失效。要持久化可在对应 systemd service 里设 OOMScoreAdjust=-800。
# Cline CLI 当前是 pts 上的交互进程，没有 unit，所以开机后需要再跑一次，或挂在 cron/vps-guard 里。

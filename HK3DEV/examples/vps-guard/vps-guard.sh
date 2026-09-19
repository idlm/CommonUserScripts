#!/bin/bash
# 轻量看门狗：占用冲高就再压 cgroup，不杀进程、不动钉死配置。
# 2026-09-19 修订（消除丢缓存风暴 + 允许正常构建/打包）：
#   1) 档位切换加入滞回(进入/退出阈值分离) + 连续确认，消除 high/emergency 反复跳变；
#   2) drop_caches 仅紧急档、且距上次 >= DROP_MIN_INTERVAL(默认 900s) 才执行；
#   3) 内存上限抬高，避免 user.slice 内(原 1.4G)的普通构建被压死。
# 可覆盖：VPS_GUARD_DROP_INTERVAL / VPS_GUARD_CONFIRM_TICKS
set -euo pipefail
STATE=/var/lib/vps-guard/state
DROPSTAMP=/var/lib/vps-guard/last-drop
LOGTAG=vps-guard
DROP_MIN_INTERVAL=${VPS_GUARD_DROP_INTERVAL:-900}
CONFIRM_TICKS=${VPS_GUARD_CONFIRM_TICKS:-2}
mkdir -p /var/lib/vps-guard

ncpu=$(nproc)
load=$(awk '{print $1}' /proc/loadavg)
mem_avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
mem_total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
mem_avail_pct=$(( mem_avail_kb * 100 / mem_total_kb ))
io_full=$(awk '/^full /{print $2}' /proc/pressure/io)
mem_full=$(awk '/^full /{print $2}' /proc/pressure/memory)
cpu_some=$(awk '/^some /{print $2}' /proc/pressure/cpu)

prev=ok
if [ -f "$STATE" ]; then prev=$(cat "$STATE" 2>/dev/null || echo ok); fi
case "$prev" in ok|high|emergency) ;; *) prev=ok ;; esac
cand=""
if [ -f "$STATE.cand" ]; then cand=$(cat "$STATE.cand" 2>/dev/null || true); fi
streak=0
if [ -f "$STATE.streak" ]; then streak=$(cat "$STATE.streak" 2>/dev/null || echo 0); fi

# ---- 分级：进入/退出阈值分离(滞回)，抑制边界抖动 ----
if [ "$prev" = "emergency" ]; then
  if [ "$mem_avail_pct" -lt 12 ] || awk "BEGIN{exit !($load > $ncpu * 2.0)}" || awk "BEGIN{exit !($io_full > 40 || $mem_full > 12)}"; then level=emergency
  elif [ "$mem_avail_pct" -lt 20 ] || awk "BEGIN{exit !($load > $ncpu * 1.1)}" || awk "BEGIN{exit !($io_full > 15 || $cpu_some > 15)}"; then level=high
  else level=ok; fi
elif [ "$prev" = "high" ]; then
  if [ "$mem_avail_pct" -lt 12 ] || awk "BEGIN{exit !($load > $ncpu * 2.6)}" || awk "BEGIN{exit !($io_full > 50 || $mem_full > 15)}"; then level=emergency
  elif [ "$mem_avail_pct" -lt 22 ] || awk "BEGIN{exit !($load > $ncpu * 1.1)}" || awk "BEGIN{exit !($io_full > 15 || $cpu_some > 15)}"; then level=high
  else level=ok; fi
else
  if [ "$mem_avail_pct" -lt 12 ] || awk "BEGIN{exit !($load > $ncpu * 2.4)}" || awk "BEGIN{exit !($io_full > 50 || $mem_full > 15)}"; then level=emergency
  elif [ "$mem_avail_pct" -lt 25 ] || awk "BEGIN{exit !($load > $ncpu * 1.5)}" || awk "BEGIN{exit !($io_full > 20 || $cpu_some > 20)}"; then level=high
  else level=ok; fi
fi

# ---- 生效值（2026-09-19 抬高内存上限，给正常构建留空间） ----
apply_ok() {
  systemctl set-property user.slice CPUQuota=300% MemoryHigh=3000M MemoryMax=3600M IOReadBandwidthMax="/dev/sda 24M" IOWriteBandwidthMax="/dev/sda 24M" >/dev/null
  systemctl set-property system.slice CPUQuota=150% MemoryHigh=1200M MemoryMax=1500M IOReadBandwidthMax="/dev/sda 24M" IOWriteBandwidthMax="/dev/sda 24M" >/dev/null
}
apply_high() {
  systemctl set-property user.slice CPUQuota=250% MemoryHigh=2800M MemoryMax=3400M IOReadBandwidthMax="/dev/sda 16M" IOWriteBandwidthMax="/dev/sda 16M" >/dev/null
  systemctl set-property system.slice CPUQuota=120% MemoryHigh=1000M MemoryMax=1200M IOReadBandwidthMax="/dev/sda 16M" IOWriteBandwidthMax="/dev/sda 16M" >/dev/null
}
apply_emergency() {
  systemctl set-property user.slice CPUQuota=200% MemoryHigh=2600M MemoryMax=3200M IOReadBandwidthMax="/dev/sda 12M" IOWriteBandwidthMax="/dev/sda 12M" >/dev/null
  systemctl set-property system.slice CPUQuota=100% MemoryHigh=800M MemoryMax=1000M IOReadBandwidthMax="/dev/sda 12M" IOWriteBandwidthMax="/dev/sda 12M" >/dev/null
  now=$(date +%s); last=0
  if [ -f "$DROPSTAMP" ]; then last=$(cat "$DROPSTAMP" 2>/dev/null || echo 0); fi
  if [ $(( now - last )) -ge "$DROP_MIN_INTERVAL" ]; then
    sync
    if echo 1 > /proc/sys/vm/drop_caches 2>/dev/null; then
      echo "$now" > "$DROPSTAMP"
      logger -t "$LOGTAG" "drop_caches page cache (interval>=${DROP_MIN_INTERVAL}s)"
    else
      logger -t "$LOGTAG" "drop_caches skipped (no permission)"
    fi
  else
    logger -t "$LOGTAG" "drop_caches suppressed (last $(( now - last ))s ago < ${DROP_MIN_INTERVAL}s)"
  fi
}

# ---- 切换：需连续 CONFIRM_TICKS 次同一候选（默认 2 次 ≈ 60s）才 set-property ----
if [ "$level" = "$prev" ]; then
  rm -f "$STATE.cand" "$STATE.streak"
  logger -t "$LOGTAG" "level=$level load=$load mem_avail=${mem_avail_pct}% cpu_psi=$cpu_some io_psi=$io_full mem_psi=$mem_full"
else
  if [ "$level" = "$cand" ]; then streak=$(( streak + 1 )); else cand="$level"; streak=1; fi
  echo "$cand" > "$STATE.cand"; echo "$streak" > "$STATE.streak"
  if [ "$streak" -ge "$CONFIRM_TICKS" ]; then
    case "$level" in ok) apply_ok ;; high) apply_high ;; emergency) apply_emergency ;; esac
    echo "$level" > "$STATE"; rm -f "$STATE.cand" "$STATE.streak"
    logger -t "$LOGTAG" "level $prev -> $level (confirmed x$streak) load=$load mem_avail=${mem_avail_pct}% cpu_psi=$cpu_some io_psi=$io_full mem_psi=$mem_full"
  else
    logger -t "$LOGTAG" "pending $level (x$streak/$CONFIRM_TICKS) keeping $prev load=$load mem_avail=${mem_avail_pct}% io_psi=$io_full"
  fi
fi

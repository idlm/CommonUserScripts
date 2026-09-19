#!/usr/bin/env bash
# 把重 I/O / 高内存任务丢进顶层 packing.slice，与 user.slice 里的 Cline 隔离。
# 用法：
#   sudo ./run-in-packing-slice.sh -- npm run pack:linux
#   sudo ./run-in-packing-slice.sh -- bash -lc '7za a /tmp/x.7z /path'
# 可选环境：PACK_MEM_HIGH PACK_MEM_MAX PACK_CPU PACK_IO PACK_DISK PACK_CWD
#
# 3HK 2026-09-19 跑通 electron-builder Linux QA（PACK_EXIT=0 VERIFY_EXIT=0）：
#   PACK_MEM_HIGH=2000M PACK_MEM_MAX=2600M PACK_CPU=250% PACK_IO=20M
#   命令必须带 -c.compression=store（体积换内存；deb ~153MB vs 默认 ~105MB）
#   sudo PACK_MEM_HIGH=2000M PACK_MEM_MAX=2600M PACK_CWD=/path/to/app \
#     ./run-in-packing-slice.sh -- \
#     bash -lc 'npm run pack:linux -- -c.compression=store && npm run verify:package'
# 模板默认 2400/2800 给一般重活。4G 机打 Electron 包请用上面那组，不要裸跑 pack:linux。
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "需要 root" >&2; exit 1; }
if [[ "${1:-}" == "--" ]]; then shift; fi
[[ $# -ge 1 ]] || { echo "usage: $0 -- <command> [args...]" >&2; exit 2; }

DISK="${PACK_DISK:-/dev/sda}"
MEM_HIGH="${PACK_MEM_HIGH:-2400M}"
MEM_MAX="${PACK_MEM_MAX:-2800M}"
CPU="${PACK_CPU:-250%}"
IO="${PACK_IO:-20M}"
UNIT="pd-pack-$(date +%s)"

# 顶层 slice：vps-guard 只压 user.slice / system.slice，不会连坐这里。
exec systemd-run --unit="$UNIT" --slice=packing.slice --collect --wait --pty \
  -p MemoryAccounting=yes -p CPUAccounting=yes -p IOAccounting=yes \
  -p MemoryHigh="$MEM_HIGH" -p MemoryMax="$MEM_MAX" \
  -p CPUQuota="$CPU" \
  -p "IOReadBandwidthMax=${DISK} ${IO}" \
  -p "IOWriteBandwidthMax=${DISK} ${IO}" \
  -p OOMScoreAdjust=200 \
  --workdir="${PACK_CWD:-$PWD}" \
  -- "$@"

#!/usr/bin/env bash
# 3HK vps-guard 一键入口。Debian/Ubuntu + systemd + cgroup v2。
# 装的是已验证配方：整机 I/O 看门狗、MemoryMax 3600/3400/3200、
# 4G swap、agent oom_score_adj=-800、packing.slice 包装脚本。
#
#   curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/HK3DEV/examples/vps-guard/install.sh | bash
#   wget -qO-  https://raw.githubusercontent.com/idlm/CommonUserScripts/main/HK3DEV/examples/vps-guard/install.sh | bash
#
# 管道带参必须用 bash -s --（不要漏 --）：
#   curl -fsSL .../install.sh | bash -s -- --help
#   curl -fsSL .../install.sh | bash -s -- --disk /dev/vda
#   wget -qO-  .../install.sh | bash -s -- --no-swap
#
# 环境：VPS_GUARD_DISK  VPS_GUARD_RAW_BASE  VPS_GUARD_FORCE=1
# 不装 Cline Pass pin，不改 AI 配置，不写 Key。
set -euo pipefail

RAW_BASE="${VPS_GUARD_RAW_BASE:-https://raw.githubusercontent.com/idlm/CommonUserScripts/main/HK3DEV/examples/vps-guard}"

FILES=(
  vps-guard.sh
  vps-guard.service
  vps-guard.timer
  io-accounting.conf
  user.slice.io-controller.conf
  user.slice.resource-guard.conf
  system.slice.resource-guard.conf
  protect-agents.sh
  run-in-packing-slice.sh
  setup-swap-4g.sh
)

usage() {
  cat <<'EOF'
用法: install.sh [--disk /dev/vda] [--no-swap] [--force] [--help]

  --disk DEV   限速设备（默认自动检测 / 的父盘）
  --no-swap    不建 /swapfile（仍把 memory.swap.max 设成 max）
  --force      内存明显不是 ~4G 也继续装
  --help       本说明

环境变量：VPS_GUARD_DISK  VPS_GUARD_RAW_BASE  VPS_GUARD_FORCE=1

装完打包（4G 机已验证 PACK_EXIT=0）：
  systemd-run --unit=pd-pack --slice=packing.slice --collect \
    -p MemoryHigh=2000M -p MemoryMax=2600M -p CPUQuota=250% \
    -p IOReadBandwidthMax="/dev/sda 20M" -p IOWriteBandwidthMax="/dev/sda 20M" \
    -p WorkingDirectory=/path/to/electron-app \
    /bin/bash -c 'npm run pack:linux -- -c.compression=store && npm run verify:package'
EOF
}

NO_SWAP=0
FORCE="${VPS_GUARD_FORCE:-0}"
DISK="${VPS_GUARD_DISK:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --no-swap) NO_SWAP=1 ;;
    --force) FORCE=1 ;;
    --disk)
      [[ $# -ge 2 ]] || { echo "需要 --disk DEV" >&2; exit 2; }
      DISK="$2"
      shift
      ;;
    --disk=*) DISK="${1#--disk=}" ;;
    *) echo "未知参数: $1 （--help）" >&2; exit 2 ;;
  esac
  shift
done

[[ "$(id -u)" -eq 0 ]] || { echo "需要 root。sudo bash $0 或 curl … | sudo bash" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "需要 systemd" >&2; exit 1; }
[[ -d /sys/fs/cgroup ]] || { echo "没有 cgroup" >&2; exit 1; }
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  :
elif [[ -d /sys/fs/cgroup/memory ]]; then
  echo "这是 cgroup v1。本配方只支持 v2。" >&2
  exit 1
fi

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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
WORKDIR=""
cleanup() { [[ -n "${WORKDIR:-}" ]] && rm -rf "$WORKDIR"; }
if [[ -n "${HERE:-}" && -f "$HERE/vps-guard.sh" && -f "$HERE/vps-guard.timer" ]]; then
  :
else
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/vps-guard.XXXXXX")"
  trap cleanup EXIT
  echo "从 $RAW_BASE 拉取模板 …"
  for f in "${FILES[@]}"; do
    fetch "$RAW_BASE/$f" "$WORKDIR/$f"
  done
  chmod +x "$WORKDIR"/*.sh
  HERE="$WORKDIR"
fi

detect_disk() {
  local src parent d
  src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  src="${src%%[*}"
  if [[ -n "$src" && -b "$src" ]] && command -v lsblk >/dev/null 2>&1; then
    parent=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
    if [[ -n "$parent" && -b "/dev/$parent" ]]; then
      echo "/dev/$parent"
      return
    fi
    case "$src" in
      /dev/nvme*n*p*) echo "${src%p*}"; return ;;
      /dev/*[0-9]) echo "${src%%[0-9]*}"; return ;;
    esac
  fi
  for d in /dev/sda /dev/vda /dev/xvda /dev/nvme0n1; do
    [[ -b "$d" ]] && { echo "$d"; return; }
  done
  echo /dev/sda
}

if [[ -z "$DISK" ]]; then
  DISK="$(detect_disk)"
fi
if [[ ! -b "$DISK" ]]; then
  echo "磁盘 $DISK 不存在。用 --disk /dev/vda 或 VPS_GUARD_DISK=…" >&2
  exit 1
fi

mem_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
echo "host=$(hostname) os=$(. /etc/os-release 2>/dev/null; echo "${ID:-?} ${VERSION_ID:-?}") ram=${mem_mb}M disk=$DISK cgroup=v2"
if (( mem_mb < 2800 )) && [[ "$FORCE" != 1 ]]; then
  echo "RAM ${mem_mb}M < 2800M：user MemoryMax=3600M 会立刻 OOM。换更大内存，或 VPS_GUARD_FORCE=1 / --force。" >&2
  exit 1
fi
if (( mem_mb > 9000 )); then
  echo "提示: RAM ${mem_mb}M，这套上限按 ~4G 机验证，偏保守。继续按 3HK 配方装。"
fi

install -d /usr/local/sbin /var/lib/vps-guard \
  /etc/systemd/system.conf.d \
  /etc/systemd/system/user.slice.d \
  /etc/systemd/system/system.slice.d

install -m 0755 "$HERE/vps-guard.sh" /usr/local/sbin/vps-guard.sh
install -m 0755 "$HERE/protect-agents.sh" /usr/local/sbin/protect-agents.sh
install -m 0755 "$HERE/run-in-packing-slice.sh" /usr/local/sbin/run-in-packing-slice.sh
install -m 0755 "$HERE/setup-swap-4g.sh" /usr/local/sbin/setup-swap-4g.sh
install -m 0644 "$HERE/vps-guard.service" /etc/systemd/system/vps-guard.service
install -m 0644 "$HERE/vps-guard.timer" /etc/systemd/system/vps-guard.timer
install -m 0644 "$HERE/io-accounting.conf" /etc/systemd/system.conf.d/io-accounting.conf
install -m 0644 "$HERE/user.slice.io-controller.conf" /etc/systemd/system/user.slice.d/io-controller.conf
sed "s|/dev/sda|${DISK}|g" "$HERE/user.slice.resource-guard.conf" \
  > /etc/systemd/system/user.slice.d/resource-guard.conf
sed "s|/dev/sda|${DISK}|g" "$HERE/system.slice.resource-guard.conf" \
  > /etc/systemd/system/system.slice.d/resource-guard.conf
if [[ "$DISK" != /dev/sda ]]; then
  sed -i "s|/dev/sda|${DISK}|g" /usr/local/sbin/vps-guard.sh
  sed -i "s|/dev/sda|${DISK}|g" /usr/local/sbin/run-in-packing-slice.sh
fi

# 子 slice 再写 io.max 会和 user.slice 叠乘
if [[ -e /sys/fs/cgroup/user.slice/user-0.slice/io.max ]]; then
  : > /sys/fs/cgroup/user.slice/user-0.slice/io.max || true
fi

systemctl daemon-reexec
systemctl daemon-reload
echo '+cpu +io +memory +pids' > /sys/fs/cgroup/cgroup.subtree_control || true
echo '+cpu +io +memory +pids' > /sys/fs/cgroup/user.slice/cgroup.subtree_control 2>/dev/null || true
echo '+cpu +io +memory +pids' > /sys/fs/cgroup/system.slice/cgroup.subtree_control 2>/dev/null || true

if [[ "$NO_SWAP" -eq 0 ]]; then
  /usr/local/sbin/setup-swap-4g.sh
else
  echo "--no-swap：跳过 /swapfile。仍把 slice memory.swap.max 设成 max。"
  for s in user.slice system.slice; do
    systemctl set-property "$s" MemorySwapMax=infinity 2>/dev/null || true
  done
  for f in /sys/fs/cgroup/user.slice/memory.swap.max /sys/fs/cgroup/system.slice/memory.swap.max; do
    [[ -w $f ]] && echo max > "$f" || true
  done
fi

systemctl enable --now vps-guard.timer
/usr/local/sbin/vps-guard.sh || true
/usr/local/sbin/protect-agents.sh || true

echo
echo "installed. timer=$(systemctl is-active vps-guard.timer) state=$(cat /var/lib/vps-guard/state 2>/dev/null || echo none)"
echo "user.slice io.max=$(cat /sys/fs/cgroup/user.slice/io.max 2>/dev/null || echo missing)"
echo "system.slice io.max=$(cat /sys/fs/cgroup/system.slice/io.max 2>/dev/null || echo missing)"
echo "swap=$(awk '/SwapTotal/{printf "%dM", $2/1024}' /proc/meminfo) memory.swap.max=$(cat /sys/fs/cgroup/user.slice/memory.swap.max 2>/dev/null || echo missing)"
echo
echo "4G 机 Electron Linux 打包（已验证 PACK_EXIT=0，不要裸跑 pack:linux）："
echo "  PACK_MEM_HIGH=2000M PACK_MEM_MAX=2600M PACK_DISK=$DISK PACK_CWD=/path/to/app \\"
echo "    /usr/local/sbin/run-in-packing-slice.sh -- \\"
echo "    bash -lc 'npm run pack:linux -- -c.compression=store && npm run verify:package'"
echo "agent 重启后 adj 会丢；vps-guard 每 30s 会再写一次 oom_score_adj=-800。"

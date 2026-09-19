#!/usr/bin/env bash
# 4G /swapfile + fstab。cgroup MemorySwapMax 必须不是 0，否则加了也用不了。
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "需要 root" >&2; exit 1; }
if ! swapon --show | grep -q .; then
  if [[ ! -f /swapfile ]]; then
    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
# 放开 slice 的 swap 上限
for s in user.slice system.slice; do
  systemctl set-property "$s" MemorySwapMax=infinity 2>/dev/null || true
done
for f in /sys/fs/cgroup/user.slice/memory.swap.max /sys/fs/cgroup/system.slice/memory.swap.max; do
  [[ -w $f ]] && echo max > "$f" || true
done
swapon --show
free -h

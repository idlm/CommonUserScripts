#!/usr/bin/env bash
# 把 3HK 这套 cgroup 限速 + vps-guard 装到本机。
# 仅 Debian/Ubuntu + systemd + cgroup v2。默认设备 /dev/sda。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISK="${VPS_GUARD_DISK:-/dev/sda}"
[[ "$(id -u)" -eq 0 ]] || { echo "需要 root" >&2; exit 1; }
[[ -d /sys/fs/cgroup ]] || { echo "没有 cgroup" >&2; exit 1; }

install -d /usr/local/sbin /var/lib/vps-guard \
  /etc/systemd/system.conf.d \
  /etc/systemd/system/user.slice.d \
  /etc/systemd/system/system.slice.d

install -m 0755 "$HERE/vps-guard.sh" /usr/local/sbin/vps-guard.sh
install -m 0644 "$HERE/vps-guard.service" /etc/systemd/system/vps-guard.service
install -m 0644 "$HERE/vps-guard.timer" /etc/systemd/system/vps-guard.timer
install -m 0644 "$HERE/io-accounting.conf" /etc/systemd/system.conf.d/io-accounting.conf
install -m 0644 "$HERE/user.slice.io-controller.conf" /etc/systemd/system/user.slice.d/io-controller.conf
sed "s|/dev/sda|${DISK}|g" "$HERE/user.slice.resource-guard.conf" \
  > /etc/systemd/system/user.slice.d/resource-guard.conf
sed "s|/dev/sda|${DISK}|g" "$HERE/system.slice.resource-guard.conf" \
  > /etc/systemd/system/system.slice.d/resource-guard.conf
# 脚本里的设备名一并替换
if [[ "$DISK" != /dev/sda ]]; then
  sed -i "s|/dev/sda|${DISK}|g" /usr/local/sbin/vps-guard.sh
fi

systemctl daemon-reexec
systemctl daemon-reload
echo '+cpu +io +memory +pids' > /sys/fs/cgroup/cgroup.subtree_control || true
echo '+cpu +io +memory +pids' > /sys/fs/cgroup/user.slice/cgroup.subtree_control 2>/dev/null || true
echo '+cpu +io +memory +pids' > /sys/fs/cgroup/system.slice/cgroup.subtree_control 2>/dev/null || true
systemctl enable --now vps-guard.timer
/usr/local/sbin/vps-guard.sh || true
echo "installed. timer=$(systemctl is-active vps-guard.timer) state=$(cat /var/lib/vps-guard/state 2>/dev/null || echo none)"
echo "user.slice io.max=$(cat /sys/fs/cgroup/user.slice/io.max 2>/dev/null || echo missing)"

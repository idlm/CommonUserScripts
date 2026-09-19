# vps-guard · 3HK 整机限速 + 占用看门狗

本目录是 3HK（Debian 13 / cgroup v2 / 4 vCPU / 3.8 GiB RAM / `/dev/sda` 40G）在 **2026-09-19** 踩过坑之后落地的一套模板。

目标：Cline / 打包 / 解压把磁盘打满时，整机不要卡死；看门狗过紧时，也不要把交互进程 OOM 掉。

**不杀进程、不改 AI 钉死配置。** 只动 cgroup 上限。

## 为什么不能写 root `io.max`

cgroup v2 把 `io` 委派给子树之后，`/sys/fs/cgroup/io.max` 要么不存在，要么 `Permission denied`。

整机 I/O 上限 = 两个顶层 slice 之和，不是 root 一条：

```
user.slice   IORead/WriteBandwidthMax = 24M
system.slice IORead/WriteBandwidthMax = 24M
→ 基线合计约 48M 理论峰值；实际再被 PSI / 看门狗压到 32M 或 24M
```

不要再给 `user-0.slice` 单独写一份 `io.max`，会和 `user.slice` **叠乘**（24+24 变成 24 再被 18 卡死）。

## 三档（本机实测）

| 档 | 触发（进入） | user.slice | system.slice | 磁盘合计 |
|:--|:--|:--|:--|:--|
| ok | 默认 | CPU 300% / MemMax 3600M / IO 24M | CPU 150% / MemMax 1500M / IO 24M | ~48M |
| high | MemAvail&lt;25% 或 load&gt;1.5×ncpu 或 io PSI 高 | 250% / 3400M / 16M | 120% / 1200M / 16M | ~32M |
| emergency | MemAvail&lt;12% 或 load&gt;2.4×ncpu 或 mem PSI 高 | 200% / 3200M / 12M | 100% / 1000M / 12M | ~24M |

切换有滞回 + 连续 2 次确认（timer 30s ≈ 60s）才 `set-property`。`drop_caches` **只在 emergency**，且间隔 ≥ 900s。

用户原话要整机 30–40 MiB/s：high 档 32M 落在区间内；ok 档略宽，避免正常会话被拖死。

## 装

```bash
# 磁盘不是 /dev/sda 时：
#   VPS_GUARD_DISK=/dev/vda sudo ./install.sh
sudo ./install.sh
sudo ./setup-swap-4g.sh     # 4G 内存机强烈建议；没有 swap 时 MemoryMax 就是硬杀
```

`setup-swap-4g.sh` 会：

1. 建 `/swapfile` 4G，`chmod 600`，`mkswap` + `swapon`
2. 写 `/etc/fstab`
3. 把 `user.slice` / `system.slice` 的 `memory.swap.max` 设成 `max`

**`MemorySwapMax=0` 等于没加 swap。** 第一次看门狗就是这个错误，直接 MEMCG OOM。

## 看现状

```bash
systemctl is-active vps-guard.timer
cat /var/lib/vps-guard/state
cat /sys/fs/cgroup/user.slice/io.max
cat /sys/fs/cgroup/system.slice/io.max
cat /sys/fs/cgroup/user.slice/memory.swap.max
journalctl -t vps-guard -n 30 --no-pager
free -h
```

## 不要做

```
✗  echo ... > /sys/fs/cgroup/io.max          # 委派后写不进去
✗  MemorySwapMax=0  同时又 MemoryMax=紧
✗  每 30s drop_caches                       # 会把 page cache 打空，I/O 更炸
✗  user.slice 再叠加 user-0.slice 的 io.max
✗  把 MemoryMax 压到 2G 以下还在 user.slice 里跑 Cline + 7za
```

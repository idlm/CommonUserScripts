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

**内存下限不再随档位收到构建需求以下。** 这是 Cline 会话 `1789847324501_r6o6f` 第二轮的结论：第一次修完滞回后，emergency 仍把 user `MemoryMax` 收到 2600M，`7za` 1.19G 一顶就 `CONSTRAINT_MEMCG`，cline 被连坐。

用户原话要整机 30–40 MiB/s：high 档 32M 落在区间内；ok 档略宽，避免正常会话被拖死。

## Cline 方案（已并入）

会话问的是「`ups-guard.sh` 为什么一直跑 / drop_caches 为什么卡 / 为什么 cline 退出」。Cline 查到真名 `vps-guard.sh`，选 **C+A**（修守卫 + 降峰打包），两轮：

1. **去抖**：滞回、2 tick 确认、drop 冷却 900s、抬内存。当时写操作一度被 Plan 模式拦住，切 act 后落地。
2. **隔离 + 保险**（OOM 之后）：
   - 内存下限改成 3600 / 3400 / **3200**（CPU/IO 仍随档位收）
   - 重活进顶层 `packing.slice`，守卫只管 `user.slice`/`system.slice`
   - agent `oom_score_adj=-800`
   - 打包：`nice -n 19 ionice -c3`、`NODE_OPTIONS=--max-old-space-size=1536`；仍炸则 electron-builder `-c.compression=store`

对应脚本：

```bash
sudo ./protect-agents.sh                          # 给已有 cline/claude/codex/grok 设 -800
```

`oom_score_adj` 是进程属性，重启会丢。Cline CLI 是 pts 交互进程、没有 unit。装完之后 `vps-guard` 每 30s 会再跑 `protect-agents.sh`（已是目标值则静默）。也可在对应 systemd service 里写 `OOMScoreAdjust=-800`。3HK 当时 `/usr/local/sbin` 未装这两个 helper，adj=-800 是手工写过的。

## 已验证配方（下次 4G 机打 Electron 包照这条）

Cline 在会话 `1789847324501_r6o6f` 里把 Linux deb + AppImage 打完。`PACK_EXIT=0` `VERIFY_EXIT=0`。诊断在上一节；**完成任务用的是下面这条，不是裸 `npm run pack:linux`。**

失败对照（不要再走）：

```
裸 npm run pack:linux
  → user.slice 内 7za+agent 同 memcg，CONSTRAINT_MEMCG，连坐 cline

nice -n 19 ionice -c3 NODE_OPTIONS=--max-old-space-size=1536 npm run pack:linux
  → 仍在 user.slice，内存/压缩峰值不够

packing.slice 隔离 + electron-builder -c.compression=store
  → 成功
```

下次直接：

```bash
# 磁盘不是 sda 就改设备名。工作目录换成你的 Electron 项目。
systemd-run --unit=pd-pack --slice=packing.slice --collect \
  -p MemoryHigh=2000M -p MemoryMax=2600M -p CPUQuota=250% \
  -p IOReadBandwidthMax="/dev/sda 20M" -p IOWriteBandwidthMax="/dev/sda 20M" \
  -p WorkingDirectory=/path/to/electron-app \
  /bin/bash -c 'npm run pack:linux -- -c.compression=store && npm run verify:package'
```

或用本目录包装脚本（默认 2400/2800，QA 打包覆盖成实测值）：

```bash
sudo PACK_MEM_HIGH=2000M PACK_MEM_MAX=2600M PACK_CWD=/path/to/electron-app \
  ./run-in-packing-slice.sh -- \
  bash -lc 'npm run pack:linux -- -c.compression=store && npm run verify:package'
```

前置（缺一条就会再 OOM）：

1. vps-guard 三档 user MemoryMax = 3600 / 3400 / **3200**（不要再收到 2600）
2. `/swapfile` 4G + `memory.swap.max=max`（`MemorySwapMax=0` 等于没加）
3. agent `oom_score_adj=-800`
4. 构建进顶层 `packing.slice`，不进 `user.slice`

本机 2026-09-19 结果（环境证据，项目本身不进本仓）：

```
PACK_EXIT=0
VERIFY_EXIT=0
deb      ~153MB   (store；默认压缩约 105MB)
AppImage ~165MB
vps-guard state=ok；偶发 pending high，2-tick 未确认故未降档
```

`compression=store` 是体积换内存，只给 4G QA 机。正式发布应在内存充足的 runner 上用默认压缩重建。容器 root 下 UI smoke 需要 `--no-sandbox`。Windows 交叉构建另需 wine，不在本配方内。

## 装（另一台同规格机一键）

不 clone。Debian/Ubuntu + systemd + cgroup v2 + 约 4G RAM。需要 root。

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/HK3DEV/examples/vps-guard/install.sh | sudo bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/HK3DEV/examples/vps-guard/install.sh | sudo bash
```

磁盘不是 sda、不要建 swap、内存不是 ~4G 仍要装：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/HK3DEV/examples/vps-guard/install.sh \
  | sudo bash -s -- --disk /dev/vda
# curl -fsSL …/install.sh | sudo bash -s -- --no-swap
# curl -fsSL …/install.sh | sudo bash -s -- --force
```

管道参数必须写在 `bash -s --` 后面，漏 `--` 脚本看不到。

已 clone 本仓时仍可本地跑（不拉 raw）：

```bash
cd CommonUserScripts/HK3DEV/examples/vps-guard
# 磁盘不是 /dev/sda 时：
#   VPS_GUARD_DISK=/dev/vda sudo ./install.sh
sudo ./install.sh
```

`install.sh` 会：装守卫 + 4G `/swapfile` + `protect-agents.sh` + `run-in-packing-slice.sh`，清掉 `user-0.slice` 上可能叠乘的 `io.max`。`vps-guard` 每 30s 会再写一次 agent `oom_score_adj=-800`（重启后不再丢）。不装 Cline Pass pin，不改 AI 配置。

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
# agent 是否已上保险
awk '/cline|claude/{print}' /proc/*/oom_score_adj /dev/null 2>/dev/null | head
cat /proc/$(pgrep -n -x cline)/oom_score_adj
systemctl status packing.slice --no-pager
```

## 不要做

```
✗  echo ... > /sys/fs/cgroup/io.max          # 委派后写不进去
✗  MemorySwapMax=0  同时又 MemoryMax=紧
✗  每 30s drop_caches                       # 会把 page cache 打空，I/O 更炸
✗  user.slice 再叠加 user-0.slice 的 io.max
✗  把 MemoryMax 压到 2G 以下还在 user.slice 里跑 Cline + 7za
✗  档位降级时把 MemoryMax 收到构建峰值以下
✗  在 user.slice 里跟 Cline 同 memcg 跑 electron-builder / 7za
✗  4G 机打 Electron 包跳过 packing.slice 或跳过 -c.compression=store
```

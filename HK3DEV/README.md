# HK3DEV

```
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║     ██╗  ██╗██╗  ██╗██████╗ ██████╗ ███████╗██╗   ██╗                ║
║     ██║  ██║██║ ██╔╝╚════██╗██╔══██╗██╔════╝██║   ██║                ║
║     ███████║█████╔╝  █████╔╝██║  ██║█████╗  ██║   ██║                ║
║     ██╔══██║██╔═██╗  ╚═══██╗██║  ██║██╔══╝  ╚██╗ ██╔╝                ║
║     ██║  ██║██║  ██╗██████╔╝██████╔╝███████╗ ╚████╔╝                 ║
║     ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚═════╝ ╚══════╝  ╚═══╝                  ║
║                                                                      ║
║     host  3HK          Debian 13 trixie          QEMU guest          ║
║     snap  2026-09-19   no keys in git            examples only       ║
╚══════════════════════════════════════════════════════════════════════╝
```

这台机器（hostname `3HK`）的**脱敏**运行快照 + 可复用配置模板。

仓库 public。本目录 **不放** API Key / Cookie / `auth.json` / SSH 私钥。
真实值只活在本机 `~/.bashrc`、`~/.claude/settings.json`、`~/.codex/auth.json`。

```
status   SNAPSHOT + TEMPLATES
host     3HK
os       Debian GNU/Linux 13.7 (trixie)
kernel   6.12.107+deb13-amd64
role     开发机 / QEMU 虚拟机
user     root
policy   复制 examples → 本机路径，再自己填 Key
```

---

## 目录

```
HK3DEV/
├── README.md                              本文件：主机 + 服务 + 事故 + 怎么复用
└── examples/
    ├── bashrc.snippet.sh                  ~/.bashrc 里 grok 段
    ├── gitconfig.example                  ~/.gitconfig
    ├── codex-config.toml.example          ~/.codex/config.toml
    ├── grok-config.toml.example           ~/.grok/config.toml
    ├── claude-settings.example.json       ~/.claude/settings.json
    ├── claude-config.json.example         ~/.claude/config.json
    ├── CLAUDE.md.example                  ~/.claude/CLAUDE.md
    └── vps-guard/                         整机 I/O + 内存看门狗（见 §07）
        ├── README.md
        ├── install.sh
        ├── setup-swap-4g.sh
        ├── vps-guard.sh
        ├── vps-guard.service / .timer
        └── *.conf                         systemd drop-in 模板
```

不进 git（本机有、这里故意没有）：

```
✗  ~/.codex/auth.json
✗  ~/.ssh/id_*
✗  ~/.claude.json          (machineID / userID / key 后缀)
✗  真实 ANTHROPIC_API_KEY / GROK_RELAY_API_KEY / ANY_API_KEY / CPA_API_KEY
```

---

## 01  ·  主机

采集时间 UTC `2026-09-19`。数值会变，结构相对稳定。

```
hostname     3HK
virt         QEMU Virtual CPU version 2.5+     (qemu-guest-agent 在跑)
cpu          4 vCPU
mem          3.8 Gi  ·  swap /swapfile 4G（2026-09-19 加；此前为 0）
disk         /dev/sda1  40G  ·  约 60%
cgroup       v2 · io/cpu/memory 委派到 user.slice + system.slice
io cap       基线每 slice 24M（合计 ~48M）；high 16M+16M；emergency 12M+12M
nic          eth0  10.69.134.135/24
gw           10.69.134.254
dns pin      1.1.1.1  8.8.8.8  via dhcp
tz           Etc/UTC
docker       无
ssh keys     ~/.ssh/authorized_keys 空文件；本机无 id_ed25519
```

工作区（root 拥有）：

```
/home/dev/cline/pd-monitor
/home/dev/cline/pd-monitor-v2
/home/dev/codex
```

PATH：

```
/root/.local/bin
/root/.grok/bin
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

`/usr/local/bin/{agent,grok}` → `~/.grok/bin/`。

---

## 02  ·  运行服务

systemd **running**：

```
ssh.service
cron.service
postgresql@17-main.service
redis-server.service
exim4.service
qemu-guest-agent.service
atop.service
atopacct.service
unattended-upgrades.service
systemd-networkd / resolved / timesyncd
vps-guard.timer                    # 30s 占用看门狗，见 §07
cline-pass-switcher.service        # 127.0.0.1:3123，配置不进本目录
```

enabled 且相关：`ssh` `cron` `postgresql` `redis-server` `exim4` `atop` `unattended-upgrades` `cloud-init*` `vps-guard.timer`。

用户 crontab：**空**。`/etc/cron.d` 有 `atop` `e2scrub_all` `sysstat`。

screen：

```
65594.node     Attached
```

交互进程（采集时，不入 systemd）：

```
grok --yolo          ×2
claude
codex resume 01a0b62b-…     (anyrouter 会话，失败 ID 不要当成功)
```

### 监听

| 地址 | 端口 | 进程 | 暴露面 |
|:--|:--|:--|:--|
| `0.0.0.0` / `[::]` | 22 | sshd | **对外 SSH** |
| `0.0.0.0` / `[::]` | 5355 | systemd-resolved | LLMNR |
| `127.0.0.1` / `[::1]` | 5432 | postgres 17 | 仅本机 |
| `127.0.0.1` / `[::1]` | 6379 | redis 8.0.2 | 仅本机 |
| `127.0.0.1` / `[::1]` | 25 | exim4 | 仅本机 |
| `127.0.0.53` / `.54` | 53 | systemd-resolved | 本机 DNS |

postgres `listen_addresses` 默认 localhost。redis `bind 127.0.0.1 -::1`，`protected-mode yes`。

**不要把 5432 / 6379 绑到 0.0.0.0。** 这台机器没有公网 IP 写在网卡上，但 SSH 已经全接口监听。

---

## 03  ·  已装工具

| 组件 | 版本 |
|:--|:--|
| bash | 5.2.37 |
| git / git-lfs | 2.47.3 / 3.6.1 |
| python3 | 3.13.5 |
| node / npm | v24.20.0 / 12.0.2 |
| OpenSSH | 10.0p1 |
| PostgreSQL | 17.11 + pgvector 0.8.0 |
| Redis | 8.0.2 |
| screen / htop / btop / nano / curl / wget | 发行版包 |
| gh | 2.100.0 |
| qemu-guest-agent | 10.0.13 |

npm 全局（`/usr/lib`）：

```
@anthropic-ai/claude-code    2.1.278
@openai/codex                0.155.1
@xai-official/grok           1.0.34
@cometix/ccline              1.1.2
cline                        3.0.62
```

CLI 实测：

```
claude    2.1.278 (Claude Code)
codex     0.155.1
grok      1.0.13  (二进制 --version；npm 包 1.0.34)
```

本机 **没有** 全局 `gemini` / `zcf` / `cpa` / JDK / Gradle / Android SDK / docker。
需要那些走兄弟目录 [`../dev-env-setup/`](../dev-env-setup/)。

---

## 04  ·  AI 拓扑

本机 **当前** 不是 grok-cli-runanytime 那条 `127.0.0.1:8899` thinking-proxy。
Grok CLI 直连 `GROK_MODELS_BASE_URL`。Claude Code 走另一条网关。

```
Grok CLI
   GROK_MODELS_BASE_URL = https://x-api.cfd/v1
   GROK_RELAY_API_KEY   = <本机 ~/.bashrc，不进 git>
   默认模型             = grok-4.6  ·  reasoning xhigh
   ui.permission_mode   = always-approve
   ui.yolo              = false     (命令行另有 grok --yolo)

Claude Code
   ANTHROPIC_BASE_URL   = https://runanytime.hxi.me
   ANTHROPIC_API_KEY    = <本机 ~/.claude/settings.json，不进 git>
   模型全套             = grok-4.6
   outputStyle          = engineer-professional
   statusLine           = ~/.claude/ccline/ccline
   ~/.claude/config.json  primaryApiKey = "zcf"

Codex CLI
   model_provider       = any
   model                = gpt-6-astra
   reasoning            = high
   auth.json            = ~/.codex/auth.json   权限 600，不进 git
                          键名 ANY_API_KEY / CPA_API_KEY / OPENAI_API_KEY

        any ──► https://anyrouter.top/v1          wire_api=responses
                 temp_env_key = ANY_API_KEY
                 该 provider 块内 model = gpt-5.2   (当前没用它当全局 model)

        cpa ──► http://85.8.151.190:8317/v1       wire_api=responses
                 temp_env_key = CPA_API_KEY
                 model = gpt-5.6-sol
```

Codex 信任目录：

```
/home/dev/codex
/home/dev/cline
/home/dev/cline/pd-monitor
/home/dev/cline/pd-monitor-v2
```

高峰挤 anyrouter：用 [`../codex-init-session/`](../codex-init-session/)。禁止并行多开，失败 thread_id 不要 resume。

---

## 05  ·  新机复用

不提供 `| bash` 一键覆盖家目录——那会把别人的 Key 布局写进你的机器。
按文件拷模板，再自己 export。

```bash
# 0. 系统侧（Debian 13，按需）
apt-get update
apt-get install -y git curl wget screen htop btop nano \
  openssh-server postgresql-17 redis-server

# 0b. 4G 内存机：swap + 整机 I/O 看门狗（见 §07）
# cd CommonUserScripts/HK3DEV/examples/vps-guard && sudo ./install.sh && sudo ./setup-swap-4g.sh

# 1. AI CLI：走本仓 dev-env-setup，或 npm 全局
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh \
  | bash -s -- --yes --items nano,htop,btop,screen,claude,codex,grok

# 2. 配置模板（已 clone 本仓时）
REPO=./CommonUserScripts/HK3DEV/examples

install -d ~/.codex ~/.claude ~/.grok
cp "$REPO/codex-config.toml.example"      ~/.codex/config.toml
cp "$REPO/claude-settings.example.json"   ~/.claude/settings.json
cp "$REPO/claude-config.json.example"     ~/.claude/config.json
cp "$REPO/CLAUDE.md.example"              ~/.claude/CLAUDE.md
cp "$REPO/grok-config.toml.example"       ~/.grok/config.toml

# git 身份
cp "$REPO/gitconfig.example" ~/.gitconfig   # 或只抄 [user] / [init]

# bashrc：把 snippet 追加到 ~/.bashrc，不要整文件覆盖发行版 bashrc
cat "$REPO/bashrc.snippet.sh" >> ~/.bashrc
nano ~/.bashrc                              # 填 GROK_RELAY_API_KEY
nano ~/.claude/settings.json                # 填 ANTHROPIC_API_KEY
# Codex Key 放环境变量或 ~/.codex/auth.json（chmod 600），不要提交
```

必填环境变量（名字必须对上 `temp_env_key` / `env_key`）：

```
GROK_RELAY_API_KEY      Grok CLI + ~/.grok/config.toml 各模型
ANTHROPIC_API_KEY       Claude Code → runanytime.hxi.me
ANY_API_KEY             Codex provider "any"
CPA_API_KEY             Codex provider "cpa"
```

`~/.codex/auth.json` 由 Codex 自己写，键名采集时是
`ANY_API_KEY` / `CPA_API_KEY` / `OPENAI_API_KEY`。不要手造一份推进 git。

改完：

```bash
source ~/.bashrc
claude --version
codex --version
grok --version
ss -tlnp | rg '22|5432|6379'
```

Grok 若要改回 thinking-proxy（剥 `signature`），走
[`../grok-cli-runanytime/`](../grok-cli-runanytime/)，
把 `GROK_MODELS_BASE_URL` 改成 `http://127.0.0.1:8899/v1`。
**当前 3HK 没有这么配。**

---

## 06  ·  配置要点

**bashrc** — 发行版默认 + grok installer PATH + 两个 export。
Key 占位，URL 保留本机值 `https://x-api.cfd/v1`。

**git** — `user.name=FX`，noreply `96124914+idlm@users.noreply.github.com`，
`init.defaultBranch=main`，`gh auth git-credential`。

**Claude permissions** — 本机几乎全开（Bash/Edit/Write/Web* 以及一串 mcp__\*）。
新机若收紧，先删 `examples` 里不需要的项。

**Claude 全局指令** — `~/.claude/CLAUDE.md` 一行：`Always respond in Chinese-simplified`。

**ccline** — `@cometix/ccline`，statusLine 调 `~/.claude/ccline/ccline`。
`models.toml` 是上游示例，无 Key，不必进本目录。

**pandalive-monitor** — `~/.config/pandalive-monitor/` 是 Electron/Chromium 运行时
（Crashpad / SingletonLock），不是应用配置，不复制。

---

## 07  ·  事故：Cline 打满磁盘 → 限 I/O → 看门狗过紧 OOM

采集日当天的因果链。数字来自本机 dmesg / cgroup / `free`，换机器请重测。

### 发现

1. **Cline 会话把磁盘 I/O 打爆。** 观测到当前 60.5 / 峰值 96.4 / 平均 34.7 MiB/s。4 vCPU + 单盘 QEMU 虚拟机在这个量级会直接卡住 SSH。
2. **用户要求整机 30–40 MiB/s，不是每个 slice 各 35。** 两个顶层 slice 的带宽要加总。
3. **root cgroup 写 `io.max` 失败。** `io` 已通过 `cgroup.subtree_control` 委派，`/sys/fs/cgroup/io.max` 不存在或 `Permission denied`。所谓“全局”只能落在 `user.slice` + `system.slice`。
4. **第一版看门狗过紧，把 Cline 自己杀掉。** 无 swap、`MemorySwapMax=0`、`user.slice` `MemoryMax` 一度压到 ~2.2G / 紧急档 1.4G，再叠加每 tick `drop_caches`。20:01:15 dmesg：`oom-kill` `CONSTRAINT_MEMCG` 约束 `/user.slice`，先杀 `7za`（anon ~1.1G），再杀 `cline`（当时 usage 2791MB vs limit 2662MB）。会话 `terminal_marker=failed_external_process_exit`。不是模型、不是 pin、不是 OAuth。
5. **`user-0.slice` 再写一份 `io.max` 会叠乘。** 清掉子 slice 的独立限速，只留顶层。

### 解决

| 步骤 | 做法 | 为什么 |
|:--|:--|:--|
| 会计 | `DefaultIOAccounting/CPUAccounting/MemoryAccounting=yes` | 没有 accounting，slice 的 BandwidthMax 不生效 |
| 基线限速 | `user.slice` 24M + `system.slice` 24M，设备 `8:0` = `/dev/sda` | 合计落在「略宽于 30–40」；看门狗再往下压 |
| 看门狗 | `vps-guard.timer` 每 30s 读 PSI / load / MemAvailable% | 冲高再收紧，不杀进程、不动 AI 钉死 |
| 滞回 | 进入/退出阈值分离 + 连续 2 tick 确认 | 消除 ok↔high↔emergency 抖动 |
| drop_caches | 仅 emergency，且间隔 ≥ 900s | 第一次每 tick drop，page cache 被打空，I/O 更炸 |
| 内存上限 | user `MemoryMax=3600M` / high 3400M / emergency 3200M | 给 Cline + 压缩任务留空间 |
| swap | `/swapfile` 4G + fstab；`memory.swap.max=max` | 无 swap 时 MemoryMax 是硬杀；`MemorySwapMax=0` 等于没加 |

落地文件（本机路径 → 本目录模板）：

```
/usr/local/sbin/vps-guard.sh
/etc/systemd/system/vps-guard.{service,timer}
/etc/systemd/system.conf.d/io-accounting.conf
/etc/systemd/system/user.slice.d/{io-controller,resource-guard}.conf
/etc/systemd/system/system.slice.d/resource-guard.conf
/swapfile + /etc/fstab 一行
```

新机：

```bash
cd CommonUserScripts/HK3DEV/examples/vps-guard
# 磁盘不是 sda：VPS_GUARD_DISK=/dev/vda sudo ./install.sh
sudo ./install.sh
sudo ./setup-swap-4g.sh
```

细节、三档表、排错命令见 [`examples/vps-guard/README.md`](examples/vps-guard/README.md)。

### 验证（本机 2026-09-19 晚）

```
swap           4.0G  ·  used 0
memory.swap.max  user=max  system=max
vps-guard.timer  active
vps-guard state  high          # 当时 IO 仍偏高，档位在收
io.max           8:0 rbps=16000000 wbps=16000000   # high 档 16M+16M
Cline            被 OOM 后已重新起来；钉死 deepseek 未动
```

Cline Pass 钉死 / 缓存命中率不在本目录展开，见 [`../cline-pass-pin/`](../cline-pass-pin/)。本目录 **仍然不放** switcher 配置、JWT、SK。

---

## 不要做

```
✗  把本目录 examples 里的占位符当成真 Key
✗  把 ~/.codex/auth.json / settings.json 原样 git add
✗  把 postgres / redis 从 127.0.0.1 改成 0.0.0.0
✗  并行多开 Codex 挤 anyrouter
✗  把失败 thread_id 当成功去 resume
✗  把这台 3HK 的内网 IP / 磁盘用量当成你新机的事实
✗  往 /sys/fs/cgroup/io.max 写带宽（io 已委派，写不进去）
✗  MemorySwapMax=0  同时又把 MemoryMax 收紧
✗  给 user.slice 和 user-0.slice 各写一份 io.max（会叠乘）
✗  看门狗每 30s drop_caches
```

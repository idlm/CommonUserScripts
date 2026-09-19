# CommonUserScripts

```
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║     ██████╗ ██████╗ ███╗   ███╗███╗   ███╗ ██████╗ ███╗   ██╗        ║
║    ██╔════╝██╔═══██╗████╗ ████║████╗ ████║██╔═══██╗████╗  ██║        ║
║    ██║     ██║   ██║██╔████╔██║██╔████╔██║██║   ██║██╔██╗ ██║        ║
║    ██║     ██║   ██║██║╚██╔╝██║██║╚██╔╝██║██║   ██║██║╚██╗██║        ║
║    ╚██████╗╚██████╔╝██║ ╚═╝ ██║██║ ╚═╝ ██║╚██████╔╝██║ ╚████║        ║
║     ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═══╝        ║
║                                                                      ║
║            U S E R   S C R I P T S          [ public ]               ║
║                                                                      ║
║     curl | wget | bash          no clone required          no keys   ║
╚══════════════════════════════════════════════════════════════════════╝
```

个人常用一键脚本。每个子目录一份独立工具，带自己的 README。

```
status   PUBLIC
branch   main
policy   仓库不放 API Key / Cookie / auth.json
pipe     curl … | bash -s -- <args>     # 不要漏 --
```

---

## 目录

```
CommonUserScripts/
├── grok-cli-runanytime/     Grok CLI  →  runanytime grok-4.6
├── codex-init-session/      Codex     →  anyrouter 高峰排队
├── dev-env-setup/           新机      →  基础 / APK / AI CLI / CPA
├── HK3DEV/                  3HK 主机  →  运行服务 + 脱敏配置
└── cline-pass-pin/          Cline Pass → 钉死 Vercel deepseek 官转
```

| 模块 | 一句话 | 入口 |
|:--|:--|:--|
| [`grok-cli-runanytime`](grok-cli-runanytime/) | 本机 thinking-proxy，剥掉缺 `signature` 的思考块 | `install.sh` |
| [`codex-init-session`](codex-init-session/) | 先探 `/v1/responses`，再单发 `codex exec --json init` | `init-session.sh` |
| [`dev-env-setup`](dev-env-setup/) | 新机预检 → 方案 → 勾选；Android SDK 34 + AI CLI + CPA | `setupv11.sh` |
| [`HK3DEV`](HK3DEV/) | 主机 `3HK` 快照：systemd / 端口 / Claude·Codex·Grok 模板 | `README.md` |
| [`cline-pass-pin`](cline-pass-pin/) | 钉 `ds-v4.1-flash` 到 Vercel `deepseek`，拉高缓存 | `install.sh` |

---

## 01  ·  GROK

```
grok  ──►  127.0.0.1:8899  (thinking-proxy)  ──►  runanytime.hxi.me / grok-4.6
```

直连这条站，Grok CLI 会 `missing field signature` 或 `invalid_request`。装完只改 `~/.bashrc` 里的 Key。

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash
```

```bash
nano ~/.bashrc          # 只改 GROK_RELAY_API_KEY
source ~/.bashrc
~/.grok/start-thinking-proxy.sh
```

带参：`curl … | bash -s -- --start`

---

## 02  ·  CODEX  /  ANYROUTER

```
probe  /v1/responses
   │
   ├─ 500 / 负载已经达到上限 / high demand  →  等，不启动 Codex
   └─ 通  →  单发  codex exec --json "init"
                 │
                 ├─ turn.completed + 助手消息  →  打印回话 ID
                 └─ 有 thread_id 但 turn.failed  →  不算成功
```

不要并行多开。失败 ID 不要拿去 resume。

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$(pwd)" --no-task
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$(pwd)" --no-task
```

只探通道：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$(pwd)" --probe-only
```

```
exit  0  通
      2  过载 / 瞬时
      3  Key / 模型等致命
```

---

## 03  ·  DEV ENV

```
v1.1   setupv11.sh          预检 → 方案 → 勾选 → 进度     [推荐]
v1.0   setupV10.sh          主菜单进组，组内再单装
menu   setup.sh             列出本目录脚本再选
```

需要 root 的入口（系统包 / 全局 npm / `/opt`）用 `sudo` 或切 root。

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh | bash
```

```bash
# 非交互 · 新机推荐方案
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh \
  | bash -s -- --yes --profile new

# 只装 APK 链
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh \
  | bash -s -- --yes --profile apk

# 指定组件
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh \
  | bash -s -- --yes --items nano,htop,claude,grok
```

```
profile   new | base | apk | ai | custom | clean
pack      nano htop btop screen
apk       JDK17  Gradle 8.7  Android SDK 34  →  /opt
ai        zcf  claude  gemini  codex  grok  cpa(=CLIProxyAPI, 不是 npm 同名包)
```

CPA 不代登。装完自己 `cpa --claude-login` / `--codex-login` / `--login`。

---

## 04  ·  HK3DEV  /  3HK

```
3HK  (QEMU / Debian 13)
   ssh :22                 全接口
   postgres :5432          仅 127.0.0.1
   redis    :6379          仅 127.0.0.1
   grok     x-api.cfd/v1
   claude   runanytime.hxi.me / grok-4.6
   codex    anyrouter.top  +  CPA :8317
```

这不是一键安装器。拷 `HK3DEV/examples/` 到家目录，自己填 Key。
真实 `auth.json` / `sk-` / `xapi_` **不进 git**。

说明与复用步骤：[`HK3DEV/README.md`](HK3DEV/)

旧版菜单 / 脚本清单：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupV10.sh | bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setup.sh | bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setup.sh \
  | bash -s -- --list
```

---

## 05  ·  CLINE PASS  /  PIN DEEPSEEK

```
cline-pass/deepseek-v4.1-flash
   默认     Cline 规划器随机上游     →  缓存 miss
   钉死     providerOptions.gateway.only = ["deepseek"]
            Vercel AI Gateway · deepseek 官转
```

现在只能钉 **Vercel 的 deepseek 官转**。OpenRouter 顶层 `provider.only` 会被丢弃。
官方 `GET /v1/models` **不含** `cline-pass/`，模型 id 手写或自己 curl 探测。

不装代理也能钉：在 provider 里自己加那个 JSON 字段。switcher 只是代劳。

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --daemon
```

客户端：`Base URL http://127.0.0.1:3123/v1`，模型 `cline-pass/deepseek-v4.1-flash`。
pi JSON / 自钉片段：[`cline-pass-pin/examples/`](cline-pass-pin/examples/)

---

## 管道约定

GitHub raw 把脚本喂给 bash 时，**脚本自己的参数必须写在 `--` 后面**：

```bash
curl -fsSL <raw-url> | bash -s -- --help
wget -qO-  <raw-url> | bash -s -- --list
```

漏掉 `--`，参数会被 bash 吃掉，脚本看不到。

---

## 不要做

```
✗  把 sk- / Cookie / ~/.codex/auth.json 推进 git
✗  把 GROK_MODELS_BASE_URL 改回网关（等于绕过 thinking-proxy）
✗  并行多开 Codex 挤 anyrouter
✗  把失败 thread_id 当成功去 resume
✗  把 grok-4.6 / 国模接到 Codex 的 /v1/responses
✗  把 CPA 理解成 npm 上的 cpa 包
✗  把 HK3DEV/examples 里的 REPLACE_ME 当真实 Key
✗  把 3HK 的 postgres/redis 从 loopback 改成 0.0.0.0
✗  把 cline-pass Key（sk_）推进 git
✗  用顶层 provider.only 钉 ds-v4.1-flash（会被 Cline 丢弃）
✗  相信官方 /v1/models 会列出 cline-pass/*
```

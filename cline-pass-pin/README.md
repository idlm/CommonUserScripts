# cline-pass-pin

```
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║     ██████╗██╗     ██╗███╗   ██╗███████╗    ██████╗  █████╗ ███████╗ ║
║    ██╔════╝██║     ██║████╗  ██║██╔════╝    ██╔══██╗██╔══██╗██╔════╝ ║
║    ██║     ██║     ██║██╔██╗ ██║█████╗      ██████╔╝███████║███████╗ ║
║    ██║     ██║     ██║██║╚██╗██║██╔══╝      ██╔═══╝ ██╔══██║╚════██║ ║
║    ╚██████╗███████╗██║██║ ╚████║███████╗    ██║     ██║  ██║███████║ ║
║     ╚═════╝╚══════╝╚═╝╚═╝  ╚═══╝╚══════╝    ╚═╝     ╚═╝  ╚═╝╚══════╝ ║
║                                                                      ║
║     pin  DeepSeek V4.1 Flash  →  Vercel  deepseek 官转               ║
║     random routing kills cache     same upstream = cache hit         ║
╚══════════════════════════════════════════════════════════════════════╝
```

把 Cline Pass 的 **DeepSeek V4.1 Flash** 钉死在 **Vercel AI Gateway 的 `deepseek` 官转**。
随机路由会把同一会话打到不同上游，缓存率崩；钉住同一条渠道，缓存立刻上去。

```
status   PIN TEMPLATE + INSTALLER + systemd
model    cline-pass/deepseek-v4.1-flash
pipe     planner  →  Vercel AI Gateway  →  deepseek
listen   127.0.0.1:3123   （仅方法 A / CPA 走 switcher 时）
boot     systemd enable --now   （--install-service）
policy   下文测试 Key 按你的要求明文写入，推 public 仓前删掉
```

本目录 **不 vendoring** [cline-pass-switcher](https://github.com/munmunjaklin458-afk/cline-pass-switcher)（MIT，零 npm 依赖，Node ≥ 18）。
一键脚本 clone 上游、写 `perModel` 钉住段、可选装 systemd、可选把 Cline CLI 指到本机代理。无利益相关。

switcher 作者原话：软件 **只是帮你往请求里加钉上游的字段**。
agent / CPA / 任何能改 chat body 的客户端，自己加下面这一段，就不用装代理。

```json
"providerOptions": { "gateway": { "only": ["deepseek"] } }
```

---

## 本机已跑通（推荐这一条）

2026-09-19 在这台机上实测成功：

```
Cline CLI（已登录 OAuth）
   │  baseUrl = http://127.0.0.1:3123/v1
   │  model   = cline-pass/deepseek-v4.1-flash
   ▼
systemd  cline-pass-switcher.service     reboot 自己起来
   │  注入 providerOptions.gateway.only = ["deepseek"]
   ▼
api.cline.bot  →  finalProvider = deepseek
第二轮相同长前缀  →  cached_tokens 有数字（缓存命中）
```

Cline CLI **没有** requestBodyExtras，不能自己钉。所以本机只改两处：switcher 注入字段，CLI 的 Base URL 指 `:3123`。上游鉴权用本机已经登录的 Cline Pass，**不要再填 `sk_`**。静态 key 过期后网关会返回 `Unauthorized: Please make sure you're using the latest version of Cline and re-authenticate your Cline account.`

先 `cline auth` 登录，再装：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --yes --install-service --pin-cline
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --yes --install-service --pin-cline
```

本仓工作树：

```bash
bash cline-pass-pin/install.sh --yes --install-service --pin-cline
```

做了什么：

| 步 | 动作 |
|:--|:--|
| 1 | clone switcher → `~/.cline-pass-switcher/src` |
| 2 | 写 `config.json`：`perModel[flash].upstreams=["deepseek"]` `pinMode=strict` |
| 3 | 停掉旧 nohup，装 `/etc/systemd/system/cline-pass-switcher.service`，`enable --now` |
| 4 | 已登录的 Cline CLI：只改 `providers.json` 的 `baseUrl` + `model`（登录态不动） |
| 5 | `config.json` 写 `useClineOAuth: true`。代理读 `~/.cline` 的登录态，过期前 5 分钟自动续期 |

装完自检：

```bash
bash cline-pass-pin/pin-ds.sh --status
bash cline-pass-pin/pin-ds.sh --probe
systemctl is-enabled cline-pass-switcher    # enabled
ss -ltnp | grep 3123                        # 127.0.0.1:3123
```

登录态只活在 `~/.cline/data/settings/providers.json`（chmod 600）。代理配置里的 `useClineOAuth` 是开关，**不存放 token，也不写进 systemd unit**。

停开机自启：`systemctl disable --now cline-pass-switcher`，或 `bash pin-ds.sh --uninstall-service`。

---

## 其它办法（一眼看完）

目标只有一件事：让 chat body 带上 `providerOptions.gateway.only: ["deepseek"]`。选你客户端做得到的那条。

| 谁 | 怎么做 | 要不要装 switcher |
|:--|:--|:--|
| **Cline CLI / VSCode** | 一键 `--install-service --pin-cline`（上面那条） | 要。CLI 不会改 body |
| **pi / SDK / 能塞 extras 的 agent** | Base URL 直连官方，body 加 extras | 不要 |
| **Codex CLI** | 另加 `wire_api="chat"` 的 provider，Base URL 指 `:3123/v1` | 要。Codex 没有 extras |
| **Claude Code** | 必须 CPA `:8317` → switcher `:3123`（Anthropic 协议，不能直连） | 要 + CPA |
| **已有 CPA** | `openai-compatibility.base-url` 指 `:3123/v1`（C2） | 要。CPA 不会自己注入 |
| **curl 自检** | POST 官方，JSON 里直接带 `providerOptions` | 不要 |

细节：[方法 A](#方法-a--本机-switcher一键) · [方法 B](#方法-b--agent--provider-自己钉) · [方法 C](#方法-c--cpacliproxyapi接到-cline-pass) · [方法 D](#方法-d--curl-直连自检) · [Codex / Claude](#最简方案codex--claude-code)

---

## 只改配置文件：谁行、谁不行、不行怎么办

判定就一条：**客户端能不能把这段塞进 chat JSON body**。能 = 只改配置，直连官方。不能 = 前面必须垫一层会注入这段的东西。

```json
"providerOptions": { "gateway": { "only": ["deepseek"] } }
```

顶层 `provider.only` 不算。HTTP header 不算。改 Base URL 本身也不算钉住。

### 行：只改 agent 配置，不装任何代理

| 客户端 | 改哪个文件 | 贴什么 |
|:--|:--|:--|
| **pi** | models 配置里的 `clinepass` 块 | [`examples/pi-models.json`](examples/pi-models.json)。flash 那条已带 `requestBodyExtras`。只改 `apiKey`。 |
| **任意能塞 extras 的 agent** | provider 的 `requestBodyExtras` / `extraBody` | [`examples/provider-snippet.json`](examples/provider-snippet.json) 的 `clinepass_direct_pin_vercel` |
| **OpenAI Python SDK** | 调用处，不是独立配置文件 | `extra_body={"providerOptions": {"gateway": {"only": ["deepseek"]}}}` |
| **OpenAI JS SDK** | 调用处 | body 里加 `providerOptions` |
| **curl / 任意 HTTP** | 请求 JSON | 见 [方法 D](#方法-d--curl-直连自检) |

通用最小块（Base URL 直连官方，Key 用 Cline 账户设置的 `sk_`）：

```json
{
  "baseUrl": "https://api.cline.bot/api/v1",
  "apiKey": "sk_你的ClinePassKey",
  "requestBodyExtras": {
    "providerOptions": {
      "gateway": { "only": ["deepseek"] }
    }
  }
}
```

模型手写 `cline-pass/deepseek-v4.1-flash`（官方 `/v1/models` 没有这个前缀）。

extras **只给 flash**。glm / kimi / qwen 不要共用同一个带 `only: ["deepseek"]` 的 provider，否则网关 400。

### 不行：配置文件里没有 extras 旋钮

这三家 **改自己的配置文件钉不住**。原因和解决办法如下。不要在它们的配置里找 `providerOptions` / `requestBodyExtras`——没有。

| 客户端 | 为什么不行 | 解决办法（改哪些文件） |
|:--|:--|:--|
| **Cline CLI / VSCode** | 没有 `requestBodyExtras`。本机登录走 OAuth JWT，不是 `sk_`。 | 1. 装 switcher（注入 extras）。2. 只改 `~/.cline/data/settings/providers.json` 的 `cline-pass.settings.baseUrl` + `model`。OAuth 不动。 |
| **Codex CLI** | 没有 extras。默认 `wire_api=responses`，Cline Pass 是 chat completions。 | 1. 装 switcher。2. `~/.codex/config.toml` **另加**一块 `wire_api="chat"` 的 provider，`base_url` 指 `:3123/v1`。现网 anyrouter **不要改**。 |
| **Claude Code** | 没有 extras，协议还是 Anthropic `/v1/messages`。Cline Pass 是 OpenAI chat。**不能直连** `:3123` 或官方。 | 1. 装 switcher。2. 装 CPA。3. CPA `config.yaml` 的 `base-url` 指 `:3123/v1`。4. `~/.claude/settings.json` 的 `env` 指 CPA `:8317`。 |

下面是这三家各自要改的配置（可拷贝）。**先把 switcher 拉起来**（一键 `--install-service`），再改客户端文件。

#### 1. Cline CLI / VSCode — 解决办法

一键（已登录时）：

```bash
cline auth
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --yes --install-service --pin-cline
```

手改只动这两项（完整片段 [`examples/cline-cli-providers.snippet.json`](examples/cline-cli-providers.snippet.json)）：

```json
{
  "providers": {
    "cline-pass": {
      "settings": {
        "baseUrl": "http://127.0.0.1:3123/v1",
        "model": "cline-pass/deepseek-v4.1-flash"
      }
    }
  },
  "lastUsedProvider": "cline-pass"
}
```

文件：`~/.cline/data/settings/providers.json`。不要动 `accessToken` / `refreshToken`。没有 `cline-pass` 块就先 `cline auth`，不要手建空账号。

#### 2. Codex CLI — 解决办法

`~/.codex/config.toml` **另加**一块，不要改现有的 `any` / `cpa`（完整 [`examples/codex-clinepass.toml`](examples/codex-clinepass.toml)）：

```toml
[model_providers.clinepass]
name = "ClinePass"
base_url = "http://127.0.0.1:3123/v1"
wire_api = "chat"
temp_env_key = "CLINE_PASS_PROXY_KEY"
requires_openai_auth = true
```

```bash
export CLINE_PASS_PROXY_KEY=local
codex -c model_provider="clinepass" -c model="cline-pass/deepseek-v4.1-flash"
```

`sk_` 只给 switcher（`CLINE_PASS_KEY`），不要写进 `config.toml` / `auth.json`。`wire_api` 必须是 `chat`，抄现网的 `responses` 会打不通。

#### 3. Claude Code — 解决办法

两层，缺一层都不行。

**CPA `config.yaml`**（指 switcher，不是官方；完整 [`examples/cpa-cline-pass.yaml`](examples/cpa-cline-pass.yaml)）：

```yaml
api-keys:
  - "cpa-local"
openai-compatibility:
  - name: "cline-pass"
    base-url: "http://127.0.0.1:3123/v1"
    api-key-entries:
      - api-key: "local"
    models:
      - name: "cline-pass/deepseek-v4.1-flash"
        alias: "ds-flash"
```

**`~/.claude/settings.json` 的 `env`** 只改这几项（完整 [`examples/claude-settings.env.json`](examples/claude-settings.env.json)）：

```json
{
  "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
  "ANTHROPIC_API_KEY": "cpa-local",
  "ANTHROPIC_MODEL": "ds-flash",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": "ds-flash",
  "ANTHROPIC_DEFAULT_SONNET_MODEL": "ds-flash",
  "ANTHROPIC_DEFAULT_OPUS_MODEL": "ds-flash"
}
```

| 钥匙 | 写在哪 | 值 |
|:--|:--|:--|
| Cline `sk_` | switcher `accounts[].key` / `CLINE_PASS_KEY` | 账户设置创建 |
| switcher `proxyKey` | CPA `api-key-entries` | 本地空鉴权随便填 |
| CPA `api-keys` | Claude `ANTHROPIC_API_KEY` | 上例 `cpa-local` |

`ANTHROPIC_BASE_URL` **不要**直接指 `http://127.0.0.1:3123`（协议不对）。也不要指官方 `api.cline.bot`。

已有 CPA、下游是 OpenAI chat 且自己能塞 extras：可以 C1 直连官方（见方法 C）。Claude Code 重建 body，extras 会丢，**必须 C2**。

### 对照：三家不行的，不要做的事

```
✗  在 Cline providers.json 里找 requestBodyExtras
✗  在 Codex config.toml 里写 providerOptions / extra_body
✗  把 Claude ANTHROPIC_BASE_URL 指 127.0.0.1:3123 或 api.cline.bot
✗  给 Codex 抄现网的 wire_api = "responses"
✗  改现网 anyrouter / runanytime 来接 Cline Pass（另开一条）
✗  以为改了 Base URL 就等于钉住了（没 extras / 没 switcher = 仍随机路由）
```

---

## 目录

- [本机已跑通（推荐这一条）](#本机已跑通推荐这一条)
- [其它办法（一眼看完）](#其它办法一眼看完)
- [只改配置文件：谁行、谁不行、不行怎么办](#只改配置文件谁行谁不行不行怎么办)
- [实测：能不能钉住](#实测能不能钉住)
- [这解决什么问题](#这解决什么问题)
- [最简方案：Codex / Claude Code](#最简方案codex--claude-code)
- [客户端怎么指](#客户端怎么指)
- [完成本任务的所有方法](#完成本任务的所有方法)
  - [方法 A · 本机 switcher（一键）](#方法-a--本机-switcher一键)
  - [方法 B · agent / provider 自己钉](#方法-b--agent--provider-自己钉)
  - [方法 C · CPA（CLIProxyAPI）接到 Cline Pass](#方法-c--cpacliproxyapi接到-cline-pass)
  - [方法 D · curl 直连自检](#方法-d--curl-直连自检)
- [一条命令（curl / wget）](#一条命令curl--wget)
- [官方 `/v1/models` 不含 `cline-pass/`](#官方-v1models-不含-cline-pass)
- [pin-ds.sh 选项](#pin-dssh-选项)
- [用量](#用量经验数字不是官方报价)
- [仓库文件](#仓库文件)
- [其它设置](#其它设置)
- [不要做](#不要做)
- [参考仓库](#参考仓库)

---

## 实测：能不能钉住

**能。** 2026-09-19 用测试 `sk_` 直连 `https://api.cline.bot/api/v1/chat/completions`，模型 `cline-pass/deepseek-v4.1-flash`，看响应里的

`data.choices[0].message.provider_metadata.gateway.routing.finalProvider`

| 请求 body | HTTP | `finalProvider` | 规划器怎么说 |
|:--|:--|:--|:--|
| 不带 extras | 200 | `fireworks`（随机） | 候选十几家：baseten → fireworks → alibaba → … → deepseek |
| `providerOptions.gateway.only: ["deepseek"]` | 200 | **`deepseek`** | `Provider set restricted to: deepseek. … execution order: deepseek(system)` |
| 同上，改钉 `togetherai`（对照） | 200 | **`togetherai`** | 字段确实控路由，不是碰巧 |
| `only: ["definitely-not-a-provider"]` | 500 / 上游 400 | — | 列出当前可钉 slug（见下） |
| 顶层 `provider.only: ["deepseek"]` | 当没钉 | 随机 | planner 管道会丢这个字段 |

当前 Vercel 侧可钉 slug（harvest `__probe__` / 钉假渠道时网关返回）：

```
alibaba  baseten  boundless  deepinfra  deepseek  fireworks
gmicloud  modal  morph  novita  parasail  particle
relace  runware  togetherai  wafer
```

**要钉的是 `deepseek`，不是 `openrouter`。**

注意：`max_tokens: 16` 时这条模型会先写 reasoning，内容被吃光，接口返回 `empty response content`（HTTP 500）。
这 **不是** 钉失败。探测 / 自检用 `max_tokens >= 256`，看 `provider_metadata`，不要看这句空内容。

---

## 这解决什么问题

```
cline-pass/deepseek-v4.1-flash
        │
        ├─ 默认：Cline 规划器随机挑上游     →  缓存 miss，额度白烧
        └─ 钉死：providerOptions.gateway.only = ["deepseek"]
                  │
                  └─ 同一条 Vercel deepseek 官转  →  cache hit
```

两条管道写法完全不同（来自 switcher 源码 `injectPrefs`）：

| 管道 | 后端 | 钉住字段 | 现在 ds-v4.1-flash |
|:--|:--|:--|:--|
| **planner** | Vercel AI Gateway | `providerOptions.gateway.only / order / sort` | **走这条** |
| **direct** | OpenRouter | 顶层 `provider.only / order` | 上午还能钉，**现在不让钉了** |

顶层 `provider.*` 会被 Cline 丢弃，这就是「换上游不生效」的原因。
规划器管道必须写嵌套的 `providerOptions.gateway`。

**更正（2026-09）：现在只能钉 Vercel 的 deepseek 官转，OpenRouter 不让钉了。**
slug 仍是 `deepseek`。

---

## 最简方案：Codex / Claude Code

Codex CLI 和 Claude Code **都不会**往 JSON body 里塞 `providerOptions`。
Claude Code 讲的是 Anthropic `/v1/messages`，Cline Pass 是 OpenAI `/v1/chat/completions`，**不能直连**。

所以两边一起用，只做两件事：**装 switcher 注入钉住** + **Claude 前面再垫一层 CPA 做协议翻译**。
不要改 Codex / Claude 去「自己钉」——它们没这个旋钮。

```
Claude Code  ──►  CPA :8317 /v1/messages     ──►  switcher :3123/v1  ──►  api.cline.bot
Codex        ──►  switcher :3123/v1  （wire_api=chat，可跳过 CPA）
                 或 CPA :8317/v1     （wire_api=chat，和 Claude 共用一条上游）
```

### 0. 先把 switcher 拉起来（两边共用）

先 `cline auth`。不要 export `sk_`：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --yes --install-service
```

本机已 clone 时：`bash cline-pass-pin/pin-ds.sh --yes --install-service`

没有 systemd 才用 `--daemon`（reboot 会丢）。

### 1. Codex：只改 `~/.codex/config.toml`

Cline Pass 不是 Responses API。现有的 `any` / `cpa`（`wire_api = "responses"`、anyrouter / 远端 `:8317`）**不要改**，另加一块：

```toml
# 用的时候切过去：  codex -c model_provider="clinepass" -c model="cline-pass/deepseek-v4.1-flash"
# 或把下面两行临时改成全局默认（会离开 anyrouter）

[model_providers.clinepass]
name = "ClinePass"
base_url = "http://127.0.0.1:3123/v1"
wire_api = "chat"
temp_env_key = "CLINE_PASS_PROXY_KEY"
requires_openai_auth = true
```

```bash
# switcher 本地 proxyKey 为空 = 不鉴权；占位即可
export CLINE_PASS_PROXY_KEY=local
codex -c model_provider="clinepass" -c model="cline-pass/deepseek-v4.1-flash"
```

`sk_` 只活在 switcher 的 `accounts[].key`（上面那条 `CLINE_PASS_KEY`），**不要**写进 `config.toml` / `auth.json`。

### 2. Claude Code：必须过 CPA，再改 `~/.claude/settings.json`

本机当前 **没有** 装 CPA。Claude 不能直连 `:3123`。装好 CPA 后，`openai-compatibility` 指 switcher（方法 C2）：

```yaml
# CPA config.yaml 片段，完整见 examples/cpa-cline-pass.yaml
api-keys:
  - "cpa-local"          # Claude / Codex 连 CPA 用这把，不是 Cline 的 sk_
openai-compatibility:
  - name: "cline-pass"
    base-url: "http://127.0.0.1:3123/v1"
    api-key-entries:
      - api-key: "local" # switcher proxyKey；空鉴权随便填
    models:
      - name: "cline-pass/deepseek-v4.1-flash"
        alias: "ds-flash"
```

`~/.claude/settings.json` 的 `env` **只改这几项**（别动别的权限 / statusLine）：

```json
"ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
"ANTHROPIC_API_KEY": "cpa-local",
"ANTHROPIC_MODEL": "ds-flash",
"ANTHROPIC_DEFAULT_HAIKU_MODEL": "ds-flash",
"ANTHROPIC_DEFAULT_SONNET_MODEL": "ds-flash",
"ANTHROPIC_DEFAULT_OPUS_MODEL": "ds-flash"
```

| 谁 | 改哪个文件 | 填什么 |
|:--|:--|:--|
| switcher | `CLINE_PASS_KEY` / 控制台账号 | Cline 的 `sk_` |
| Codex | `~/.codex/config.toml` 新 provider | `base_url=http://127.0.0.1:3123/v1`，`wire_api=chat` |
| Claude | `~/.claude/settings.json` `env` | `ANTHROPIC_BASE_URL=http://127.0.0.1:8317`，Key = CPA `api-keys` |
| CPA | `config.yaml` | `base-url` 指 `:3123/v1`，**不要**指官方（Claude 重建 body，extras 会丢） |

本机现在 Claude 走 `runanytime.hxi.me` / `grok-4.6`，Codex 走 `anyrouter` / `gpt-6-astra`。
上面是**另开一条** Cline Pass 钉住通道，不是覆盖现网。切回去把 BASE_URL / `model_provider` 改回即可。

HK3DEV 那条远端 `http://85.8.151.190:8317` 接的是 Codex 中转，**不是** Cline Pass。不要把 `sk_` 填进那边。

---

## 客户端怎么指

走代理（脚本装好 switcher 之后）：

```
Base URL    http://127.0.0.1:3123/v1
API Key     控制台「访问与安全」的 proxyKey；本地空 = 不鉴权
Model       cline-pass/deepseek-v4.1-flash
```

不装代理、自己钉（pi / 任何能塞 request body extras 的客户端）：

```json
{
  "baseUrl": "https://api.cline.bot/api/v1",
  "apiKey": "sk_你的ClinePassKey",
  "requestBodyExtras": {
    "providerOptions": {
      "gateway": { "only": ["deepseek"] }
    }
  }
}
```

Codex / Claude Code **做不到**「自己钉」这一段（没有 requestBodyExtras）。它们走上面的最简方案：只改 Base URL / 模型，钉住交给 switcher。

推 public 仓前把这段 Key 删掉。

---

## 完成本任务的所有方法

目标只有一件事：让发往 Cline Pass 的 chat body 带上 `providerOptions.gateway.only: ["deepseek"]`。
四条路等价，选你客户端做得到的那条。

```
你的客户端
   │
   ├─ A  ──►  127.0.0.1:3123/v1   (switcher 注入钉住)  ──►  api.cline.bot
   ├─ B  ──►  api.cline.bot         (provider extras 自己带钉住)
   ├─ C  ──►  CPA :8317             ──►  api.cline.bot
   │              │                      （下游 OpenAI body 可透传 extras）
   │              └─ extras 丢了 / CPA 自己不会注入
   │                     └──►  先 A，再让 CPA 指 switcher
   └─ D  ──►  curl 直连自检
```

Key 一律 Cline 账户设置里创建的 `sk_`。下文测试 Key 按你的要求明文写在「客户端怎么指」；推仓前删掉。
Cline CLI 本机登录走的是 **OAuth JWT**，不是 `sk_`；CLI 没有 requestBodyExtras，钉住请走方法 A。
Codex / Claude Code 同样没有 extras，走 [最简方案](#最简方案codex--claude-code)。

---

### 方法 A · 本机 switcher（一键）

适合：Cline 扩展 / CLI、不会改 body 的客户端、想在控制台里看实际命中渠道。

1. 跑下面的 [一条命令](#一条命令curl--wget)：`--install-service` 装 systemd 开机自启。Cline CLI 已登录再加 `--pin-cline`。
2. 不会改 body 的客户端改三处：

```
Base URL    http://127.0.0.1:3123/v1
API Key     控制台「访问与安全」的 proxyKey；本地空 = 不鉴权
Model       cline-pass/deepseek-v4.1-flash
```

3. 上游默认用本机 Cline 登录态（`useClineOAuth: true`）。先 `cline auth`。不要再粘静态 `sk_`，过期就会 Unauthorized。
4. Cline CLI 片段：[`examples/cline-cli-providers.snippet.json`](examples/cline-cli-providers.snippet.json)（只改 `baseUrl` / `model`，OAuth 不动）。

switcher 按 `perModel[模型].upstreams = ["deepseek"]` + `pinMode: strict` 注入 planner 字段，
响应头里能看到 `X-Cline-Target-Upstream` / `X-Cline-Actual-Upstream`。

模板：[`examples/config.ds-v4.1-flash.json`](examples/config.ds-v4.1-flash.json)

---

### 方法 B · agent / provider 自己钉

适合：pi、OpenAI SDK、任何能在 chat/completions JSON 上合并 extras 的 agent。
**不装 switcher。** Base URL 直连官方。

通用 extras（所有这类客户端都是这一段）：

```json
{
  "providerOptions": {
    "gateway": {
      "only": ["deepseek"]
    }
  }
}
```

完整 provider 块：

```json
{
  "baseUrl": "https://api.cline.bot/api/v1",
  "api": "openai-completions",
  "authHeader": true,
  "apiKey": "sk_你的ClinePassKey",
  "requestBodyExtras": {
    "providerOptions": {
      "gateway": { "only": ["deepseek"] }
    }
  }
}
```

各客户端怎么填：

| 客户端 | 怎么钉 |
|:--|:--|
| **pi** | 把 [`examples/pi-models.json`](examples/pi-models.json) 的 `clinepass` 块合进 models 配置，只改 `apiKey`。flash 那条已带 `requestBodyExtras`。若你的 pi 只认 **provider 级** extras、不认 model 级：单独做一个只有 flash 的 provider，把 extras 放在 provider 根上，**不要**让 glm / kimi / qwen 共用（否则它们也会被钉到 `deepseek`，网关会 400）。 |
| **OpenAI Python / JS SDK** | `extra_body={"providerOptions": {"gateway": {"only": ["deepseek"]}}}`（Python）或 `providerOptions` 放进 body。 |
| **curl / 任意 HTTP** | POST JSON 里直接带 `providerOptions`，见方法 D。 |
| **Cline VSCode / Cline CLI** | 没有公开的 requestBodyExtras。指方法 A 的本机代理。 |
| **Codex CLI** | 没有 extras。`~/.codex/config.toml` 加 `wire_api="chat"` 的 provider，Base URL 指 `:3123/v1`。见最简方案。 |
| **Claude Code** | 没有 extras，协议还是 Anthropic。必须 CPA `:8317` → switcher。改 `ANTHROPIC_BASE_URL` / `ANTHROPIC_MODEL`。见最简方案。 |
| **其它 agent** | 搜配置项：`requestBodyExtras` / `extra_body` / `extraBody` / `default_headers` 不够，必须进 **JSON body**。只能加 HTTP header、不能改 body → 用方法 A。 |

走代理时把 `baseUrl` 改成 `http://127.0.0.1:3123/v1`，extras 可省略（switcher 会注入）。

对照片段：[`examples/provider-snippet.json`](examples/provider-snippet.json)

---

### 方法 C · CPA（CLIProxyAPI）接到 Cline Pass

适合：已经在用 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)（本仓里简称 CPA，默认 `:8317`），把 Cline Pass 当一条 OpenAI 兼容上游。

CPA **能**当 Cline Pass 的客户端；CPA **配置里没有** `extra_body` / `providerOptions` 这种「替你钉上游」的旋钮。
钉住仍然靠 body 里那一段。分两种接法：

#### C1 · CPA 直连官方（依赖 extras 透传）

`config.yaml` 的 `openai-compatibility`（字段名以 [上游示例](https://github.com/router-for-me/CLIProxyAPI/blob/main/config.example.yaml) 为准）：

```yaml
openai-compatibility:
  - name: "cline-pass"
    base-url: "https://api.cline.bot/api/v1"
    api-key-entries:
      - api-key: "sk_你的ClinePassKey"          # Cline 账户设置里的 sk_，不是 CPA 自己的 api-keys
    models:
      - name: "cline-pass/deepseek-v4.1-flash"
        alias: "ds-flash"          # 下游客户端看到的名字，可改
```

完整可拷贝块：[`examples/cpa-cline-pass.yaml`](examples/cpa-cline-pass.yaml)

然后：

```
下游客户端  →  http://127.0.0.1:8317/v1   （CPA 的 api-keys）
CPA         →  https://api.cline.bot/api/v1
model       下游用 alias（上例 `ds-flash`），CPA 改写成 cline-pass/deepseek-v4.1-flash
```

**透传事实（读过 CPA 源码）：**

- OpenAI Chat Completions → OpenAI 兼容上游：翻译层只在 alias 时改 `model`，**其余 JSON 原样转发**。
  下游如果自己在 body 里带了 `providerOptions`，CPA 会交给 Cline Pass，钉住生效。
- 下游走 **Claude / Gemini / Responses** 协议时，CPA 会重建 body，`providerOptions` **会丢**。
  这种客户端不能靠 C1 钉住。

所以 C1 的前提：下游客户端讲 OpenAI chat/completions，并且能塞 extras（同方法 B）。

#### C2 · CPA 前面再加 switcher（稳妥，推荐不会改 body 的客户端）

CPA 不会自己注入钉住字段。下游协议会重建 body、或你懒得在每个客户端里塞 extras 时，让 CPA 指本机 switcher：

```
下游  →  CPA :8317  →  127.0.0.1:3123/v1  (switcher 注入)  →  api.cline.bot
```

```yaml
openai-compatibility:
  - name: "cline-pass"
    base-url: "http://127.0.0.1:3123/v1"   # 不是 api.cline.bot
    api-key-entries:
      - api-key: "local"                   # switcher 的 proxyKey；本地空鉴权可随便填
    models:
      - name: "cline-pass/deepseek-v4.1-flash"
        alias: "ds-flash"
```

`sk_` 只放在 switcher 的 `accounts[].key`（或 `CLINE_PASS_KEY`），不要和 CPA 的 `api-keys` 搞混：

| 钥匙 | 谁核验 | 值 |
|:--|:--|:--|
| CPA `api-keys` | 下游 → CPA | 你给 Codex / Claude Code / 其它客户端的那把 |
| switcher `proxyKey` | CPA → switcher | 本地可空 |
| Cline Pass `sk_` | switcher → api.cline.bot | 账户设置创建 |

先方法 A 把 switcher 拉起来，再改 CPA 的 `base-url`。

HK3DEV 里 CPA 默认 `:8317`，和这里是同一个软件；那边接的是 Codex 中转，**不是** Cline Pass。不要把两套 `base-url` 抄串。

---

### 方法 D · curl 直连自检

```bash
export CLINE_PASS_KEY='sk_你的ClinePassKey'

curl -fsS https://api.cline.bot/api/v1/chat/completions \
  -H "Authorization: Bearer ${CLINE_PASS_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "cline-pass/deepseek-v4.1-flash",
    "messages": [{"role":"user","content":"Reply with the single word PING"}],
    "max_tokens": 256,
    "providerOptions": {"gateway": {"only": ["deepseek"]}}
  }'
```

成功时在 JSON 里找：

```
provider_metadata.gateway.routing.finalProvider == "deepseek"
planningReasoning 含 "Provider set restricted to: deepseek"
```

**不要把输出里的 Authorization / 完整响应贴进 git。** `max_tokens` 太小会 `empty response content`，先加大再判断。

---

## 一条命令（curl / wget）

不 clone 本仓。脚本会：检查 Node ≥ 18 → clone switcher → 写 `~/.cline-pass-switcher/config.json`（钉 `deepseek` / strict，`useClineOAuth: true`）。
推荐直接 `--install-service`（systemd 开机自启）。Cline CLI 已登录再加 `--pin-cline`。不要设置 `CLINE_PASS_KEY`。

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
```

管道带参必须用 `bash -s --`（不要漏 `--`）：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --yes --install-service --pin-cline
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --help
```

```bash
# 只看将要写入的 config（不写盘、不 clone）
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --print-config
```

先登录再装。静态 `sk_` 会过期，默认不要填：

```bash
cline auth
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --yes --install-service --pin-cline

# 没有 systemd 才用 --daemon（reboot 会丢）
# curl … | bash -s -- --yes --daemon
```

本地已 clone 本仓时：

```bash
bash cline-pass-pin/install.sh --yes --install-service --pin-cline
# 或直接
bash cline-pass-pin/pin-ds.sh --help
```

---

## 官方 `/v1/models` 不含 `cline-pass/`

`GET https://api.cline.bot/api/v1/models` **不会**返回 `cline-pass/` 前缀。
查模型让 agent 自己 curl 探测，或手写清单。本目录已经写进：

```
cline-pass/deepseek-v4.1-flash     主钉，planner → Vercel deepseek
cline-pass/deepseek-v4-flash       同族一并钉，防切短名又随机
cline-pass/glm-5.3
cline-pass/glm-5.3-flash           官方目录没有，自己试试
cline-pass/kimi-k3
cline-pass/qwen3.8-max
```

探测走本机代理，由代理带上已登录的 Cline 凭证。**不要把 Authorization 贴进 git**：

```bash
# 本机目录：knownModels + perModel
curl -fsS http://127.0.0.1:3123/v1/models | python3 -m json.tool | head

# 试一个模型（200 且内容非空 = 登录态有效；401 / Unauthorized = 先 cline auth 再重开代理）
curl -fsS http://127.0.0.1:3123/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"cline-pass/deepseek-v4.1-flash","messages":[{"role":"user","content":"Reply with the word OK"}],"max_tokens":800}'
```

走本机代理时，`/v1/models` 返回的是 `knownModels` + `perModel` 的并集，不是官方目录。

---

## pin-ds.sh 选项

| 选项 | 作用 |
|:--|:--|
| （无） | clone + 写 config，打印启动命令 |
| `--install-service` | 配完装 systemd，`enable --now`（开机自启，推荐） |
| `--uninstall-service` | 关掉开机自启并删 unit（config / src 保留） |
| `--pin-cline` | 已登录的 Cline CLI：只改 `providers.json` 的 `baseUrl` / `model` |
| `--daemon` | nohup 后台；reboot 会丢。能装 systemd 请用 `--install-service` |
| `--start` | 配完前台启动（管道里别用，stdin 已被占用） |
| `--stop` | 停 nohup；若 systemd 在跑则 `systemctl stop`（不 disable） |
| `--status` | 端口 / nohup / systemd / 钉住段 / Cline baseUrl（不打印 Key） |
| `--probe` | `GET http://127.0.0.1:3123/v1/models` |
| `--print-config` | 打印将要写入的 JSON，不写盘 |
| `--yes` / `-y` | 已有 config 时覆盖 `perModel` / 端口 / `useClineOAuth`（**保留 accounts / proxyKey**） |
| `--static-key` | 关闭登录续期，改回静态 `sk_`。过期会再报 Unauthorized |
| `--no-clone` | 已有 `src/` 时不 git pull |
| `--help` | 帮助 |

没有 `--direct-pin`。直连自钉是方法 B，改客户端配置，不是脚本开关。

环境变量：

| 变量 | 默认 | 说明 |
|:--|:--|:--|
| `CLINE_PASS_USE_OAUTH` | `1` | `1` 读本机 Cline 登录态并自动续期。`0` 才用静态 `sk_` |
| `CLINE_PASS_KEY` | 空 | 仅 `CLINE_PASS_USE_OAUTH=0` 时的静态 key。默认留空 |
| `PROXY_KEY` | 空 | 下游代理密钥；本地空 = 不鉴权 |
| `CLINE_PASS_PIN_HOME` | `~/.cline-pass-switcher` | 数据目录（config / pid / log / src） |
| `CLINE_PASS_PIN_PORT` | `3123` | 监听端口 |
| `CLINE_PASS_PIN_BIND` | `127.0.0.1` | 绑定地址。**不要改成 0.0.0.0 除非你知道自己在干什么** |
| `CLINE_PASS_PIN_UPSTREAM` | `deepseek` | 钉住的渠道 slug |
| `CLINE_PASS_PIN_MODEL` | `cline-pass/deepseek-v4.1-flash` | 主模型 |
| `CLINE_PASS_SWITCHER_REPO` | munmunjaklin458-afk/cline-pass-switcher | 上游 git |
| `CLINE_PASS_PIN_RAW_BASE` | 本仓 raw | 仅 `install.sh`，测试用 |

已有 config 且里面有 Key：默认 **不覆盖**。要改钉住段加 `--yes`。accounts 始终从旧文件合并过来。
`--print-config` 会 `mkdir` 家目录，空目录 ≠ 已安装。

---

## 用量（经验数字，不是官方报价）

Cline Pass 按套餐额度走，下面是本机实测量级，用来判断「钉缓存值不值」：

```
今天      ~1.5 亿 tokens  dsv4.1f     月额度掉 ~5%
估        ~2 USD / 月                  ~30 亿  4.1f
requests  按写代码平均 250k tokens/次  ~12000 次
首月      5 USD 也划算
```

**不算 I/O token**，只算 requests × 平均 tokens。
`pi-models.json` 里 flash 的标价仅供客户端 UI 显示：

```
input 0.44   output 1.32   cacheRead 0.014   cacheWrite 0     USD / 1M
```

cacheRead 比 input 便宜两个数量级——这就是为什么要钉死同一上游。

---

## 仓库文件

```
cline-pass-pin/
├── README.md                              本文件
├── install.sh                             curl/wget 入口（再拉 pin-ds.sh）
├── pin-ds.sh                              clone + 写钉住 config + systemd / Cline CLI
└── examples/
    ├── pi-models.json                     pi 的 clinepass provider 块
    ├── config.ds-v4.1-flash.json          switcher 本机配置模板（无 Key）
    ├── provider-snippet.json              走代理 vs 直连自钉
    ├── cpa-cline-pass.yaml                CPA openai-compatibility 片段
    ├── codex-clinepass.toml               ~/.codex/config.toml 追加块
    ├── claude-settings.env.json           Claude settings.json 的 env 片段
    ├── cline-cli-providers.snippet.json   Cline CLI 只改 baseUrl / 模型
    └── cline-pass-switcher.service        systemd 模板（无 Key）
```

本机装完（不进 git）：

```
~/.cline-pass-switcher/
├── config.json          含 accounts[].key，chmod 600
├── src/                 munmunjaklin458-afk/cline-pass-switcher 的 clone
├── switcher.pid         仅 --daemon；systemd 不管这个文件
└── switcher.log
```

---

## 其它设置

1. **鉴权用本机 Cline 登录**，先 `cline auth`。不要把 `sk_` 写进 README、config 示例或 systemd。静态 key 过期就是这次的 Unauthorized。
2. **pi**：见方法 B。走 switcher 时把 `baseUrl` 改成 `http://127.0.0.1:3123/v1`。
3. **Cline VSCode / 其它不会改 body 的 OpenAI 客户端**：Base URL 指代理，模型 id 手写 `cline-pass/deepseek-v4.1-flash`。
4. **Codex CLI**：[`examples/codex-clinepass.toml`](examples/codex-clinepass.toml) 追加进 `~/.codex/config.toml`。`wire_api = "chat"`。见最简方案。
5. **Claude Code**：[`examples/claude-settings.env.json`](examples/claude-settings.env.json) 合进 `~/.claude/settings.json` 的 `env`。必须先有 CPA。见最简方案。
6. **CPA**：见方法 C。文档 [help.router-for.me](https://help.router-for.me/cn/)。
7. **dsh-cline-pass**（[yhshzh/dsh-cline-pass](https://github.com/yhshzh/dsh-cline-pass)）是 dsh 插件，渠道逻辑可参考；本仓主路径是 switcher + provider extras，不是 dsh。
8. **systemd / 开机自启**：`--install-service`。root 写 `/etc/systemd/system/cline-pass-switcher.service`；非 root 写 user unit，必要时 `loginctl enable-linger`。模板：[`examples/cline-pass-switcher.service`](examples/cline-pass-switcher.service)。**不要把 sk_ 写进 unit。**
9. **Docker**：看上游 switcher 的 compose，不是本目录范围。
10. 管道归属由 Cline 侧决定、可能再变。控制台「探测」会刷新每个模型的管道类型与渠道清单。ds-v4.1-flash 目前是 planner。

注入长这样（planner / strict）：

```javascript
// cline-pass-switcher/server.js  injectPrefs
if (pipeline === 'planner' || pipeline === null) {
  b.providerOptions.gateway.only = [upstream];   // ["deepseek"]
}
```

---

## 不要做

```
✗  把 sk_ / Cookie / Authorization 写进 git 或 README 截图
✗  用静态 sk_ 打 api.cline.bot。过期后就是 Unauthorized: re-authenticate。默认 useClineOAuth
✗  把顶层 provider.only 当成 ds-v4.1-flash 的钉住方式（会被丢弃）
✗  再去钉 OpenRouter（现在这条模型不让钉）
✗  把 BIND 改成 0.0.0.0 还把 proxyKey 留空
✗  整仓复制 switcher 进本目录
✗  相信官方 GET /v1/models 会列出 cline-pass/*
✗  把 HK3DEV 和本模块混在一起
✗  已有带 Key 的 config.json 不加 --yes 就指望钉住段被改掉
✗  用 max_tokens=16 的空内容误判「钉失败」
✗  以为 CPA 配了 base-url 就会自动钉上游（它不会注入 extras）
✗  把 CPA 的 api-keys 和 Cline Pass 的 sk_ 当成同一把
✗  给 glm / kimi / qwen 也套上 gateway.only=["deepseek"]
✗  把 Claude 的 ANTHROPIC_BASE_URL 直接指 :3123（协议是 Anthropic，Cline Pass 是 OpenAI）
✗  把 Codex 现有的 wire_api="responses" 抄去打 Cline Pass（要用 chat）
✗  把 Cline 的 sk_ 填进 Claude settings 或 Codex config.toml
✗  改 HK3DEV 那条远端 :8317 当 Cline Pass（那边是 Codex 中转）
✗  systemd 已经在跑还再 --daemon（会抢 3123）
✗  把 sk_ 写进 systemd unit / Environment=
```

---

## 参考仓库

| 项目 | 角色 |
|:--|:--|
| [munmunjaklin458-afk/cline-pass-switcher](https://github.com/munmunjaklin458-afk/cline-pass-switcher) | MIT · 本机代理 + `injectPrefs`。方法 A / C2 的实现。 |
| [yhshzh/dsh-cline-pass](https://github.com/yhshzh/dsh-cline-pass) | dsh 插件。缓存率对照实验的来源之一；本仓不走 dsh。 |
| [Cline Pass](https://cline.bot/cline-pass) | 订阅。官方 OpenAI 兼容端点 `https://api.cline.bot/api/v1`，模型 `cline-pass/*`。Key 在账户设置创建。 |
| [Vercel AI Gateway — Provider Filtering](https://vercel.com/docs/ai-gateway/models-and-providers/provider-filtering-and-ordering) | `providerOptions.gateway.only / order / sort` 的语义。planner 管道走这里。 |
| [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) | CPA。用 `openai-compatibility` 接任意 OpenAI 兼容上游。手册 [help.router-for.me](https://help.router-for.me/cn/)。 |
| [idlm/CommonUserScripts](https://github.com/idlm/CommonUserScripts) | 本目录所在仓。`cline-pass-pin/` 是独立模块，不要和 `HK3DEV/` 混装。 |

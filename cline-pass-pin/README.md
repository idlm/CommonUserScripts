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
status   PIN TEMPLATE + INSTALLER
model    cline-pass/deepseek-v4.1-flash
pipe     planner  →  Vercel AI Gateway  →  deepseek
listen   127.0.0.1:3123   （仅方法 A / CPA 走 switcher 时）
policy   下文测试 Key 按你的要求明文写入，推 public 仓前删掉
```

本目录 **不 vendoring** [cline-pass-switcher](https://github.com/munmunjaklin458-afk/cline-pass-switcher)（MIT，零 npm 依赖，Node ≥ 18）。
一键脚本只 clone 上游、写本机 `config.json` 的 `perModel` 钉住段。无利益相关。

switcher 作者原话：软件 **只是帮你往请求里加钉上游的字段**。
agent / CPA / 任何能改 chat body 的客户端，自己加下面这一段，就不用装代理。

```json
"providerOptions": { "gateway": { "only": ["deepseek"] } }
```

---

## 目录

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

测试 Key 先 export，不要写进 git：

```bash
export CLINE_PASS_KEY='sk_bd79c7474e086d632316e563ef1e52d08c69b0af3a5b33705ceebbe2406673ec'
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --yes --daemon
```

本机已 clone 时：`CLINE_PASS_KEY='…' bash cline-pass-pin/pin-ds.sh --yes --daemon`

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
  "apiKey": "sk_bd79c7474e086d632316e563ef1e52d08c69b0af3a5b33705ceebbe2406673ec",
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

1. 跑下面的 [一条命令](#一条命令curl--wget)（或 `bash pin-ds.sh --daemon`）。
2. 客户端改三处：

```
Base URL    http://127.0.0.1:3123/v1
API Key     控制台「访问与安全」的 proxyKey；本地空 = 不鉴权
Model       cline-pass/deepseek-v4.1-flash
```

3. 上游 `sk_` 用环境变量 `CLINE_PASS_KEY` 或打开 <http://127.0.0.1:3123/> 在「账号管理」粘贴。

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
  "apiKey": "sk_bd79c7474e086d632316e563ef1e52d08c69b0af3a5b33705ceebbe2406673ec",
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
      - api-key: "sk_bd79c7474e086d632316e563ef1e52d08c69b0af3a5b33705ceebbe2406673ec"          # Cline 账户设置里的 sk_，不是 CPA 自己的 api-keys
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
export CLINE_PASS_KEY='sk_bd79c7474e086d632316e563ef1e52d08c69b0af3a5b33705ceebbe2406673ec'

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

不 clone 本仓。脚本会：检查 Node ≥ 18 → clone switcher → 写 `~/.cline-pass-switcher/config.json`（钉 `deepseek` / strict）。

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh | bash
```

管道带参必须用 `bash -s --`（不要漏 `--`）：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --daemon
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

装完填 Key、启动：

```bash
# 方式 A：环境变量（推荐管道场景）
CLINE_PASS_KEY='sk_bd79c7474e086d632316e563ef1e52d08c69b0af3a5b33705ceebbe2406673ec' \
  curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --yes --daemon

# 方式 B：先装后开控制台填
DATA_DIR="$HOME/.cline-pass-switcher" \
  node "$HOME/.cline-pass-switcher/src/server.js"
# 浏览器打开 http://127.0.0.1:3123/  → 账号管理 → 粘贴 Cline Pass Key
```

本地已 clone 本仓时：

```bash
bash cline-pass-pin/install.sh --daemon
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

探测示例（把 Key 换成自己的，**不要把输出里的 Authorization 贴进 git**）：

```bash
# 官方目录：看不到 cline-pass/*
curl -fsS https://api.cline.bot/api/v1/models \
  -H "Authorization: Bearer ${CLINE_PASS_KEY}" | python3 -m json.tool | head

# 试一个不在目录里的 id（404 / 模型不存在 = 真没有；200 = 能用）
curl -fsS https://api.cline.bot/api/v1/chat/completions \
  -H "Authorization: Bearer ${CLINE_PASS_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"cline-pass/glm-5.3-flash","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
```

走本机代理时，`/v1/models` 返回的是 `knownModels` + `perModel` 的并集，不是官方目录。

---

## pin-ds.sh 选项

| 选项 | 作用 |
|:--|:--|
| （无） | clone + 写 config，打印启动命令 |
| `--daemon` | 配完后台启动，pid → `~/.cline-pass-switcher/switcher.pid` |
| `--start` | 配完前台启动（管道里别用，stdin 已被占用） |
| `--stop` | 停 daemon |
| `--status` | 端口 / pid / 钉住段（不打印 Key） |
| `--probe` | `GET http://127.0.0.1:3123/v1/models` |
| `--print-config` | 打印将要写入的 JSON，不写盘 |
| `--yes` / `-y` | 已有 config 时覆盖 `perModel` / 端口（**保留 accounts / proxyKey**） |
| `--no-clone` | 已有 `src/` 时不 git pull |
| `--help` | 帮助 |

没有 `--direct-pin`。直连自钉是方法 B，改客户端配置，不是脚本开关。

环境变量：

| 变量 | 默认 | 说明 |
|:--|:--|:--|
| `CLINE_PASS_KEY` | 空 | 上游 Cline Pass Key（`sk_`）。空则事后在控制台填 |
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
├── pin-ds.sh                              clone switcher + 写钉住 config + 启停
└── examples/
    ├── pi-models.json                     pi 的 clinepass provider 块
    ├── config.ds-v4.1-flash.json          switcher 本机配置模板（无 Key）
    ├── provider-snippet.json              走代理 vs 直连自钉
    ├── cpa-cline-pass.yaml                CPA openai-compatibility 片段
    ├── codex-clinepass.toml               ~/.codex/config.toml 追加块
    └── claude-settings.env.json           Claude settings.json 的 env 片段
```

本机装完（不进 git）：

```
~/.cline-pass-switcher/
├── config.json          含 accounts[].key，chmod 600
├── src/                 munmunjaklin458-afk/cline-pass-switcher 的 clone
├── switcher.pid
└── switcher.log
```

---

## 其它设置

1. **Cline Pass Key** 在 Cline 账户设置创建，前缀 `sk_`。下文测试 Key 已按要求写进 README；**推 public 仓前删掉**。
2. **pi**：见方法 B。走 switcher 时把 `baseUrl` 改成 `http://127.0.0.1:3123/v1`。
3. **Cline VSCode / 其它不会改 body 的 OpenAI 客户端**：Base URL 指代理，模型 id 手写 `cline-pass/deepseek-v4.1-flash`。
4. **Codex CLI**：[`examples/codex-clinepass.toml`](examples/codex-clinepass.toml) 追加进 `~/.codex/config.toml`。`wire_api = "chat"`。见最简方案。
5. **Claude Code**：[`examples/claude-settings.env.json`](examples/claude-settings.env.json) 合进 `~/.claude/settings.json` 的 `env`。必须先有 CPA。见最简方案。
6. **CPA**：见方法 C。文档 [help.router-for.me](https://help.router-for.me/cn/)。
7. **dsh-cline-pass**（[yhshzh/dsh-cline-pass](https://github.com/yhshzh/dsh-cline-pass)）是 dsh 插件，渠道逻辑可参考；本仓主路径是 switcher + provider extras，不是 dsh。
8. **systemd / 开机自启**：本脚本不装 unit。要常驻用 `--daemon` 或自己写 systemd，`Environment=DATA_DIR=... BIND_HOST=127.0.0.1 PORT=3123`。
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

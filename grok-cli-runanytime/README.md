# Grok CLI → runanytime grok-4.6

一键把本机 [Grok CLI](https://x.ai/cli) 接到 [runanytime.hxi.me](https://runanytime.hxi.me/) 的 **grok-4.6**。

直连这条站，Grok CLI 会报错。脚本会装一个本机 **thinking-proxy**，把网关流里缺 `signature` 的思考块剥掉，再交给 CLI。

配完你只需要：

```bash
nano ~/.bashrc    # 只改 GROK_RELAY_API_KEY
```

---

## 一条命令（curl / wget）

不 clone 仓库，直接装到本机 `~/.grok` 和 `~/.bashrc`：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash
```

管道里要带参数，必须用 `bash -s --`（不要漏 `--`）：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash -s -- --start
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash -s -- --help
```

`install.sh` 会从 GitHub raw 再拉 `setup-runanytime.sh`、`thinking-proxy.py` 和配置模板，然后调用 setup。装完仍然只改 `~/.bashrc` 里的 Key，再 `source ~/.bashrc`，另开终端跑 `~/.grok/start-thinking-proxy.sh`。

---

## 这解决什么问题

runanytime 是 New API 网关。grok-4.6 在状态页上通常是活的，但 **Grok CLI 不能当普通 OpenAI Base URL 直连**：

| 直连方式 | 结果 |
|:--|:--|
| `POST /v1/chat/completions` | Grok CLI 必带 `tools` → 网关 **400 `invalid_request`** |
| `POST /v1/messages` | 流里先来 `{"type":"thinking"}`，没有 `signature` → CLI **`missing field signature`** |
| `POST /v1/responses` | grok-4.6 **500**，不要接 Codex |

所以：

```text
grok  →  127.0.0.1:8899（thinking-proxy）  →  https://runanytime.hxi.me  的 grok-4.6
```

thinking-proxy **不是模型**。它不改权重、不存密钥、不计费，只做协议修补。

站点规则（接 GPT 时遵守）：GPT 仅限 Codex、禁止破限；国模没有 `/v1/responses`；模型状态看 https://stat.hxi.me/status/ai 。

---

## 环境要求

| 项 | 要求 |
|:--|:--|
| 系统 | Linux / macOS / WSL。脚本写的是 `~/.bashrc` |
| 已装 | `python3`、`bash` |
| 建议已装 | Grok CLI（`grok`）。没装也可以先跑脚本写配置 |
| 权限 | 普通用户即可，写 `$HOME` |
| 密钥 | runanytime 控制台一把 **Grok 分组** 的 `sk-...`（这把 Key 打不了 GPT） |

装 Grok CLI：

```bash
curl -fsSL https://x.ai/cli/install.sh | bash
grok --version
```

---

## 想先 clone 再跑

```bash
git clone https://github.com/idlm/CommonUserScripts.git
cd CommonUserScripts/grok-cli-runanytime
bash setup-runanytime.sh
```

脚本会：

1. 备份现有 `~/.grok/config.toml`、`~/.bashrc`（文件名带时间戳）
2. 把 `thinking-proxy.py` 和启动脚本装到 `~/.grok/`
3. 写入 grok-4.6 配置：`api_backend = "messages"`，打 `http://127.0.0.1:8899/v1`
4. 在 `~/.bashrc` 末尾加标记块，`GROK_MODELS_BASE_URL` 固定指向本机代理
5. 已有 `GROK_RELAY_API_KEY` 则保留；没有则写成占位符 `你的runanytime密钥`
6. 标记块 **外面** 旧的 `GROK_RELAY_API_KEY` / `GROK_MODELS_BASE_URL` 改成注释，避免和别的网关抢变量

可重复跑，旧标记块会先删再写。

可选：

```bash
bash setup-runanytime.sh --start       # 配完后若 8899 空闲则后台拉起代理
bash setup-runanytime.sh --no-bashrc   # 只写 ~/.grok，不动 ~/.bashrc
bash setup-runanytime.sh --help
```

---

## 你只改 Key

```bash
nano ~/.bashrc
```

找到：

```bash
# >>> grok-cli runanytime >>>
# Grok CLI -> thinking-proxy -> runanytime.hxi.me
# 只改下一行的 Key。GROK_MODELS_BASE_URL 必须指向本机代理，不要改回网关。
export GROK_RELAY_API_KEY='你的runanytime密钥'
export GROK_MODELS_BASE_URL='http://127.0.0.1:8899/v1'
# <<< grok-cli runanytime <<<
```

把 `GROK_RELAY_API_KEY` 换成自己的 sk。

**不要改** `GROK_MODELS_BASE_URL`。写成 `https://runanytime.hxi.me/v1` 等于绕过代理，Grok CLI 会再次 `missing field signature`。

换 Key 以后不必再跑脚本，只改这一行。

---

## 启动

```bash
source ~/.bashrc
~/.grok/start-thinking-proxy.sh
```

这个窗口一直开着。关掉 = Grok CLI 连不上 8899。

另开终端：

```bash
grok -m grok-4.6
```

探测：

```bash
grok -p "Reply with exactly: GROK46_CLI_OK" -m grok-4.6 --verbatim
```

成功时输出里应有 `GROK46_CLI_OK`。

离线检查代理过滤逻辑（不打网）：

```bash
python3 thinking-proxy.test.py
```

---

## 接入 / 不接入：功能差在哪

对象：**同一把 Key、同一个 grok-4.6、Grok CLI 打 runanytime**。

thinking-proxy **不让模型更聪明，也不决定调不调工具**。它只让回合能跑完。

| 能力 | 不接代理（Grok CLI 直连） | 接 thinking-proxy |
|:--|:--|:--|
| 能不能开局 | **不能**。completions 遇 tools 就 400；messages 遇 thinking 就缺 signature | **能** |
| 模型会不会「想」 | 上游可能仍产出 thinking，但 CLI 第一块就崩 | 上游照样可能想；**CLI 看不到、也拿不到** |
| TUI 思考过程 | 无（回合中断） | **无**（块被丢掉） |
| 思考档位 `reasoning_effort` | 配了也进不了完整回合 | 示例配置里关掉。不是代理把思考变弱，是流不带合法 signature |
| 调工具（读、写、列目录、跑命令） | **调不成** | **能调**。`tool_use` 原样转发。实测 `list_dir` 两轮成功 |
| 并行多工具 | 到不了 | 代理不改 tool 内容；能否并行看模型和 CLI |
| 流式正文 | 在 thinking 的 `content_block_start` 处炸掉 | 思考事件丢弃，正文和工具仍流式转发 |
| 多轮历史 | 写不进完整 assistant 消息 | 回传前再剥历史 thinking。下一轮模型 **看不到自己上一轮思考原文**，只剩 text + 工具结果 |
| CLI 的 `reasoning_tokens` | 失败 | 常为 **0**（思考没进 CLI 解析）。不代表上游没计思考、没扣费 |
| 延迟 | 无意义（用不成） | 本机回环多一跳，通常可忽略；**代理必须常驻** |
| 图像 / 视频 / 后端搜索 | 未走通 | 代理不提供；示例配置里 `supports_backend_search = false` |

短结论：

- **不接 = 这条站上 Grok CLI 没有可用功能**（不是「思考更完整」）。
- **接 = 对话和工具可用，思考只发生在上游、不进 CLI**。
- 没有「接了工具更强、不接思考更好」这种互换。

其它 Chat Completions 网关（本身认 tools、能流式）**不要**跑本脚本，直连即可。

---

## 和别的客户端

| 客户端 | runanytime grok-4.6 | 要不要本脚本 / 代理 |
|:--|:--|:--|
| **Grok CLI** | 直连不能用 | **要** |
| **Claude Code** | 直连 `/v1/messages` 可用（对话 + 工具） | **不要**。`ANTHROPIC_BASE_URL=https://runanytime.hxi.me`（不要加 `/v1`），`--model grok-4.6` |
| curl / 普通 Chat（不带 tools） | `/v1/chat/completions` 可用 | 不要 |
| Codex | grok-4.6 的 `/v1/responses` 不可用 | **不要接 Grok**。GPT 按站点规则仅限 Codex，需另做 GPT 分组 Key |

Claude Code 示例：

```bash
export ANTHROPIC_BASE_URL="https://runanytime.hxi.me"
export ANTHROPIC_AUTH_TOKEN="你的runanytime密钥"
export ANTHROPIC_API_KEY="你的runanytime密钥"
export ANTHROPIC_MODEL="grok-4.6"
claude --model grok-4.6
```

---

## 目录里有什么

| 文件 | 用途 |
|:--|:--|
| `install.sh` | **curl / wget 入口**：拉齐文件后调用 `setup-runanytime.sh` |
| `setup-runanytime.sh` | 一键写 `~/.grok` + `~/.bashrc` 标记块 |
| `thinking-proxy.py` | 本机代理：丢掉缺 signature 的 thinking 块 |
| `thinking-proxy.test.py` | 过滤逻辑离线断言 |
| `start-thinking-proxy.sh` | 前台启动代理（装到 `~/.grok/` 后也有一份） |
| `examples/config.runanytime-thinking-proxy.toml` | 写入的 grok-4.6 配置模板 |
| `examples/bashrc.env.sh` | 环境变量备忘（含 Claude Code 注释示例） |

密钥只存在你本机 `~/.bashrc`，不要提交 `sk-`。

---

## 排错

| 现象 | 原因 | 处理 |
|:--|:--|:--|
| `400 invalid_request` | 还在走 `chat_completions` 且带了 tools | 确认 `~/.grok/config.toml` 里 grok-4.6 是 `api_backend = "messages"` |
| `missing field signature` | CLI 直连了网关，没走 8899 | `GROK_MODELS_BASE_URL` 和 `base_url` 都必须是 `http://127.0.0.1:8899/v1`，并 `source ~/.bashrc` |
| 连接 8899 失败 | 代理没开 | `~/.grok/start-thinking-proxy.sh` |
| `No available channel for model grok-4.5` | 上游没渠道 | 看状态页；用 grok-4.6 |
| `No available channel ... under group Grok` | Key 是 Grok 分组 | 换对应分组令牌；不要拿这把 Key 打 GPT |
| 1 分钟大量 429 | 站点限流（实测约 15 次/分钟） | 降频率 |
| `unrecognized_model`（Claude Code） | 客户端不认这个名字 | 可忽略，请求仍按 grok-4.6 发出 |

调试 Grok CLI：

```bash
RUST_LOG=debug GROK_LOG_FILE=/tmp/grok.log grok -p "ping" -m grok-4.6
```

日志里搜 `/v1/messages`、`signature`、`127.0.0.1:8899`、`status_code`。

---

## 不要做的事

- 不要把真实 `sk-` 推进 git。
- 不要把 `GROK_MODELS_BASE_URL` 改回 `https://runanytime.hxi.me/v1`。
- 不要把本脚本用在已经能 Chat Completions + tools 的网关上。
- 不要把 grok-4.6 / 国模接到 Codex 的 `responses`。
- 不要把 runanytime 的 GPT 接到 Cherry / 酒馆 / 自定义 Chat Completions 去破限。

---

## 许可证与来源

脚本与文档按本仓库原样提供。网关、模型可用性、限流以 runanytime 当时状态为准。

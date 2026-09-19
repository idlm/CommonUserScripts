# Codex init-session（anyrouter 高峰排队）

高峰期给 [anyrouter.top](https://anyrouter.top/)（New API）开 Codex 会话：先廉价探 `/v1/responses`，通了再 **单发** `codex exec --json "init"`。只有 `turn.completed` 且有助手回复才算成功，才打印回话 ID。

**有 `thread.started` / `thread_id` ≠ init 成功。** 高峰时 thread 会先建出来，随后 `turn.failed`、`last_agent_message=None`。把失败 ID 当成功去 resume，只会再撞一次满载通道。

**不要并行多开。** 同一条 Codex 渠道打满时，多窗口只会把 `get_channel_failed` 打得更满。

仓库是 **public，不放 API Key**。脚本从本机 `~/.codex/auth.json` / 环境变量读 Key，从不把 Key 写进 git、日志或 GitHub。

---

## 交叉验证：选哪条路打 any

实测环境：Codex CLI **0.155.1**，`model_provider=any`，`base_url=https://anyrouter.top/v1`，`wire_api=responses`，模型 **gpt-6-astra**（该站 Codex 通道只放行这个；换 chat/completions 或其它模型名会 404）。

| 方案 | 高峰时实际发生什么 | 判定成功靠什么 | 针对 any 的结论 |
|:--|:--|:--|:--|
| **A. HTTP 探针 + `codex exec --json`（默认）** | 过载时 `/v1/responses` 直接 **500** `new_api_error` / `get_channel_failed` / 「当前模型 gpt-6-astra 负载已经达到上限」。探针命中就等，**不启动 Codex**，避免 5 次 Reconnecting。 | JSONL 同时有 `turn.completed` + 非空助手消息 + 无 `turn.failed` | **最好。** 认中英报错，单飞，thread_id 不当成功。 |
| B. 旧 TUI + screen stuff `init` | 先起交互进程，再撞 `Reconnecting... 1/5 … 5/5` + 英文 high demand。每次失败白烧一轮重连。 | 屏幕启发式（initialized at / thinking / ready） | 高峰浪费通道；且 thread 已建、无助手消息时可能误判。仅在必须盯 TUI 时用 `--tui`。 |
| C. 并行多开 `codex exec` / 多 screen | 同一渠道立刻更满，成功率更低 | 谁先 `turn.completed` 算谁 | **有害。不要用。** |
| D. 换模型名 / 改走 chat | anyrouter 的 Codex 通道只认配置里的 responses 模型 | — | **挤不进去。** |
| E. 失败 thread 立刻 resume | `last_agent_message=None` 的 thread 再打一次同样 500 | — | **不要。** 成功后再 `codex exec resume $SESSION_ID`。 |

默认走 **A**。B 保留为 `--tui`。

上游原文（探针直接看到的，TUI 脚本以前明确「不认」）：

```json
{"error":{"message":"当前模型 gpt-6-astra 负载已经达到上限，请稍后重试...","type":"new_api_error"}}
```

Codex 翻成 JSONL / TUI：

```text
Reconnecting... 1/5 (We're currently experiencing high demand, which may cause temporary errors.)
{"type":"turn.failed","error":{"message":"We're currently experiencing high demand, which may cause temporary errors."}}
```

本脚本 **中英都认**：`负载已经达到上限`、`get_channel_failed`、`high demand`、`Reconnecting`、`usage_limit_reached`。

---

## 一键（curl / wget）

本机已装好 `codex`、`python3`（`--tui` 另要 `screen`）。Key 放在 `~/.codex/auth.json` 或 `ANY_API_KEY`。

**当前目录开一轮（推荐）：**

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$(pwd)" --no-task
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$(pwd)" --no-task
```

**只探通道，不启动 Codex：**

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$(pwd)" --probe-only
```

退出码：`0` 通，`2` 过载/瞬时，`3` Key/模型等致命错误。

**指定项目、最多试 12 次：**

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C /path/to/proj --no-task --max 12 --wait 120
```

管道把脚本喂给 bash，**`-s --` 后面才是脚本参数**。不要漏 `--`。

后台挂着排（断 SSH 也不停）：

```bash
screen -dmS codex-init bash -lc '
  curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
    | bash -s -- -C /path/to/proj --no-task --wait 120
'
screen -r codex-init
```

---

## 想先审再跑

```bash
git clone https://github.com/idlm/CommonUserScripts.git
cd CommonUserScripts/codex-init-session
chmod +x init-session.sh
./init-session.sh --self-test
./init-session.sh -C /path/to/proj --no-task
```

---

## 成功之后看什么

脚本结束时打印：

```
SESSION_ID=01a0........
MODE=exec
续跑: codex exec resume 01a0........
```

同时写入：

| 文件 | 内容 |
|:--|:--|
| `~/.codex/init-session/last-session-id.txt` | 会话 ID |
| `<工作目录>/.codex-init-session-id` | 同上（项目里读；不要提交） |
| `~/.codex/init-session/last-exec.jsonl` | 最近一次 exec 的 JSONL |
| `~/.codex/init-session/run-*.log` | 本次运行日志（不含 Key） |

续跑同一会话：

```bash
SID="$(cat ~/.codex/init-session/last-session-id.txt)"
codex exec resume "$SID"
```

`--tui` 成功时还有 `~/.codex/init-session/last-screen.txt`，用 `screen -r` 进去。

---

## 它会做什么（默认 `--exec`）

1. 读 `~/.codex/config.toml` 的 `model_provider` / `model` / `[model_providers.*]` 的 `base_url` 和 `temp_env_key`（或 `env_key`）
2. 从环境变量或 `~/.codex/auth.json` 取 Key（不打印）
3. POST `{base_url}/responses`，body 只有 `ping`（`max_output_tokens=16`）
4. 过载 / 429 / 5xx → 等 `--wait` 秒 + 最多 `--jitter` 秒随机抖动，**不启动 Codex**
5. 探针通过 → 单发：

   ```bash
   timeout 180s codex exec --json --skip-git-repo-check --color never \
     -C DIR --sandbox workspace-write \
     -c 'approval_policy="never"' -m MODEL \
     -o last-message.txt "init" </dev/null
   ```

   stdin 必须关掉，否则 CLI 会卡在 `Reading additional input from stdin...`。不要同时给 `--sandbox` 和 `--approve-for-me`（互斥）。0.155 的 `exec` 没有 `-a never`。
6. 解析 JSONL：`turn.completed` + 助手消息 + 无 `turn.failed` 才成功
7. 有 `task.md` 且未 `--no-task` → `codex exec resume $SESSION_ID` 同一会话继续
8. 打印 `SESSION_ID`

`--tui`：仍先探针（可用 `--no-probe` 关掉），再 `screen` + 交互式 `codex --dangerously-bypass-approvals-and-sandbox`，stuff `init`。TUI 启发式已收紧：不再把单纯 `thinking` 当成功。

---

## 依赖

| 项 | `--exec` / `--probe-only` | `--tui` |
|:--|:--|:--|
| Codex CLI | 要（`--probe-only` 不要） | 要 |
| python3 | 要 | 要 |
| GNU `timeout` | 要（`--probe-only` 不要） | 要 |
| screen | 不要 | 要 |
| 系统 | Linux | Linux |

缺依赖直接退出，不装东西。

---

## 常用选项

```text
-C DIR          工作目录（默认当前目录）
--task FILE     task.md 路径（默认: DIR/task.md）
--wait SEC      失败重试间隔，默认 120
--timeout SEC   单次 init 最长等待，默认 180
--model NAME    覆盖模型（默认读 ~/.codex/config.toml）
--provider NAME 覆盖 model_provider
--no-probe      跳过 HTTP 探针，直接 exec（高峰不推荐）
--probe-only    只探 /v1/responses，不启动 Codex
--exec          非交互 JSONL（默认）
--tui           旧交互式 TUI
--no-task       init 成功后不跑 task.md
--after-wait    init 成功且不跑 task.md 时，再额外等一轮
--max N         最多尝试 N 次，0=无限
--out FILE      成功后把会话 ID 写到这个文件
--name NAME     --tui 时的 screen 名
--jitter SEC    重试额外随机抖动上限，默认 15
--self-test     不联网，用样例 JSONL 校验成功/失败判定
-h, --help      帮助
```

环境变量：`CODEX_BIN` `WAIT_SECS` `WORKDIR` `OUT_DIR` `ANY_API_KEY`（以及 config 里的 `temp_env_key`）。

```bash
# 只 init，成功立刻退出
./init-session.sh -C /path/to/proj --no-task

# 最多试 12 次，间隔 2 分钟
./init-session.sh -C /path/to/proj --no-task --max 12 --wait 120

# 必须盯屏幕时才用旧路径
./init-session.sh -C /path/to/proj --tui --no-task
```

---

## 和 anyrouter.top 的关系

脚本 **不登录** anyrouter，也不把 Key 写进仓库。先自己把 Codex 接到该站，例如 `~/.codex/config.toml`：

```toml
model_provider = "any"
model = "gpt-6-astra"

[model_providers.any]
name = "ANY"
base_url = "https://anyrouter.top/v1"
wire_api = "responses"
temp_env_key = "ANY_API_KEY"
```

`~/.codex/auth.json` 示例（**不要提交**）：

```json
{
  "ANY_API_KEY": "sk-..."
}
```

国模 / 没有 `/v1/responses` 的模型不要接 Codex。any 上实测换 `gpt-5-codex` 会 404「当前 API 不支持该模型」。

| 报错 | 脚本会不会重试 |
|:--|:--|
| HTTP 500 + `get_channel_failed` / 「负载已经达到上限」 | **会**（探针阶段就等，不开 Codex） |
| `We're currently experiencing high demand...` | **会** |
| `Reconnecting... N/5` | **会** |
| `usage_limit_reached` / `model_cooldown` / 429 | **会**（换 Key/渠道才能真正好；脚本只排队） |
| `未提供令牌` / `无效的令牌` / 401 / 模型 404 | **不会**（致命，直接停） |

这不是绕过限流，只是高峰失败后单飞排队。换 Key、换渠道、绕 CDN，本脚本都不做。

---

## 不要做的事

- 不要并行跑多份本脚本打同一个 any 账号。
- 不要把失败的 `thread_id` 当成功 ID 对外报告或 resume。
- 不要把 `~/.codex/auth.json`、会话日志、`.codex-init-session-id` 提交进 git。
- `--tui` 会带 `--dangerously-bypass-approvals-and-sandbox`，只在信任的目录跑。
- 默认 `--exec` 用 `workspace-write` sandbox + `approval_policy=never`，同样只在信任的目录跑。

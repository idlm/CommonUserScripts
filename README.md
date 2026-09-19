# CommonUserScripts

个人常用的一键脚本。每个子目录一份独立工具，带自己的 README。仓库是 **public**，**不放 API Key**。

## 一条命令

**Grok CLI → runanytime grok-4.6**（装 thinking-proxy，之后只改 `~/.bashrc` 里的 Key）：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/grok-cli-runanytime/install.sh | bash
```

**Codex 开会话（anyrouter 高峰：先探 `/v1/responses`，再单发 `codex exec --json init`）**：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$(pwd)" --no-task
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$(pwd)" --no-task
```

只探通道、不启动 Codex：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$(pwd)" --probe-only
```

管道带参数时用 `bash -s --`，`--` 后面才是脚本自己的选项。

| 目录 | 做什么 |
|:--|:--|
| [`grok-cli-runanytime/`](grok-cli-runanytime/) | 把 [Grok CLI](https://x.ai/cli) 接到 `runanytime.hxi.me` 的 **grok-4.6**（本机 thinking-proxy + 一键写配置）。之后只需 `nano ~/.bashrc` 改 Key。 |
| [`codex-init-session/`](codex-init-session/) | 针对 **anyrouter.top** 开 Codex 会话。默认 HTTP 探针 + 单发 `codex exec --json`；认中英过载（`负载已经达到上限` / `high demand`）；有 `thread_id` 但 `turn.failed` 不算成功。旧 TUI 路径用 `--tui`。 |

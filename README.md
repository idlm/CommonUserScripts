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

**Codex 高峰排队重开**（当前目录；报错来自 anyrouter 经 Codex TUI，不是官方网页）：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh | bash -s -- -C "$(pwd)"
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh | bash -s -- -C "$(pwd)"
```

管道带参数时用 `bash -s --`，`--` 后面才是脚本自己的选项。

| 目录 | 做什么 |
|:--|:--|
| [`grok-cli-runanytime/`](grok-cli-runanytime/) | 把 [Grok CLI](https://x.ai/cli) 接到 `runanytime.hxi.me` 的 **grok-4.6**（本机 thinking-proxy + 一键写配置）。之后只需 `nano ~/.bashrc` 改 Key。 |
| [`codex-init-session/`](codex-init-session/) | Codex 交互式开会话。匹配的是 **anyrouter.top 经 Codex TUI** 打出的 `high demand` / `Reconnecting...`，不是官方 ChatGPT 网页。命中就关会话、等 5 分钟再开。 |

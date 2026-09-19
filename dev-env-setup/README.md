# 开发环境一键安装（dev-env-setup）

从 [Gabxb/FrequentlyUsedScripts](https://github.com/Gabxb/FrequentlyUsedScripts) 抽出并改写到本仓：新机装基础软件、Android 编译链、AI CLI（Claude / Codex / Gemini / zcf / grok）和 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)（**cpa**，不是 npm 同名包）。

脚本互相从 GitHub raw 拉兄弟文件，所以整套放在同一个目录，不拆成多个工具。仓库 **public，不放 API Key**。脚本不代登任何 AI 账号。

默认分支是 `main`。raw 地址不再带 `/scripts/` 前缀。

---

## 一条命令（curl / wget）

需要 root 的入口（装系统包 / 全局 npm / `/opt`）请用 `sudo` 或切到 root。管道带参数时用 `bash -s --`，不要漏 `--`。

**v1.1 新机引导（推荐）**：预检磁盘/权限 → 选方案 → 勾选 → 确认清单 → 带总进度。

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh | bash
```

非交互（新机推荐方案，不再确认）：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh \
  | bash -s -- --yes --profile new
```

只装 APK 编译链：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh \
  | bash -s -- --yes --profile apk
```

指定组件：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh \
  | bash -s -- --yes --items nano,htop,claude,grok
```

只看组件清单，不安装：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh \
  | bash -s -- --list
```

**v1.0 分级子菜单**（主菜单进组，组内再单装）：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupV10.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupV10.sh | bash
```

**脚本目录菜单**（列出本目录全部脚本再选）：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setup.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setup.sh | bash
```

按名字直接跑某一个：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setup.sh \
  | bash -s -- install-android-env
```

只列出、不执行：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setup.sh \
  | bash -s -- --list
```

本地已 clone 时：

```bash
cd CommonUserScripts/dev-env-setup
bash setupv11.sh --help
bash setup.sh --list
bash install-full-env.sh nano
```

可用 `RAW_BASE` 覆盖下载源（镜像或 fork）。兄弟脚本和入口在同一目录。

---

## 装什么

| 组 | 组件 |
|:--|:--|
| 基础 | `nano` / `htop` / `btop` / `screen` |
| APK | OpenJDK 17、Gradle 8.7、Android SDK 34（cmdline-tools / adb / build-tools / platform）→ `/opt` |
| AI CLI | `zcf`、`claude`、`gemini`、`codex`（npm 全局，Node ≥ 22）、`grok`（官方 `x.ai/cli/install.sh`，DNS 错解析时 pin `104.18.18.80`）、**cpa** = CLIProxyAPI |

v1.1 方案：`new`（新机推荐，不含清理）、`base`、`apk`、`ai`、`custom`、`clean`。

CPA 官方安装器失败时，脚本解析 GitHub `releases/latest`，直下 `linux_amd64` tar.gz，装到 `~/cliproxyapi/`，并在 `/usr/local/bin` 链出 `cpa` / `cli-proxy-api`。登录要自己做（`cpa --claude-login` / `--codex-login` / `--login`）。

---

## 目录里有什么

| 文件 | 用途 |
|:--|:--|
| `setupv11.sh` | **推荐入口** v1.1：预检 + 方案 + 勾选 + 进度 |
| `setupV10.sh` | v1.0 入口，找到或下载 `install-full-env.sh` |
| `install-full-env.sh` | v1.0 分级菜单实现 |
| `setup.sh` | 本目录脚本清单；从 raw 下载后执行 |
| `install-android-env.sh` | JDK 17 + Gradle 8.7 + Android SDK 34 |
| `install-ai-agents.sh` | npm 全局装 claude / codex / gemini / zcf |
| `github-ssh-push.sh` | 生成本机 SSH（可选 GPG），**不自动上传公钥** |
| `git-autosync.sh` | 本地 ↔ `origin/<分支>` 双向同步；提交前扫疑似密钥文件名 |
| `update-env-snapshot.sh` | 刷新目标 README 里 `<!-- SNAPSHOT:START/END -->`；自己不 commit |
| `脚本说明.md` | 各脚本行为细节 |

`git-autosync.sh` / `update-env-snapshot.sh` 默认 `REPO_DIR=$PWD`、`BRANCH=main`、`SSH_KEY=$HOME/.ssh/id_ed25519_github`。不要对着本 public 仓开 autosync 把 `.env` / `auth.json` 推上来——脚本会拦常见密钥文件名，但拦不住写进普通文件的 token。

更细的行为、环境变量、脚本怎么互相调用，见 [`脚本说明.md`](脚本说明.md)。

---

## 不要做的事

- 不要把真实 API Key / Cookie / `~/.codex/auth.json` 推进 git。
- 不要把源仓库某台机器的 SNAPSHOT（IP、主机名、cron）当成你的环境。
- 不要把 CPA 理解成 npm 上的 `cpa` 包。
- 不要和 `git-autosync.sh` 同时手动 `git add` / `commit`，会撞索引锁。

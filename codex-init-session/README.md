# Codex init-session（高峰排队重开）

高峰期自动重试的 Codex **交互式** 开会话脚本。撞到 high demand / `Reconnecting...` 就关掉这次会话，等 5 分钟再新开。

新开会话用的就是：

```bash
codex --dangerously-bypass-approvals-and-sandbox
```

然后在 TUI 里输入 `init`。下面这种也算失败：

```
› init

◦ Reconnecting... 2/5 (8s • esc to interrupt)
  └ We're currently experiencing high demand, which may
    cause temporary errors.
```

`init` 成功后：

- 工作目录有 `task.md` → 同一会话里按它跑
- 没有 → 再等 5 分钟
- 把 **会话 ID** 打到终端，并写到文件
- TUI 留在 `screen` 里，随时 `screen -r` 进去

---

## 一键（curl / wget）

本机已装好 `codex`、`python3`、`screen`。

**当前目录开一轮：**

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh | bash -s -- -C "$(pwd)"
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh | bash -s -- -C "$(pwd)"
```

**指定项目目录：**

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C /path/to/proj
```

**有 `task.md` 时（init 成功后自动按文件执行）：**

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C /path/to/proj --task /path/to/proj/task.md
```

管道会把脚本喂给 bash，**`-s --` 后面才是传给脚本的参数**。不要漏 `--`。

---

## 想先审再跑

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh -o init-session.sh
chmod +x init-session.sh
./init-session.sh -C "$(pwd)"
```

或 clone：

```bash
git clone https://github.com/idlm/CommonUserScripts.git
cd CommonUserScripts/codex-init-session
./init-session.sh -C /path/to/proj
```

---

## 成功之后看什么

脚本结束时会打印：

```
SESSION_ID=01a0........
SCREEN=codex-init-时间戳-次数
```

同时写入：

| 文件 | 内容 |
|:--|:--|
| `~/.codex/init-session/last-session-id.txt` | 会话 ID |
| `~/.codex/init-session/last-screen.txt` | screen 名 |
| `<工作目录>/.codex-init-session-id` | 会话 ID（方便项目里读） |
| `~/.codex/init-session/run-*.log` | 本次运行日志 |

进 TUI：

```bash
screen -r "$(cat ~/.codex/init-session/last-screen.txt)"
```

只看会话 ID：

```bash
cat ~/.codex/init-session/last-session-id.txt
```

后台跑（断 SSH 也不停）：

```bash
screen -dmS codex-init bash -lc '
  curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
    | bash -s -- -C /path/to/proj
'
screen -r codex-init   # 回来看进度
```

---

## 它会做什么

1. `screen` 里新开：
   `codex --dangerously-bypass-approvals-and-sandbox -C <工作目录> --no-alt-screen`
2. 等输入框出现，发送 `init`
3. 盯 TUI / screen 日志。命中下面任一情况就 **关掉这次会话，等 5 分钟，再新开**：
   - `We're currently experiencing high demand, which may cause temporary errors.`
   - `Reconnecting... 2/5`（以及更高次数）
   - usage limit / 429 / 超时
4. `init` 成功 → 解析会话 ID
5. 有 `task.md` 就往同一 TUI 再塞一条「按 task.md 执行」；没有就再等 5 分钟
6. 打印会话 ID，TUI 继续留着

`--no-alt-screen` 只为了 screen 日志能抓住 `Reconnecting...`，不影响启动命令本身。

---

## 依赖

| 项 | 要求 |
|:--|:--|
| Codex CLI | 已登录，能跑 `codex --dangerously-bypass-approvals-and-sandbox` |
| python3 | 分类 TUI 文本、解析会话 ID |
| screen | 挂交互式 TUI，断线也能留着 |
| 系统 | Linux |

缺依赖时脚本会直接报错退出，不会装东西。

---

## 常用选项

```text
-C DIR          工作目录（默认当前目录）
--task FILE     task.md 路径（默认: DIR/task.md）
--wait SEC      失败重试间隔，默认 300（5 分钟）
--timeout SEC   单次 init 最长等待，默认 180
--no-task       init 成功后不跑 task.md
--no-after-wait init 成功且没有 task.md 时，不再额外等 5 分钟
--max N         最多尝试 N 次 init，0=无限
--out FILE      成功后把会话 ID 写到这个文件
--name NAME     screen 会话名（默认自动生成）
-h, --help      帮助
```

例子：

```bash
# 只 init，成功立刻退出，不等那额外 5 分钟
./init-session.sh -C /home --no-task --no-after-wait

# 最多试 12 次（大约一小时）
./init-session.sh -C /home --max 12

# 高峰重试改成 2 分钟
./init-session.sh -C /home --wait 120
```

环境变量：`CODEX_BIN` `WAIT_SECS` `WORKDIR` `OUT_DIR`

```bash
export WORKDIR=/path/to/proj
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/codex-init-session/init-session.sh \
  | bash -s -- -C "$WORKDIR"
```

跑完读 ID：

```bash
SID="$(cat ~/.codex/init-session/last-session-id.txt)"
echo "$SID"
```

---

## 不要做的事

- 这不是绕过限流，只是高峰失败后排队重开。
- 不要把会话 ID 日志当密钥提交进 git。
- 脚本会带 `--dangerously-bypass-approvals-and-sandbox`，只在你信任的目录跑。

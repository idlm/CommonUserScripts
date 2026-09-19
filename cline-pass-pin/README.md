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

本目录 **不 vendoring** [cline-pass-switcher](https://github.com/munmunjaklin458-afk/cline-pass-switcher)（MIT，零 npm 依赖，Node ≥ 18）。
一键脚本只 clone 上游、写本机 `config.json` 的 `perModel` 钉住段。无利益相关。

按作者的说法：switcher **只是帮你加了个请求特定上游的请求头**。
agent 软件的 provider 配置里自己加 `providerOptions.gateway.only: ["deepseek"]`，就不用这个软件。

```
status   PIN TEMPLATE + INSTALLER
model    cline-pass/deepseek-v4.1-flash
pipe     planner  →  Vercel AI Gateway  →  deepseek
listen   127.0.0.1:3123
policy   仓库不放 sk_ / Cookie / auth.json
```

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
slug 仍是 `deepseek`，不是 `openrouter`。

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
CLINE_PASS_KEY='sk_REPLACE_ME' \
  curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/cline-pass-pin/install.sh \
  | bash -s -- --yes --daemon

# 方式 B：先装后开控制台填
# 源码在 ~/.cline-pass-switcher/src ；config 在同级
DATA_DIR="$HOME/.cline-pass-switcher" \
  node "$HOME/.cline-pass-switcher/src/server.js"
# 浏览器打开 http://127.0.0.1:3123/  → 账号管理 → 粘贴 Cline Pass Key
# 或装完直接：
#   bash pin-ds.sh --daemon
```

本地已 clone 本仓时：

```bash
bash cline-pass-pin/install.sh --daemon
# 或直接
bash cline-pass-pin/pin-ds.sh --help
```

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
  "apiKey": "{{🐶}}",
  "requestBodyExtras": {
    "providerOptions": {
      "gateway": { "only": ["deepseek"] }
    }
  }
}
```

完整块见 [`examples/provider-snippet.json`](examples/provider-snippet.json)。
pi 的 models 清单见 [`examples/pi-models.json`](examples/pi-models.json)（`apiKey` 占位 `{{🐶}}`）。

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

## 目录

```
cline-pass-pin/
├── README.md                              本文件
├── install.sh                             curl/wget 入口（再拉 pin-ds.sh）
├── pin-ds.sh                              clone switcher + 写钉住 config + 启停
└── examples/
    ├── pi-models.json                     pi 的 clinepass provider 块（Key 占位）
    ├── config.ds-v4.1-flash.json          switcher 本机配置模板（无 Key）
    └── provider-snippet.json              走代理 vs 直连自钉
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

1. **Cline Pass Key** 在 Cline 账户设置创建，前缀 `sk_`。本仓 examples 一律 `{{🐶}}` / 空字符串。
2. **pi**：把 `examples/pi-models.json` 的 `clinepass` 块合进 pi 的 models 配置，只改 `apiKey`。走 switcher 时把 `baseUrl` 改成 `http://127.0.0.1:3123/v1`。
3. **Cline VSCode / 其它 OpenAI 兼容客户端**：Base URL 指代理即可，模型 id 手写 `cline-pass/deepseek-v4.1-flash`。
4. **dsh-cline-pass**（[yhshzh/dsh-cline-pass](https://github.com/yhshzh/dsh-cline-pass)）是 dsh 插件，渠道逻辑可参考；本仓主路径是 switcher + pi JSON，不是 dsh。
5. **systemd / 开机自启**：本脚本不装 unit。要常驻用 `--daemon` 或自己写 systemd，`Environment=DATA_DIR=... BIND_HOST=127.0.0.1 PORT=3123`。
6. **Docker**：看上游 switcher 的 compose，不是本目录范围。
7. 管道归属由 Cline 侧决定、可能再变。控制台「探测」会刷新每个模型的管道类型与渠道清单。ds-v4.1-flash 目前是 planner。

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
```

---

## 致谢

- [munmunjaklin458-afk/cline-pass-switcher](https://github.com/munmunjaklin458-afk/cline-pass-switcher) · MIT · 本机代理 + `injectPrefs`
- [yhshzh/dsh-cline-pass](https://github.com/yhshzh/dsh-cline-pass) · dsh 插件，缓存率对照实验的来源之一
- [Cline Pass](https://cline.bot/cline-pass) · 订阅模型 `cline-pass/*`
- [Vercel AI Gateway — Provider Filtering](https://vercel.com/docs/ai-gateway/models-and-providers/provider-filtering-and-ordering)

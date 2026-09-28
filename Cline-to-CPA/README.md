# Cline-to-CPA

把本机的 Cline Pass 观测代理反带出去，给远程 CPA 当一条 OpenAI 兼容上游。

钉上游已经失效。这个目录**不注入** `providerOptions.gateway.only`。代理只做两件事：转发请求，记录网关实际选中的 `finalProvider`。

```
远程 CPA 或客户端
   │  Authorization: Bearer <下游密钥>
   ▼
http://<公网IP>:3123/v1
   │  丢掉 only / order / sort
   │  记下 finalProvider 和 DeepSeek 缓存命中
   ▼
https://api.cline.bot/api/v1
   用本机已经登录的 Cline Pass，不发给下游
```

本机自己的 Cline CLI 继续打 `http://127.0.0.1:3123/v1`。环回地址不要求下游密钥。

## 一条命令

需要 Node.js ≥ 18、git、python3。Cline Pass 登录沿用本机已有账号，脚本不接收 `sk_`。

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/Cline-to-CPA/install.sh \
  | bash -s -- --yes --install-service
```

```bash
wget -qO- https://raw.githubusercontent.com/idlm/CommonUserScripts/main/Cline-to-CPA/install.sh \
  | bash -s -- --yes --install-service
```

跑完终端会打印三行，交给远程 CPA：

```
Base URL   http://<公网IP>:3123/v1
API Key    cps-……          # 下游密钥，不是 Cline 的 sk_
Model      cline-pass/deepseek-v4.1-flash
```

密钥同时写在 `~/.cline-pass-switcher/config.json` 的 `proxyKey`，文件权限 `0600`。不要把这一行提交到 git。

## CPA 怎么接

```yaml
openai-compatibility:
  - name: "cline-pass"
    base-url: "http://<公网IP>:3123/v1"
    api-key-entries:
      - api-key: "<终端打印的 cps- 密钥>"
    models:
      - name: "cline-pass/deepseek-v4.1-flash"
        alias: "ds-flash"
```

| 钥匙 | 谁核验 | 放哪 |
|:--|:--|:--|
| `cps-…` | 远程客户端 → 本代理 | CPA 的 `api-key-entries`，或客户端的 API Key |
| Cline Pass 登录 | 本代理 → `api.cline.bot` | 本机 `config.json` 的 `accounts`，或 Cline CLI 已登录的 OAuth |
| CPA `api-keys` | 客户端 → CPA | 只在 CPA 自己的配置里，不要填到这里 |

短名 `ds4.1f` 会收成 `cline-pass/deepseek-v4.1-flash`。

## 自检

```bash
# 不带密钥，应是 401
curl -sS -m 10 http://<公网IP>:3123/v1/models

# 带密钥，应列出 cline-pass/*
curl -sS -m 10 -H "Authorization: Bearer <cps-密钥>" \
  http://<公网IP>:3123/v1/models
```

渠道分布只在本机看：`http://127.0.0.1:3123/`。

## 选项

| 参数 | 作用 |
|:--|:--|
| `--yes` | 已有 `config.json` 时也更新端口和公网地址，保留 accounts |
| `--install-service` | 写 systemd，`BIND_HOST=0.0.0.0`，开机自启 |
| `--status` | 只看地址和密钥是否已设，不改文件 |
| `--port N` | 端口，默认 `3123` |
| `--public URL` | 公网根地址，不带 `/v1`。空则用探测到的公网 IP |

环境变量：`CLINE_TO_CPA_HOME`、`CLINE_TO_CPA_PORT`、`CLINE_TO_CPA_PUBLIC`、`PROXY_KEY`。

云厂商安全组要放行对应 TCP 端口。这是明文 HTTP；要长期给别人用，前面再加一层 HTTPS。

## 不要做

```
✗  把 cps- 密钥、sk_、OAuth token 写进这个仓库
✗  把公网监听配上空的 proxyKey
✗  再往请求里写 gateway.only 指望钉回 deepseek 官转
✗  把 Cline 的 sk_ 填进 CPA 的 api-key-entries
✗  让本机 Cline CLI 改去打公网地址（它继续用 127.0.0.1）
```

实现在 [idlm/cline-pass-switcher](https://github.com/idlm/cline-pass-switcher) 的 `OBSERVE.md`。

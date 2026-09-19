# 写入 ~/.bashrc 后执行: source ~/.bashrc
# 把「你的新API_KEY」和网关地址换成自己的。不要把真实密钥提交进 git。

# 普通用法（兼容 Chat Completions 的网关，例如 123nhh）
export GROK_RELAY_API_KEY="你的新API_KEY"
export GROK_MODELS_BASE_URL="https://api.123nhh.com/v1"

# 若改用 runanytime 的 grok-4.6 + thinking-proxy，把上面两行改成：
# export GROK_RELAY_API_KEY="你的runanytime密钥"
# export GROK_MODELS_BASE_URL="http://127.0.0.1:8899/v1"

# Claude Code 接同一把 Grok 分组密钥时（Base URL 不要带 /v1）：
# export ANTHROPIC_BASE_URL="https://runanytime.hxi.me"
# export ANTHROPIC_AUTH_TOKEN="你的runanytime密钥"
# export ANTHROPIC_API_KEY="你的runanytime密钥"
# export ANTHROPIC_MODEL="grok-4.6"

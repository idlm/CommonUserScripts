# 追加到 ~/.bashrc（不要整文件覆盖发行版 bashrc）
# 来源：3HK 2026-09-19 快照。Key 必须自己填，不要提交真实值。

# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
[[ -r "$HOME/.grok/completions/bash/grok.bash" ]] && source "$HOME/.grok/completions/bash/grok.bash"
# <<< grok installer <<<

# 当前 3HK：直连网关，不是 127.0.0.1:8899 thinking-proxy
export GROK_RELAY_API_KEY="xapi_REPLACE_ME"
export GROK_MODELS_BASE_URL="https://x-api.cfd/v1"

# uv / pip --user 一类工具会生成这个文件；没有也可以删掉这行
[ -r "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

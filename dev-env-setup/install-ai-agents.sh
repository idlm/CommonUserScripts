#!/usr/bin/env bash
#
# AI Agent CLI 一键安装 (Claude Code + Codex + Gemini CLI + zcf)
# 幂等，可重复执行；已安装的组件默认跳过，--force 时重装/升级
#
# 用法:
#   bash install-ai-agents.sh                  # 安装全部组件
#   bash install-ai-agents.sh claude codex     # 只安装指定组件
#   bash install-ai-agents.sh --list           # 列出可安装组件
#   bash install-ai-agents.sh --force gemini   # 强制重装/升级指定组件
#
set -euo pipefail

# ---------- 配置 ----------
# 组件清单，格式: 键|命令名|npm 包名|说明
AGENTS=(
  "claude|claude|@anthropic-ai/claude-code|Claude Code (Anthropic 官方 CLI)"
  "codex|codex|@openai/codex|Codex CLI (OpenAI 官方)"
  "gemini|gemini|@google/gemini-cli|Gemini CLI (Google 官方)"
  "zcf|zcf|zcf|zcf 快速配置 Claude Code (也可 npx zcf 免安装运行)"
)

# 四个组件中 Claude Code 要求最高，统一按此下限准备 Node.js
NODE_MAJOR_MIN="${NODE_MAJOR_MIN:-22}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"

FORCE=0
SELECTED=()
# ---------- 配置结束 ----------

info() { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$1" >&2; exit 1; }

# 取清单字段: field <条目> <序号>
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

list_agents() {
    printf '\n可安装组件:\n\n'
    local item
    for item in "${AGENTS[@]}"; do
        printf '  %-8s %-22s %s\n' \
            "$(field "$item" 1)" "$(field "$item" 3)" "$(field "$item" 4)"
    done
    printf '\n'
}

# 按键名查条目，未命中返回非 0
find_agent() {
    local key="$1" item
    for item in "${AGENTS[@]}"; do
        if [[ "$(field "$item" 1)" == "$key" ]]; then
            printf '%s' "$item"
            return 0
        fi
    done
    return 1
}

usage() {
    cat <<'EOF'
AI Agent CLI 一键安装 (Claude Code + Codex + Gemini CLI + zcf)
幂等，可重复执行；已安装的组件默认跳过，--force 时重装/升级

用法:
  bash install-ai-agents.sh                  # 安装全部组件
  bash install-ai-agents.sh claude codex     # 只安装指定组件
  bash install-ai-agents.sh --list           # 列出可安装组件
  bash install-ai-agents.sh --force gemini   # 强制重装/升级指定组件

环境变量:
  NPM_REGISTRY      npm 源，默认 https://registry.npmjs.org
  NODE_MAJOR_MIN    Node.js 最低主版本，默认 22
EOF
}

# Node.js 与 npm 是所有组件的前置依赖，缺失或版本过低时补装
ensure_node() {
    local major need_install=0

    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        need_install=1
    else
        major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')"
        if (( major < NODE_MAJOR_MIN )); then
            warn "当前 Node.js $(node -v) 低于 v${NODE_MAJOR_MIN}.x，将升级"
            need_install=1
        fi
    fi

    if (( need_install == 0 )); then
        info "Node.js $(node -v) / npm $(npm -v) 已满足要求 (>= v${NODE_MAJOR_MIN})"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        info "安装前置依赖 curl / ca-certificates"
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
    fi

    info "通过 NodeSource 安装 Node.js ${NODE_MAJOR_MIN}.x"
    curl -fsSL --retry 3 --max-time 120 \
        "https://deb.nodesource.com/setup_${NODE_MAJOR_MIN}.x" | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

    command -v node >/dev/null 2>&1 || die "Node.js 安装失败"
    info "Node.js $(node -v) / npm $(npm -v) 安装完成"
}

install_agent() {
    local key="$1" item bin pkg desc
    if ! item="$(find_agent "$key")"; then
        warn "未找到组件: $key"
        list_agents
        die "已中止"
    fi

    bin="$(field "$item" 2)"
    pkg="$(field "$item" 3)"
    desc="$(field "$item" 4)"

    if (( FORCE == 0 )) && command -v "$bin" >/dev/null 2>&1; then
        info "$key 已安装 ($(command -v "$bin"))，跳过；--force 可重装/升级"
        return 0
    fi

    info "安装 $key: $pkg"
    printf '    说明: %s\n\n' "$desc"
    if ! npm install -g --registry "$NPM_REGISTRY" "$pkg"; then
        die "$key 安装失败: $pkg(检查网络或 npm 源，可用 NPM_REGISTRY 覆盖)"
    fi

    if ! command -v "$bin" >/dev/null 2>&1; then
        warn "$key 已写入全局目录，但命令 $bin 不在 PATH 中"
        warn "请确认 $(npm prefix -g)/bin 已加入 PATH"
        return 0
    fi
    info "$key 安装完成: $(command -v "$bin")"
}

verify_agent() {
    local key="$1" item bin ver
    item="$(find_agent "$key")"
    bin="$(field "$item" 2)"

    if command -v "$bin" >/dev/null 2>&1; then
        ver="$(timeout 20 "$bin" --version 2>&1 | head -n1 || true)"
        printf '  %-8s %s\n' "$key" "${ver:-已安装(未返回版本)}"
    else
        printf '  %-8s 未找到命令\n' "$key"
    fi
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            -l|--list)  list_agents; exit 0 ;;
            -h|--help)  usage; exit 0 ;;
            -f|--force) FORCE=1 ;;
            -*)         die "未知参数: $1(可用: --list / --force / --help)" ;;
            *)          SELECTED+=("$1") ;;
        esac
        shift
    done

    if (( ${#SELECTED[@]} == 0 )); then
        local item
        for item in "${AGENTS[@]}"; do
            SELECTED+=("$(field "$item" 1)")
        done
    fi

    # 先校验按键名，避免装机干到一半才发现组件名写错
    local key
    for key in "${SELECTED[@]}"; do
        find_agent "$key" >/dev/null || { warn "未找到组件: $key"; list_agents; die "已中止"; }
    done

    (( EUID == 0 )) || die "需要 root 权限(全局安装并可能补装 Node.js)，请用 sudo 或切换到 root"

    locale 2>/dev/null | grep -qi 'utf-\?8' || \
        warn "当前 locale 非 UTF-8，CLI 交互界面可能显示异常"

    ensure_node

    for key in "${SELECTED[@]}"; do
        install_agent "$key"
    done

    info "全部完成，版本验证:"
    for key in "${SELECTED[@]}"; do
        verify_agent "$key"
    done
    printf '\n提示: zcf 也可直接 npx zcf 免安装运行。\n'
}

main "$@"

#!/usr/bin/env bash
#
# CommonUserScripts 开发环境脚本入口
#
# 用法:
#   交互式菜单(推荐)
#     bash <(curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setup.sh)
#
#   一键安装 v1.0 (分级子菜单)
#     bash <(curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupV10.sh)
#
#   一键安装 v1.1 (新机引导,推荐)
#     bash <(curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh)
#
#   直接运行指定脚本(适合自动化,无需交互)
#     curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setup.sh | bash -s -- install-android-env
#
#   仅列出可用脚本
#     curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setup.sh | bash -s -- --list
#
set -euo pipefail

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup}"

# 脚本清单,格式: 键|相对路径|说明|是否需要 root
SCRIPTS=(
  "install-android-env|install-android-env.sh|APK 编译环境一键安装(JDK 17 + Gradle 8.7 + Android SDK 34)|yes"
  "install-ai-agents|install-ai-agents.sh|AI Agent CLI 一键安装(Claude Code + Codex + Gemini CLI + zcf)|yes"
  "github-ssh-push|github-ssh-push.sh|GitHub SSH 推送环境配置|no"
  "git-autosync|git-autosync.sh|Git 仓库双向自动同步(需配合 cron)|no"
  "update-env-snapshot|update-env-snapshot.sh|刷新 README 运行环境快照(需配合 cron)|no"
  "install-full-env|install-full-env.sh|交互式一键安装 v1.0(分级子菜单)|yes"
  "setupV10|setupV10.sh|一键安装入口 v1.0|yes"
  "setupv11|setupv11.sh|新机安装引导 v1.1(方案+勾选+进度)|yes"
)

TMP_DIR=""
# 注意: EXIT trap 中最后一条命令的退出状态会成为脚本的退出码。
# 这里必须用 if 而非 `[[ ... ]] && rm`,否则条件不满足时短路返回 1,
# 会让正常执行的脚本对外报告失败(自动化场景下会被误判为出错)。
cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    return 0
}
trap cleanup EXIT

info()  { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[33m[警告]\033[0m %s\n' "$1" >&2; }
die()   { printf '\033[31m[错误]\033[0m %s\n' "$1" >&2; exit 1; }

# 取清单字段: field <条目> <序号>
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

check_deps() {
    command -v curl >/dev/null 2>&1 || die "缺少 curl,请先安装:apt-get install -y curl"
    command -v bash >/dev/null 2>&1 || die "缺少 bash"
}

list_scripts() {
    printf '\n可用脚本:\n\n'
    local i=1 item
    for item in "${SCRIPTS[@]}"; do
        printf '  %d) %-22s %s\n' "$i" "$(field "$item" 1)" "$(field "$item" 3)"
        i=$((i + 1))
    done
    printf '\n'
}

# 按键名查条目,未命中返回非 0
find_item() {
    local key="$1" item
    for item in "${SCRIPTS[@]}"; do
        if [[ "$(field "$item" 1)" == "$key" ]]; then
            printf '%s' "$item"
            return 0
        fi
    done
    return 1
}

# 下载脚本到临时目录并做基本校验
fetch_script() {
    local path="$1" dest="$2"
    # -f 必须保留: 没有它,GitHub 返回 404 时会把错误页当正文写进文件
    curl -fsSL --retry 3 --max-time 120 -o "$dest" "$RAW_BASE/$path" \
        || die "下载失败: $RAW_BASE/$path(检查网络或路径是否存在)"
    [[ -s "$dest" ]] || die "下载内容为空: $path"
    # 校验 shebang,拦住把 HTML 错误页当脚本执行的情况
    head -c 2 "$dest" | grep -q '#!' || die "下载内容不是脚本(缺少 shebang),已中止"
}

run_script() {
    local item="$1"
    local key path desc need_root
    key="$(field "$item" 1)"
    path="$(field "$item" 2)"
    desc="$(field "$item" 3)"
    need_root="$(field "$item" 4)"

    if [[ "$need_root" == "yes" && "$(id -u)" != "0" ]]; then
        die "$key 需要 root 权限运行,请用 sudo 或切换到 root"
    fi

    TMP_DIR="$(mktemp -d)"
    local dest="$TMP_DIR/$(basename "$path")"

    info "准备执行: $key"
    printf '    说明: %s\n    来源: %s\n' "$desc" "$RAW_BASE/$path"
    fetch_script "$path" "$dest"
    printf '    大小: %s 字节 / %s 行\n\n' "$(wc -c <"$dest" | tr -d ' ')" "$(wc -l <"$dest" | tr -d ' ')"

    info "开始运行 $key"
    bash "$dest"
    info "$key 执行完毕"
}

interactive_menu() {
    # 经 curl 管道执行时 stdin 已被脚本正文占用,交互输入必须走 /dev/tty
    [[ -r /dev/tty ]] || die "当前环境无法交互,请改用参数方式,例如:bash -s -- install-android-env"

    list_scripts
    printf '请输入序号(1-%d),或 q 退出: ' "${#SCRIPTS[@]}"
    local choice
    read -r choice </dev/tty

    [[ "$choice" == "q" || "$choice" == "Q" ]] && { info "已取消"; exit 0; }
    [[ "$choice" =~ ^[0-9]+$ ]] || die "无效输入: $choice"
    (( choice >= 1 && choice <= ${#SCRIPTS[@]} )) || die "序号超出范围: $choice"

    run_script "${SCRIPTS[$((choice - 1))]}"
}

main() {
    check_deps

    case "${1:-}" in
        "")
            printf '\nCommonUserScripts 开发环境脚本入口\n'
            interactive_menu
            ;;
        -l|--list)
            list_scripts
            ;;
        -h|--help)
            sed -n '3,14p' "$0" 2>/dev/null || printf '用法: setup.sh [脚本名|--list|--help]\n'
            ;;
        *)
            local item
            if item="$(find_item "$1")"; then
                run_script "$item"
            else
                warn "未找到脚本: $1"
                list_scripts
                exit 1
            fi
            ;;
    esac
}

main "$@"



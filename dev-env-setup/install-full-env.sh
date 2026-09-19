#!/usr/bin/env bash
#
# 本机交互式一键安装  v1.0
# 入口: setupV10.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupV10.sh)
#
# 新机引导版见 v1.1: setupv11.sh
#
#   1. 基础软件(可单选): nano / htop / btop / screen
#   2. APK 编译环境(可单选): JDK / Gradle / cmdline-tools / adb / build-tools / platform
#   3. AI CLI(可单选): zcf / claude / gemini / codex / grok / cpa(CLIProxyAPI)
#   5. 安装全部项目(1+2+3,不含清理)
#   6. 清理系统垃圾与软件缓存
#
# 用法:
#   bash install-full-env.sh              # 交互菜单
#   bash install-full-env.sh 1            # 进入基础软件子菜单
#   bash install-full-env.sh nano         # 只装 nano
#   bash install-full-env.sh claude grok  # 只装指定 AI CLI
#   bash install-full-env.sh 5            # 安装全部项目
#   bash install-full-env.sh 6            # 清理垃圾与缓存
#
# CPA 来源: https://github.com/router-for-me/CLIProxyAPI
# Linux 官方安装器失败时改为解析 GitHub releases/latest 再下 tar.gz。
#
set -euo pipefail

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup}"
XAI_PIN_IP="${XAI_PIN_IP:-104.18.18.80}"
CPA_INSTALL_DIR="${CPA_INSTALL_DIR:-$HOME/cliproxyapi}"
CPA_INSTALLER_URL="${CPA_INSTALLER_URL:-https://raw.githubusercontent.com/router-for-me/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer}"
CPA_REPO="router-for-me/CLIProxyAPI"

ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
GRADLE_HOME="${GRADLE_HOME:-/opt/gradle-8.7}"
ANDROID_DL="https://dl.google.com/android/repository"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
APT_UPDATED=0
LOOP_MENU=1

info() { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$1" >&2; }
ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$1"; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$1" >&2; exit 1; }

need_root() {
    [[ "$(id -u)" == "0" ]] || die "需要 root 权限,请用 sudo 或切换到 root"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

read_choice() {
    local prompt="$1" reply=""
    printf '%s' "$prompt"
    if [[ -r /dev/tty ]]; then
        read -r reply </dev/tty || reply=""
    elif [[ -t 0 ]]; then
        read -r reply || reply=""
    else
        die "当前无法交互,请改用参数,例如: bash install-full-env.sh nano"
    fi
    printf '%s' "$reply"
}

print_status() {
    local cmd="$1" extra="${2:-}"
    if has_cmd "$cmd"; then
        printf '  %-16s \033[32m已安装\033[0m  %s\n' "$cmd" "$(command -v "$cmd")"
    elif [[ -n "$extra" && -x "$extra" ]]; then
        printf '  %-16s \033[32m已安装\033[0m  %s\n' "$cmd" "$extra"
    else
        printf '  %-16s \033[31m未安装\033[0m\n' "$cmd"
    fi
}

run_sibling() {
    local name="$1"
    shift
    local candidates=(
        "$SCRIPT_DIR/$name"
    )
    if [[ -n "${LOCAL_SCRIPTS_DIR:-}" ]]; then
        candidates+=("$LOCAL_SCRIPTS_DIR/$name")
    fi
    local f
    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            info "调用 $f $*"
            bash "$f" "$@"
            return 0
        fi
    done

    local tmp
    tmp="$(mktemp)"
    info "本机没有 $name,从 $RAW_BASE 下载"
    curl -fsSL --retry 3 --max-time 120 -o "$tmp" "$RAW_BASE/$name" \
        || die "下载失败: $RAW_BASE/$name"
    head -c 2 "$tmp" | grep -q '#!' || die "$name 下载内容不是脚本"
    bash "$tmp" "$@"
    rm -f "$tmp"
}

apt_update_once() {
    (( APT_UPDATED )) && return 0
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    APT_UPDATED=1
}

install_apt_pkg() {
    local pkg="$1" bin="${2:-$1}"
    need_root
    if has_cmd "$bin" && (( FORCE == 0 )); then
        info "$pkg 已安装 ($(command -v "$bin")),跳过"
        print_status "$bin"
        return 0
    fi
    apt_update_once
    export DEBIAN_FRONTEND=noninteractive
    info "安装 $pkg"
    apt-get install -y "$pkg"
    ok "$pkg 安装完成"
    print_status "$bin"
}

# ---------- 本机 DNS: x.ai 会被解析到错误地址 ----------
xai_resolves_ok() {
    local ip
    ip="$(getent ahostsv4 x.ai 2>/dev/null | awk '{print $1; exit}')"
    [[ "$ip" == 104.18.* || "$ip" == 104.19.* ]]
}

pin_xai_dns() {
    xai_resolves_ok && return 0
    if [[ "$(id -u)" == "0" ]]; then
        if grep -qE '(^|[[:space:]])x\.ai([[:space:]]|$)' /etc/hosts 2>/dev/null; then
            warn "x.ai 解析异常,但 /etc/hosts 已有记录,改用 curl --resolve"
        else
            printf '%s x.ai\n' "$XAI_PIN_IP" >> /etc/hosts
            info "已写入 /etc/hosts: $XAI_PIN_IP x.ai(绕过本机 DNS 污染)"
        fi
    else
        warn "非 root,无法写 /etc/hosts,grok 安装将用 curl --resolve"
    fi
}

curl_xai() {
    curl --resolve "x.ai:443:$XAI_PIN_IP" "$@"
}

wget_dl() {
    local url="$1" dest="${2:-}"
    if [[ -z "$dest" ]]; then
        dest="/tmp/$(basename "${url%%\?*}")"
    fi
    echo "    来源: $url"
    echo "    保存: $dest"
    wget --tries=5 --timeout=30 --waitretry=2 --show-progress --progress=bar:force \
        -c -O "$dest" "$url"
    echo "    完成: $(du -h "$dest" | awk '{print $1}')"
}

ensure_wget_unzip() {
    need_root
    has_cmd wget && has_cmd unzip && return 0
    apt_update_once
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y unzip wget
}

# ---------- 1. 基础软件 ----------
install_nano()   { install_apt_pkg nano nano; }
install_htop()   { install_apt_pkg htop htop; }
install_btop()   { install_apt_pkg btop btop; }
install_screen() { install_apt_pkg screen screen; }

install_base() {
    info "安装全部基础软件: nano htop btop screen"
    install_nano
    install_htop
    install_btop
    install_screen
    ok "基础软件安装完成"
}

# ---------- 2. APK 编译环境 ----------
source_android_profile() {
    if [[ -f /etc/profile.d/android.sh ]]; then
        # shellcheck disable=SC1091
        source /etc/profile.d/android.sh
    fi
}

install_jdk() {
    need_root
    if has_cmd java && (( FORCE == 0 )); then
        info "JDK 已安装,跳过"
        java -version 2>&1 | head -1
        return 0
    fi
    apt_update_once
    export DEBIAN_FRONTEND=noninteractive
    info "安装 OpenJDK 17"
    apt-get install -y openjdk-17-jdk-headless unzip wget
    ok "OpenJDK 17 安装完成"
    java -version 2>&1 | head -1
}

install_gradle() {
    need_root
    ensure_wget_unzip
    if [[ -x "$GRADLE_HOME/bin/gradle" ]] && (( FORCE == 0 )); then
        info "Gradle 已安装: $GRADLE_HOME/bin/gradle"
        return 0
    fi
    info "安装 Gradle 8.7 -> $GRADLE_HOME (约 128MB,下载中请看进度条)"
    wget_dl https://services.gradle.org/distributions/gradle-8.7-bin.zip /tmp/gradle-8.7-bin.zip
    unzip -qo /tmp/gradle-8.7-bin.zip -d /opt
    [[ -x "$GRADLE_HOME/bin/gradle" ]] || die "Gradle 安装失败"
    ok "Gradle 8.7 安装完成"
}

install_cmdline_tools() {
    need_root
    ensure_wget_unzip
    mkdir -p "$ANDROID_HOME/cmdline-tools"
    if [[ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]] && (( FORCE == 0 )); then
        info "Android cmdline-tools 已安装"
        return 0
    fi
    info "安装 Android cmdline-tools"
    wget_dl "$ANDROID_DL/commandlinetools-linux-11076708_latest.zip" /tmp/commandlinetools-linux-11076708_latest.zip
    unzip -qo /tmp/commandlinetools-linux-11076708_latest.zip -d "$ANDROID_HOME/cmdline-tools"
    rm -rf "$ANDROID_HOME/cmdline-tools/latest"
    mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
    ok "cmdline-tools 安装完成"
}

accept_sdk_licenses() {
    need_root
    install_cmdline_tools
    info "接受 Android SDK 许可"
    yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
    ok "SDK 许可已处理"
}

install_adb() {
    need_root
    ensure_wget_unzip
    if [[ -x "$ANDROID_HOME/platform-tools/adb" ]] && (( FORCE == 0 )); then
        info "adb 已安装: $ANDROID_HOME/platform-tools/adb"
        return 0
    fi
    info "安装 platform-tools (adb)"
    wget_dl "$ANDROID_DL/platform-tools-latest-linux.zip" /tmp/platform-tools-latest-linux.zip
    unzip -qo /tmp/platform-tools-latest-linux.zip -d "$ANDROID_HOME"
    [[ -x "$ANDROID_HOME/platform-tools/adb" ]] || die "adb 安装失败"
    ok "adb 安装完成"
}

install_build_tools() {
    need_root
    ensure_wget_unzip
    if [[ -x "$ANDROID_HOME/build-tools/34.0.0/aapt2" ]] && (( FORCE == 0 )); then
        info "build-tools 34.0.0 已安装"
        return 0
    fi
    info "安装 build-tools 34.0.0"
    wget_dl "$ANDROID_DL/build-tools_r34-linux.zip" /tmp/build-tools_r34-linux.zip
    rm -rf /tmp/bt "$ANDROID_HOME/build-tools/34.0.0"
    mkdir -p /tmp/bt "$ANDROID_HOME/build-tools/34.0.0"
    unzip -qo /tmp/build-tools_r34-linux.zip -d /tmp/bt
    cp -a /tmp/bt/android-14/. "$ANDROID_HOME/build-tools/34.0.0/"
    ok "build-tools 34.0.0 安装完成"
}

install_android_platform() {
    need_root
    ensure_wget_unzip
    if [[ -f "$ANDROID_HOME/platforms/android-34/android.jar" ]] && (( FORCE == 0 )); then
        info "platform android-34 已安装"
        return 0
    fi
    info "安装 platform android-34"
    wget_dl "$ANDROID_DL/platform-34-ext12_r01.zip" /tmp/platform-34-ext12_r01.zip
    unzip -qo /tmp/platform-34-ext12_r01.zip -d "$ANDROID_HOME"
    mkdir -p "$ANDROID_HOME/platforms"
    rm -rf "$ANDROID_HOME/platforms/android-34"
    mv "$ANDROID_HOME/android-34-ext12" "$ANDROID_HOME/platforms/android-34"
    ok "platform android-34 安装完成"
}

write_android_env() {
    need_root
    info "写入 /etc/profile.d/android.sh"
    cat > /etc/profile.d/android.sh <<EOF
export ANDROID_HOME=$ANDROID_HOME
export ANDROID_SDK_ROOT=$ANDROID_HOME
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$GRADLE_HOME/bin:\$PATH
EOF
    chmod +x /etc/profile.d/android.sh
    source_android_profile
    ok "环境变量已写入,当前终端可: source /etc/profile.d/android.sh"
}

print_apk_status() {
    source_android_profile
    print_status java
    print_status gradle "$GRADLE_HOME/bin/gradle"
    print_status sdkmanager "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
    print_status adb "$ANDROID_HOME/platform-tools/adb"
    if [[ -x "$ANDROID_HOME/build-tools/34.0.0/aapt2" ]]; then
        printf '  %-16s \033[32m已安装\033[0m  %s\n' "build-tools" "$ANDROID_HOME/build-tools/34.0.0"
    else
        printf '  %-16s \033[31m未安装\033[0m\n' "build-tools"
    fi
    if [[ -f "$ANDROID_HOME/platforms/android-34/android.jar" ]]; then
        printf '  %-16s \033[32m已安装\033[0m  %s\n' "android-34" "$ANDROID_HOME/platforms/android-34"
    else
        printf '  %-16s \033[31m未安装\033[0m\n' "android-34"
    fi
}

install_apk() {
    need_root
    info "安装全部 APK 编译环境"
    run_sibling install-android-env.sh
    source_android_profile
    print_apk_status
}

# ---------- 3. AI CLI + CPA ----------
install_npm_agent() {
    local key="$1"
    need_root
    local args=()
    (( FORCE )) && args+=(--force)
    run_sibling install-ai-agents.sh "${args[@]}" "$key"
}

install_grok() {
    if has_cmd grok && (( FORCE == 0 )); then
        info "grok 已安装 ($(command -v grok)),跳过"
        print_status grok "$HOME/.grok/bin/grok"
        return 0
    fi
    pin_xai_dns
    info "安装 Grok CLI(官方 https://x.ai/cli/install.sh)"
    local installer
    installer="$(mktemp)"
    if ! curl_xai -fsSL --retry 3 --max-time 60 -o "$installer" https://x.ai/cli/install.sh; then
        rm -f "$installer"
        die "下载 grok 安装脚本失败(x.ai DNS 污染或网络不通)"
    fi
    head -c 2 "$installer" | grep -q '#!' || { rm -f "$installer"; die "grok 安装脚本内容异常"; }

    (
        curl() {
            local a saw=0
            for a in "$@"; do
                [[ "$a" == *x.ai* ]] && saw=1
            done
            if (( saw )); then
                command curl --resolve "x.ai:443:$XAI_PIN_IP" "$@"
            else
                command curl "$@"
            fi
        }
        export -f curl
        bash "$installer"
    )
    rm -f "$installer"
    export PATH="$HOME/.grok/bin:/usr/local/bin:$PATH"
    has_cmd grok || [[ -x "$HOME/.grok/bin/grok" ]] || die "grok 安装后仍找不到命令"
    ok "grok 安装完成"
    print_status grok "$HOME/.grok/bin/grok"
}

cpa_binary() {
    local p
    for p in \
        "$(command -v cpa 2>/dev/null || true)" \
        "$(command -v cli-proxy-api 2>/dev/null || true)" \
        "$CPA_INSTALL_DIR/cli-proxy-api" \
        /usr/local/bin/cli-proxy-api \
        /usr/local/bin/cpa
    do
        [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

link_cpa() {
    local src="$1"
    [[ -x "$src" ]] || return 1
    local dest_dir="/usr/local/bin"
    if [[ ! -w "$dest_dir" ]]; then
        dest_dir="$HOME/.local/bin"
        mkdir -p "$dest_dir"
    fi
    ln -sfn "$src" "$dest_dir/cli-proxy-api"
    ln -sfn "$src" "$dest_dir/cpa"
    ok "已链接 $dest_dir/cpa -> $src"
}

latest_cpa_tag() {
    local loc
    loc="$(curl -fsSI --max-time 25 -A 'curl' \
        "https://github.com/${CPA_REPO}/releases/latest" \
        | awk 'tolower($1)=="location:"{print $2; exit}' | tr -d '\r')"
    [[ -n "$loc" ]] || return 1
    local tag="${loc##*/}"
    printf '%s' "${tag#v}"
}

install_cpa_from_release() {
    local arch version url tmp dir bin
    case "$(uname -m)" in
        x86_64|amd64) arch="linux_amd64" ;;
        aarch64|arm64) arch="linux_aarch64" ;;
        *) die "CLIProxyAPI 不支持架构: $(uname -m)" ;;
    esac

    info "GitHub API 不可用时,改从 releases/latest 解析版本"
    version="$(latest_cpa_tag)" || die "无法解析 CLIProxyAPI 最新版本(检查访问 github.com)"
    url="https://github.com/${CPA_REPO}/releases/download/v${version}/CLIProxyAPI_${version}_${arch}.tar.gz"
    info "下载 CLIProxyAPI $version: $url"

    tmp="$(mktemp)"
    curl -fL --retry 3 --max-time 180 -o "$tmp" "$url" || die "下载 CLIProxyAPI 失败: $url"
    [[ -s "$tmp" ]] || die "下载的 CLIProxyAPI 压缩包为空"

    dir="${CPA_INSTALL_DIR}/${version}"
    mkdir -p "$dir"
    tar -xzf "$tmp" -C "$dir"
    rm -f "$tmp"

    bin="$(find "$dir" -type f \( -name cli-proxy-api -o -name CLIProxyAPI \) | head -1)"
    [[ -n "$bin" ]] || die "压缩包里没有 cli-proxy-api / CLIProxyAPI"
    chmod +x "$bin"

    mkdir -p "$CPA_INSTALL_DIR"
    ln -sfn "$bin" "$CPA_INSTALL_DIR/cli-proxy-api"
    printf '%s\n' "$version" > "$CPA_INSTALL_DIR/version.txt"
    link_cpa "$CPA_INSTALL_DIR/cli-proxy-api"
    ok "CLIProxyAPI $version 安装到 $CPA_INSTALL_DIR"
}

install_cpa() {
    local existing
    if existing="$(cpa_binary)" && (( FORCE == 0 )); then
        info "CPA (CLIProxyAPI) 已安装: $existing"
        link_cpa "$existing" || true
        print_status cpa "$existing"
        return 0
    fi

    info "安装 CPA = CLIProxyAPI (https://github.com/${CPA_REPO})"
    info "优先走官方 Linux 安装器,失败则直下 GitHub Release"

    local installer rc=0
    installer="$(mktemp)"
    if curl -fsSL --retry 3 --max-time 60 -o "$installer" "$CPA_INSTALLER_URL" \
        && head -c 2 "$installer" | grep -q '#!'; then
        if ! bash "$installer" install; then
            rc=1
            warn "官方安装器失败(本机 GitHub API 常被限流),改走 Release 直链"
        fi
    else
        rc=1
        warn "官方安装器下载失败,改走 Release 直链"
    fi
    rm -f "$installer"

    if (( rc != 0 )) || ! cpa_binary >/dev/null; then
        install_cpa_from_release
    elif [[ -x "$CPA_INSTALL_DIR/cli-proxy-api" ]]; then
        link_cpa "$CPA_INSTALL_DIR/cli-proxy-api"
    fi

    export PATH="/usr/local/bin:$HOME/.local/bin:$CPA_INSTALL_DIR:$PATH"
    cpa_binary >/dev/null || die "CPA (CLIProxyAPI) 安装后仍找不到命令"
    info "CPA 文档: https://help.router-for.me/  登录示例: cpa --claude-login / --codex-login / --login"
    print_status cpa "$(cpa_binary || true)"
}

print_ai_status() {
    export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.grok/bin:$CPA_INSTALL_DIR:$PATH"
    print_status zcf
    print_status claude
    print_status gemini
    print_status codex
    print_status grok "$HOME/.grok/bin/grok"
    print_status cpa "$(cpa_binary || true)"
    print_status cli-proxy-api "$CPA_INSTALL_DIR/cli-proxy-api"
}

install_ai() {
    info "安装全部 AI CLI: zcf / claude / gemini / codex / grok / cpa"
    install_npm_agent zcf
    install_npm_agent claude
    install_npm_agent gemini
    install_npm_agent codex
    install_grok
    install_cpa
    info "AI CLI 状态:"
    print_ai_status
}

# ---------- 6. 清理 ----------
cleanup_junk() {
    need_root
    info "清理系统垃圾与软件缓存(apt / npm / pip / go / 过期临时文件)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get autoremove -y || true
    apt-get autoclean -y || true
    apt-get clean || true
    rm -rf /var/cache/apt/archives/*.deb

    if has_cmd npm; then
        npm cache clean --force >/dev/null 2>&1 || true
    fi
    rm -rf /root/.npm/_cacache /root/.cache/pip /root/.cache/go-build \
           /root/.cache/gradle /root/.gradle/caches 2>/dev/null || true

    find /tmp /var/tmp -xdev -type f -mtime +2 -delete 2>/dev/null || true
    find /tmp /var/tmp -xdev -type d -empty -mtime +2 -delete 2>/dev/null || true

    ok "清理完成"
    df -h / | tail -1
}

install_all() {
    info "安装全部项目(基础软件 + APK 环境 + AI CLI,不含清理)"
    install_base
    install_apk
    install_ai
    ok "全部项目安装完成"
}

# ---------- 菜单 ----------
usage() {
    cat <<'EOF'
本机交互式一键安装

用法:
  bash install-full-env.sh                 # 交互菜单
  bash install-full-env.sh 1               # 基础软件子菜单
  bash install-full-env.sh nano            # 只装 nano
  bash install-full-env.sh 3               # AI CLI 子菜单
  bash install-full-env.sh claude grok cpa # 只装指定 AI CLI
  bash install-full-env.sh 5               # 安装全部项目
  bash install-full-env.sh 6               # 清理垃圾与缓存
  bash install-full-env.sh --force grok    # 强制重装 grok

主菜单:
  1  基础软件(可再单选 nano/htop/btop/screen)
  2  APK 编译环境(可再单选 JDK/Gradle/SDK 组件)
  3  AI CLI(可再单选 zcf/claude/gemini/codex/grok/cpa)
  5  安装全部项目(1+2+3,不含清理)
  6  清理系统垃圾与软件缓存
  0  退出

CPA 是 CLIProxyAPI: https://github.com/router-for-me/CLIProxyAPI
EOF
}

show_menu() {
    cat <<'EOF'

本机一键安装
  1) 基础软件              进入后可单选 nano / htop / btop / screen
  2) APK 编译环境          进入后可单选 JDK / Gradle / SDK 组件
  3) AI CLI                进入后可单选 zcf / claude / gemini / codex / grok / cpa
  5) 安装全部项目          1 + 2 + 3(不含清理)
  6) 清理系统垃圾          apt / npm / pip / go / 软件缓存
  0) 退出

cpa = CLIProxyAPI  https://github.com/router-for-me/CLIProxyAPI
EOF
}

show_base_menu() {
    cat <<'EOF'

[1] 基础软件
  1) nano
  2) htop
  3) btop
  4) screen
  a) 安装本组全部
  b) 返回上级
EOF
    print_status nano
    print_status htop
    print_status btop
    print_status screen
}

show_apk_menu() {
    cat <<'EOF'

[2] APK 编译环境
  1) OpenJDK 17
  2) Gradle 8.7
  3) Android cmdline-tools
  4) 接受 SDK 许可
  5) platform-tools (adb)
  6) build-tools 34.0.0
  7) platform android-34
  8) 写入环境变量
  a) 安装本组全部
  b) 返回上级
EOF
    print_apk_status
}

show_ai_menu() {
    cat <<'EOF'

[3] AI CLI
  1) zcf
  2) claude     Claude Code
  3) gemini     Gemini CLI
  4) codex      Codex CLI
  5) grok       Grok CLI
  6) cpa        CLIProxyAPI
  a) 安装本组全部
  b) 返回上级
EOF
    print_ai_status
}

submenu_loop() {
    local kind="$1" choice
    while :; do
        case "$kind" in
            base) show_base_menu; printf '请选择(1-4 / a 全部 / b 返回): ' ;;
            apk)  show_apk_menu;  printf '请选择(1-8 / a 全部 / b 返回): ' ;;
            ai)   show_ai_menu;   printf '请选择(1-6 / a 全部 / b 返回): ' ;;
        esac
        choice="$(read_choice "")"
        printf '\n'
        case "$kind:$choice" in
            *:b|*:B|*:0|*:) return 0 ;;
            base:1|base:nano)   install_nano ;;
            base:2|base:htop)   install_htop ;;
            base:3|base:btop)   install_btop ;;
            base:4|base:screen) install_screen ;;
            base:a|base:A)      install_base ;;
            apk:1|apk:jdk|apk:java) install_jdk ;;
            apk:2|apk:gradle)   install_gradle ;;
            apk:3|apk:sdk|apk:cmdline-tools) install_cmdline_tools ;;
            apk:4|apk:licenses) accept_sdk_licenses ;;
            apk:5|apk:adb)      install_adb ;;
            apk:6|apk:build-tools) install_build_tools ;;
            apk:7|apk:platform) install_android_platform ;;
            apk:8|apk:env)      write_android_env ;;
            apk:a|apk:A)        install_apk ;;
            ai:1|ai:zcf)        install_npm_agent zcf ;;
            ai:2|ai:claude)     install_npm_agent claude ;;
            ai:3|ai:gemini)     install_npm_agent gemini ;;
            ai:4|ai:codex)      install_npm_agent codex ;;
            ai:5|ai:grok)       install_grok ;;
            ai:6|ai:cpa|ai:cliproxyapi) install_cpa ;;
            ai:a|ai:A)          install_ai ;;
            *) warn "无效选择: $choice" ;;
        esac
    done
}

run_choice() {
    case "$1" in
        1|--base)  submenu_loop base ;;
        2|--apk)   submenu_loop apk ;;
        3|--ai)    submenu_loop ai ;;
        5|--all)   LOOP_MENU=0; install_all ;;
        6|--clean) LOOP_MENU=0; cleanup_junk ;;
        nano)      LOOP_MENU=0; install_nano ;;
        htop)      LOOP_MENU=0; install_htop ;;
        btop)      LOOP_MENU=0; install_btop ;;
        screen)    LOOP_MENU=0; install_screen ;;
        jdk|java)  LOOP_MENU=0; install_jdk ;;
        gradle)    LOOP_MENU=0; install_gradle ;;
        sdk|cmdline-tools) LOOP_MENU=0; install_cmdline_tools ;;
        licenses)  LOOP_MENU=0; accept_sdk_licenses ;;
        adb)       LOOP_MENU=0; install_adb ;;
        build-tools) LOOP_MENU=0; install_build_tools ;;
        platform|android-34) LOOP_MENU=0; install_android_platform ;;
        env)       LOOP_MENU=0; write_android_env ;;
        zcf)       LOOP_MENU=0; install_npm_agent zcf ;;
        claude)    LOOP_MENU=0; install_npm_agent claude ;;
        gemini)    LOOP_MENU=0; install_npm_agent gemini ;;
        codex)     LOOP_MENU=0; install_npm_agent codex ;;
        grok)      LOOP_MENU=0; install_grok ;;
        cpa|cliproxyapi|cli-proxy-api) LOOP_MENU=0; install_cpa ;;
        0|q|Q) info "已取消"; exit 0 ;;
        *) die "未知选项: $1(用 --help 查看)" ;;
    esac
}

interactive_main() {
    local item
    while :; do
        show_menu
        item="$(read_choice "请输入序号(0/1/2/3/5/6): ")"
        printf '\n'
        [[ "$item" == "0" || "$item" == "q" || "$item" == "Q" ]] && { info "已退出"; return 0; }
        run_choice "$item"
        LOOP_MENU=1
    done
}

main() {
    local args=() item
    while (( $# > 0 )); do
        case "$1" in
            -f|--force) FORCE=1 ;;
            -h|--help)  usage; exit 0 ;;
            -l|--list)  show_menu; exit 0 ;;
            *)          args+=("$1") ;;
        esac
        shift
    done

    if (( ${#args[@]} == 0 )); then
        interactive_main
    else
        for item in "${args[@]}"; do
            run_choice "$item"
        done
    fi

    printf '\n'
    ok "任务完成。新开一个终端,或执行: source /etc/profile.d/android.sh; hash -r"
}

main "$@"

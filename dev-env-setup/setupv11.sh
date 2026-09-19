#!/usr/bin/env bash
#
# CommonUserScripts 新机安装引导  v1.1
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup/setupv11.sh)
#   bash setupv11.sh
#   bash setupv11.sh --profile new
#   bash setupv11.sh --profile custom
#   bash setupv11.sh --yes --profile apk
#   bash setupv11.sh --items nano,htop,claude,grok
#
# 与 v1.0 并存:
#   v1.0  分级子菜单      setupV10.sh
#   v1.1  预检+方案+勾选   setupv11.sh  (本文件)
#
set -euo pipefail

VERSION="1.1"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/idlm/CommonUserScripts/main/dev-env-setup}"
XAI_PIN_IP="${XAI_PIN_IP:-104.18.18.80}"
CPA_INSTALL_DIR="${CPA_INSTALL_DIR:-$HOME/cliproxyapi}"
CPA_INSTALLER_URL="${CPA_INSTALLER_URL:-https://raw.githubusercontent.com/router-for-me/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer}"
CPA_REPO="router-for-me/CLIProxyAPI"
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
GRADLE_HOME="${GRADLE_HOME:-/opt/gradle-8.7}"
ANDROID_DL="https://dl.google.com/android/repository"
NODE_MAJOR_MIN="${NODE_MAJOR_MIN:-22}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
LOG_FILE="${LOG_FILE:-/tmp/setupv11.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
ASSUME_YES=0
APT_UPDATED=0
NODE_READY=0
PROFILE=""
ITEMS_ARG=""
TOTAL_STEPS=0
STEP_INDEX=0
declare -a PLAN=()
declare -a RESULT_OK=()
declare -a RESULT_SKIP=()
declare -a RESULT_FAIL=()

# id|组|显示名|说明|默认选中(1/0)
MODULES=(
  "nano|base|nano|终端编辑器|1"
  "htop|base|htop|进程监视|1"
  "btop|base|btop|资源监视|1"
  "screen|base|screen|终端复用|1"
  "jdk|apk|OpenJDK 17|APK 编译必需|1"
  "gradle|apk|Gradle 8.7|约 128MB,有进度条|1"
  "cmdline|apk|Android cmdline-tools|sdkmanager|1"
  "adb|apk|platform-tools (adb)|真机/模拟器调试|1"
  "buildtools|apk|build-tools 34.0.0|aapt2 / zipalign|1"
  "platform|apk|platform android-34|android.jar|1"
  "env|apk|写入 Android 环境变量|/etc/profile.d/android.sh|1"
  "zcf|ai|zcf|Claude Code 快速配置|1"
  "claude|ai|claude|Claude Code CLI|1"
  "gemini|ai|gemini|Gemini CLI|1"
  "codex|ai|codex|Codex CLI|1"
  "grok|ai|grok|Grok CLI,绕过 x.ai DNS 污染|1"
  "cpa|ai|cpa|CLIProxyAPI,不是 npm 同名包|1"
  "clean|maint|清理缓存|apt/npm/pip/go,不删已装软件|0"
)

info() { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$1" >&2; }
ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$1"; }
err()  { printf '\033[31m[错误]\033[0m %s\n' "$1" >&2; }
die()  { err "$1"; exit 1; }
log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [[ "$(id -u)" == "0" ]] || die "需要 root。请: sudo bash $0"
}

read_tty() {
    local prompt="$1" reply=""
    printf '%s' "$prompt"
    if [[ -r /dev/tty ]]; then
        read -r reply </dev/tty || reply=""
    elif [[ -t 0 ]]; then
        read -r reply || reply=""
    else
        die "当前无法交互。改用: bash $0 --yes --profile new"
    fi
    printf '%s' "$reply"
}

confirm() {
    local prompt="${1:-确认执行?} [Y/n] "
    (( ASSUME_YES )) && return 0
    local a
    a="$(read_tty "$prompt")"
    [[ -z "$a" || "$a" == [Yy] || "$a" == [Yy][Ee][Ss] ]]
}

mod_by_id() {
    local id="$1" m
    for m in "${MODULES[@]}"; do
        [[ "$(field "$m" 1)" == "$id" ]] && { printf '%s' "$m"; return 0; }
    done
    return 1
}

ids_of_group() {
    local g="$1" m
    for m in "${MODULES[@]}"; do
        [[ "$(field "$m" 2)" == "$g" ]] && printf '%s\n' "$(field "$m" 1)"
    done
}

in_plan() {
    local id="$1" x
    for x in "${PLAN[@]+"${PLAN[@]}"}"; do
        [[ "$x" == "$id" ]] && return 0
    done
    return 1
}

add_plan() {
    local id="$1"
    in_plan "$id" && return 0
    PLAN+=("$id")
}

remove_plan() {
    local id="$1" x
    local -a next=()
    for x in "${PLAN[@]+"${PLAN[@]}"}"; do
        [[ "$x" == "$id" ]] || next+=("$x")
    done
    PLAN=("${next[@]+"${next[@]}"}")
}

toggle_plan() {
    local id="$1"
    if in_plan "$id"; then
        remove_plan "$id"
    else
        add_plan "$id"
    fi
}

set_plan_from_ids() {
    local raw="$1" id
    PLAN=()
    raw="${raw//,/ }"
    for id in $raw; do
        [[ -z "$id" ]] && continue
        mod_by_id "$id" >/dev/null || die "未知组件: $id"
        add_plan "$id"
    done
}

set_plan_profile() {
    local p="$1" id
    PLAN=()
    case "$p" in
        new|all)
            for id in nano htop btop screen jdk gradle cmdline adb buildtools platform env \
                      zcf claude gemini codex grok cpa; do
                add_plan "$id"
            done
            ;;
        base)  while read -r id; do add_plan "$id"; done < <(ids_of_group base) ;;
        apk)   while read -r id; do add_plan "$id"; done < <(ids_of_group apk) ;;
        ai)    while read -r id; do add_plan "$id"; done < <(ids_of_group ai) ;;
        clean) add_plan clean ;;
        custom)
            for id in nano htop btop screen jdk gradle cmdline adb buildtools platform env \
                      zcf claude gemini codex grok cpa; do
                add_plan "$id"
            done
            ;;
        *) die "未知方案: $p (可用: new/base/apk/ai/clean/custom)" ;;
    esac
}

installed_hint() {
    local id="$1"
    case "$id" in
        nano|htop|btop|screen|zcf|claude|gemini|codex) has_cmd "$id" && printf '已装' && return ;;
        grok) { has_cmd grok || [[ -x "$HOME/.grok/bin/grok" ]]; } && printf '已装' && return ;;
        cpa) { has_cmd cpa || has_cmd cli-proxy-api || [[ -x "$CPA_INSTALL_DIR/cli-proxy-api" ]]; } && printf '已装' && return ;;
        jdk) has_cmd java && printf '已装' && return ;;
        gradle) [[ -x "$GRADLE_HOME/bin/gradle" ]] && printf '已装' && return ;;
        cmdline) [[ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]] && printf '已装' && return ;;
        adb) { has_cmd adb || [[ -x "$ANDROID_HOME/platform-tools/adb" ]]; } && printf '已装' && return ;;
        buildtools) [[ -x "$ANDROID_HOME/build-tools/34.0.0/aapt2" ]] && printf '已装' && return ;;
        platform) [[ -f "$ANDROID_HOME/platforms/android-34/android.jar" ]] && printf '已装' && return ;;
        env) [[ -f /etc/profile.d/android.sh ]] && printf '已写' && return ;;
        clean) printf '可选'; return ;;
    esac
    printf '未装'
}

mark() {
    in_plan "$1" && printf '[\033[32mx\033[0m]' || printf '[ ]'
}

# ---------- 预检 ----------
disk_free_g() {
    df -BG / | awk 'NR==2 {gsub(/G/,""); print $4}'
}

preflight() {
    local free os kern
    os="$(. /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-?} ${VERSION_ID:-}")"
    kern="$(uname -r)"
    free="$(disk_free_g)"
    printf '\n\033[1mCommonUserScripts  新机安装  v%s\033[0m\n' "$VERSION"
    printf '旧版子菜单入口:  bash <(curl -fsSL %s/setupV10.sh)\n' "$RAW_BASE"
    printf '%s\n' "------------------------------------------------"
    printf '  用户     %s (uid=%s)\n' "$(id -un)" "$(id -u)"
    printf '  系统     %s  kernel %s\n' "$os" "$kern"
    printf '  架构     %s\n' "$(uname -m)"
    printf '  磁盘     / 剩余 %sG\n' "$free"
    printf '  日志     %s\n' "$LOG_FILE"
    if [[ "$(id -u)" != "0" ]]; then
        die "请用 root 运行。例: sudo bash $0"
    fi
    if [[ "${free:-0}" =~ ^[0-9]+$ ]] && (( free < 4 )); then
        warn "根分区剩余不足 4G,APK 环境可能装不下"
        confirm "仍要继续? [Y/n] " || die "已取消"
    fi
    : >"$LOG_FILE"
    log "start v$VERSION profile=${PROFILE:-interactive}"
}

# ---------- 下载 ----------
apt_update_once() {
    (( APT_UPDATED )) && return 0
    export DEBIAN_FRONTEND=noninteractive
    info "apt-get update"
    apt-get update -y
    APT_UPDATED=1
}

download() {
    local url="$1" dest="$2"
    printf '    下载: %s\n' "$url"
    printf '    保存: %s\n' "$dest"
    wget --tries=5 --timeout=30 --waitretry=2 --show-progress --progress=bar:force \
        -c -O "$dest" "$url"
    printf '    完成: %s\n' "$(du -h "$dest" | awk '{print $1}')"
}

ensure_wget_unzip() {
    has_cmd wget && has_cmd unzip && has_cmd curl && return 0
    apt_update_once
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y wget unzip curl ca-certificates
}

# ---------- 安装实现 ----------
install_apt_pkg() {
    local pkg="$1" bin="${2:-$1}"
    if has_cmd "$bin" && (( FORCE == 0 )); then
        ok "$pkg 已安装,跳过"
        return 10
    fi
    apt_update_once
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "$pkg"
    has_cmd "$bin" || return 1
    ok "$pkg 安装完成"
}

ensure_node() {
    (( NODE_READY )) && return 0
    local major=0 need=0
    if ! has_cmd node || ! has_cmd npm; then
        need=1
    else
        major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')"
        (( major < NODE_MAJOR_MIN )) && need=1
    fi
    if (( need == 0 )); then
        NODE_READY=1
        return 0
    fi
    ensure_wget_unzip
    info "安装 Node.js ${NODE_MAJOR_MIN}.x"
    curl -fsSL --retry 3 --max-time 120 "https://deb.nodesource.com/setup_${NODE_MAJOR_MIN}.x" | bash -
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y nodejs
    has_cmd node || return 1
    NODE_READY=1
}

install_npm_pkg() {
    local key="$1" bin="$2" pkg="$3"
    if has_cmd "$bin" && (( FORCE == 0 )); then
        ok "$key 已安装,跳过"
        return 10
    fi
    ensure_node
    info "npm i -g $pkg"
    npm install -g --registry "$NPM_REGISTRY" "$pkg"
    has_cmd "$bin" || warn "$key 已写入,但 $bin 不在 PATH,确认 \$(npm prefix -g)/bin"
    ok "$key 完成"
}

install_jdk() {
    if has_cmd java && (( FORCE == 0 )); then
        ok "JDK 已安装,跳过"; java -version 2>&1 | head -1; return 10
    fi
    apt_update_once
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y openjdk-17-jdk-headless unzip wget curl ca-certificates
    has_cmd java || return 1
    ok "OpenJDK 17 完成"
}

install_gradle() {
    ensure_wget_unzip
    if [[ -x "$GRADLE_HOME/bin/gradle" ]] && (( FORCE == 0 )); then
        ok "Gradle 已安装,跳过"; return 10
    fi
    info "Gradle 8.7 约 128MB,请看进度条(支持断点续传)"
    download https://services.gradle.org/distributions/gradle-8.7-bin.zip /tmp/gradle-8.7-bin.zip
    unzip -qo /tmp/gradle-8.7-bin.zip -d /opt
    [[ -x "$GRADLE_HOME/bin/gradle" ]] || return 1
    ok "Gradle 8.7 完成"
}

install_cmdline() {
    ensure_wget_unzip
    mkdir -p "$ANDROID_HOME/cmdline-tools"
    if [[ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]] && (( FORCE == 0 )); then
        ok "cmdline-tools 已安装,跳过"
    else
        download "$ANDROID_DL/commandlinetools-linux-11076708_latest.zip" /tmp/commandlinetools-linux-11076708_latest.zip
        unzip -qo /tmp/commandlinetools-linux-11076708_latest.zip -d "$ANDROID_HOME/cmdline-tools"
        rm -rf "$ANDROID_HOME/cmdline-tools/latest"
        mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
    fi
    yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
    ok "cmdline-tools + SDK 许可完成"
}

install_adb() {
    ensure_wget_unzip
    if [[ -x "$ANDROID_HOME/platform-tools/adb" ]] && (( FORCE == 0 )); then
        ok "adb 已安装,跳过"; return 10
    fi
    download "$ANDROID_DL/platform-tools-latest-linux.zip" /tmp/platform-tools-latest-linux.zip
    unzip -qo /tmp/platform-tools-latest-linux.zip -d "$ANDROID_HOME"
    [[ -x "$ANDROID_HOME/platform-tools/adb" ]] || return 1
    ok "adb 完成"
}

install_buildtools() {
    ensure_wget_unzip
    if [[ -x "$ANDROID_HOME/build-tools/34.0.0/aapt2" ]] && (( FORCE == 0 )); then
        ok "build-tools 已安装,跳过"; return 10
    fi
    download "$ANDROID_DL/build-tools_r34-linux.zip" /tmp/build-tools_r34-linux.zip
    rm -rf /tmp/bt "$ANDROID_HOME/build-tools/34.0.0"
    mkdir -p /tmp/bt "$ANDROID_HOME/build-tools/34.0.0"
    unzip -qo /tmp/build-tools_r34-linux.zip -d /tmp/bt
    cp -a /tmp/bt/android-14/. "$ANDROID_HOME/build-tools/34.0.0/"
    ok "build-tools 34.0.0 完成"
}

install_platform() {
    ensure_wget_unzip
    if [[ -f "$ANDROID_HOME/platforms/android-34/android.jar" ]] && (( FORCE == 0 )); then
        ok "android-34 已安装,跳过"; return 10
    fi
    download "$ANDROID_DL/platform-34-ext12_r01.zip" /tmp/platform-34-ext12_r01.zip
    unzip -qo /tmp/platform-34-ext12_r01.zip -d "$ANDROID_HOME"
    mkdir -p "$ANDROID_HOME/platforms"
    rm -rf "$ANDROID_HOME/platforms/android-34"
    mv "$ANDROID_HOME/android-34-ext12" "$ANDROID_HOME/platforms/android-34"
    ok "platform android-34 完成"
}

install_env() {
    cat > /etc/profile.d/android.sh <<EOF
export ANDROID_HOME=$ANDROID_HOME
export ANDROID_SDK_ROOT=$ANDROID_HOME
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$GRADLE_HOME/bin:\$PATH
EOF
    chmod +x /etc/profile.d/android.sh
    # shellcheck disable=SC1091
    source /etc/profile.d/android.sh
    ok "已写入 /etc/profile.d/android.sh"
}

xai_ok() {
    local ip
    ip="$(getent ahostsv4 x.ai 2>/dev/null | awk '{print $1; exit}')"
    [[ "$ip" == 104.18.* || "$ip" == 104.19.* ]]
}

pin_xai() {
    xai_ok && return 0
    if grep -qE '(^|[[:space:]])x\.ai([[:space:]]|$)' /etc/hosts 2>/dev/null; then
        warn "x.ai 解析异常,改用 curl --resolve"
        return 0
    fi
    printf '%s x.ai\n' "$XAI_PIN_IP" >> /etc/hosts
    info "已写入 /etc/hosts: $XAI_PIN_IP x.ai"
}

install_grok() {
    export PATH="$HOME/.grok/bin:/usr/local/bin:$PATH"
    if has_cmd grok && (( FORCE == 0 )); then
        ok "grok 已安装,跳过"; return 10
    fi
    pin_xai
    local installer
    installer="$(mktemp)"
    curl --resolve "x.ai:443:$XAI_PIN_IP" -fsSL --retry 3 --max-time 60 \
        -o "$installer" https://x.ai/cli/install.sh || { rm -f "$installer"; return 1; }
    head -c 2 "$installer" | grep -q '#!' || { rm -f "$installer"; return 1; }
    (
        curl() {
            local a saw=0
            for a in "$@"; do [[ "$a" == *x.ai* ]] && saw=1; done
            if (( saw )); then command curl --resolve "x.ai:443:$XAI_PIN_IP" "$@"; else command curl "$@"; fi
        }
        export -f curl
        bash "$installer"
    )
    rm -f "$installer"
    export PATH="$HOME/.grok/bin:/usr/local/bin:$PATH"
    has_cmd grok || [[ -x "$HOME/.grok/bin/grok" ]] || return 1
    ok "grok 完成"
}

cpa_bin() {
    local p
    for p in "$(command -v cpa 2>/dev/null || true)" \
             "$(command -v cli-proxy-api 2>/dev/null || true)" \
             "$CPA_INSTALL_DIR/cli-proxy-api" /usr/local/bin/cli-proxy-api /usr/local/bin/cpa; do
        [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

link_cpa() {
    local src="$1" dest="/usr/local/bin"
    [[ -x "$src" ]] || return 1
    [[ -w "$dest" ]] || { dest="$HOME/.local/bin"; mkdir -p "$dest"; }
    ln -sfn "$src" "$dest/cli-proxy-api"
    ln -sfn "$src" "$dest/cpa"
}

latest_cpa_tag() {
    local loc tag
    loc="$(curl -fsSI --max-time 25 -A 'curl' \
        "https://github.com/${CPA_REPO}/releases/latest" \
        | awk 'tolower($1)=="location:"{print $2; exit}' | tr -d '\r')"
    [[ -n "$loc" ]] || return 1
    tag="${loc##*/}"
    printf '%s' "${tag#v}"
}

install_cpa_release() {
    local arch version url tmp dir bin
    case "$(uname -m)" in
        x86_64|amd64) arch="linux_amd64" ;;
        aarch64|arm64) arch="linux_aarch64" ;;
        *) return 1 ;;
    esac
    version="$(latest_cpa_tag)" || return 1
    url="https://github.com/${CPA_REPO}/releases/download/v${version}/CLIProxyAPI_${version}_${arch}.tar.gz"
    tmp="$(mktemp)"
    info "直下 CLIProxyAPI $version"
    curl -fL --retry 3 --max-time 180 --progress-bar -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    dir="${CPA_INSTALL_DIR}/${version}"
    mkdir -p "$dir"
    tar -xzf "$tmp" -C "$dir"
    rm -f "$tmp"
    bin="$(find "$dir" -type f \( -name cli-proxy-api -o -name CLIProxyAPI \) | head -1)"
    [[ -n "$bin" ]] || return 1
    chmod +x "$bin"
    ln -sfn "$bin" "$CPA_INSTALL_DIR/cli-proxy-api"
    printf '%s\n' "$version" > "$CPA_INSTALL_DIR/version.txt"
    link_cpa "$CPA_INSTALL_DIR/cli-proxy-api"
}

install_cpa() {
    local existing installer rc=0
    if existing="$(cpa_bin)" && (( FORCE == 0 )); then
        link_cpa "$existing" || true
        ok "cpa 已安装,跳过"; return 10
    fi
    info "安装 CPA = CLIProxyAPI"
    installer="$(mktemp)"
    if curl -fsSL --retry 3 --max-time 60 -o "$installer" "$CPA_INSTALLER_URL" \
        && head -c 2 "$installer" | grep -q '#!'; then
        bash "$installer" install || rc=1
    else
        rc=1
    fi
    rm -f "$installer"
    if (( rc != 0 )) || ! cpa_bin >/dev/null; then
        warn "官方安装器失败,改走 Release 直链"
        install_cpa_release || return 1
    elif [[ -x "$CPA_INSTALL_DIR/cli-proxy-api" ]]; then
        link_cpa "$CPA_INSTALL_DIR/cli-proxy-api"
    fi
    export PATH="/usr/local/bin:$HOME/.local/bin:$CPA_INSTALL_DIR:$PATH"
    cpa_bin >/dev/null || return 1
    info "登录: cpa --claude-login / --codex-login / --login"
    ok "cpa 完成"
}

install_clean() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get autoremove -y || true
    apt-get autoclean -y || true
    apt-get clean || true
    rm -f /var/cache/apt/archives/*.deb
    has_cmd npm && npm cache clean --force >/dev/null 2>&1 || true
    rm -rf /root/.npm/_cacache /root/.cache/pip /root/.cache/go-build \
           /root/.cache/gradle /root/.gradle/caches 2>/dev/null || true
    find /tmp /var/tmp -xdev -type f -mtime +2 -delete 2>/dev/null || true
    find /tmp /var/tmp -xdev -type d -empty -mtime +2 -delete 2>/dev/null || true
    df -h / | tail -1
    ok "清理完成"
}

run_one() {
    local id="$1"
    case "$id" in
        nano)       install_apt_pkg nano nano ;;
        htop)       install_apt_pkg htop htop ;;
        btop)       install_apt_pkg btop btop ;;
        screen)     install_apt_pkg screen screen ;;
        jdk)        install_jdk ;;
        gradle)     install_gradle ;;
        cmdline)    install_cmdline ;;
        adb)        install_adb ;;
        buildtools) install_buildtools ;;
        platform)   install_platform ;;
        env)        install_env ;;
        zcf)        install_npm_pkg zcf zcf zcf ;;
        claude)     install_npm_pkg claude claude @anthropic-ai/claude-code ;;
        gemini)     install_npm_pkg gemini gemini @google/gemini-cli ;;
        codex)      install_npm_pkg codex codex @openai/codex ;;
        grok)       install_grok ;;
        cpa)        install_cpa ;;
        clean)      install_clean ;;
        *)          err "未实现: $id"; return 1 ;;
    esac
}

# ---------- 界面 ----------
print_plan() {
    local id m i=1
    printf '\n将执行 \033[1m%d\033[0m 项:\n' "${#PLAN[@]}"
    for id in "${PLAN[@]+"${PLAN[@]}"}"; do
        m="$(mod_by_id "$id")"
        printf '  %2d. %-12s %-24s  状态:%s\n' \
            "$i" "$(field "$m" 3)" "$(field "$m" 4)" "$(installed_hint "$id")"
        i=$((i + 1))
    done
    printf '\n'
}

print_catalog() {
    local m id i=1 g=""
    printf '\n组件清单 (输入序号开关):\n'
    for m in "${MODULES[@]}"; do
        id="$(field "$m" 1)"
        if [[ "$(field "$m" 2)" != "$g" ]]; then
            g="$(field "$m" 2)"
            case "$g" in
                base)  printf '\n  -- 基础软件 --\n' ;;
                apk)   printf '\n  -- APK 编译 --\n' ;;
                ai)    printf '\n  -- AI CLI --\n' ;;
                maint) printf '\n  -- 维护 --\n' ;;
            esac
        fi
        printf '  %s %2d) %-16s %-22s %s\n' \
            "$(mark "$id")" "$i" "$(field "$m" 3)" "$(field "$m" 4)" "$(installed_hint "$id")"
        i=$((i + 1))
    done
    printf '\n  a 全选新机推荐   n 全不选   g1 基础 g2 APK g3 AI\n'
    printf '  c 确认开始       b 返回方案   q 退出\n'
}

custom_loop() {
    local raw i id m
    [[ ${#PLAN[@]} -eq 0 ]] && set_plan_profile custom
    while :; do
        print_catalog
        raw="$(read_tty "自定义> ")"
        printf '\n'
        case "$raw" in
            q|Q) die "已取消" ;;
            b|B) return 1 ;;
            c|C|"") return 0 ;;
            a|A) set_plan_profile new ;;
            n|N) PLAN=() ;;
            g1) PLAN=(); while read -r id; do add_plan "$id"; done < <(ids_of_group base) ;;
            g2) PLAN=(); while read -r id; do add_plan "$id"; done < <(ids_of_group apk) ;;
            g3) PLAN=(); while read -r id; do add_plan "$id"; done < <(ids_of_group ai) ;;
            *)
                for i in $raw; do
                    if [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#MODULES[@]} )); then
                        m="${MODULES[$((i - 1))]}"
                        toggle_plan "$(field "$m" 1)"
                    else
                        warn "无效输入: $i"
                    fi
                done
                ;;
        esac
    done
}

choose_profile() {
    cat <<EOF

请选择安装方案:
  1) 新机推荐     基础软件 + APK 编译 + AI CLI
  2) 仅基础软件   nano / htop / btop / screen
  3) 仅 APK 编译  JDK / Gradle / Android SDK
  4) 仅 AI CLI    zcf / claude / gemini / codex / grok / cpa
  5) 自定义勾选   逐项开关后再确认
  6) 清理缓存     不安装软件
  0) 退出

EOF
    local c
    c="$(read_tty "方案 [1]: ")"
    printf '\n'
    case "${c:-1}" in
        1) set_plan_profile new ;;
        2) set_plan_profile base ;;
        3) set_plan_profile apk ;;
        4) set_plan_profile ai ;;
        5) custom_loop || choose_profile ;;
        6) set_plan_profile clean ;;
        0|q|Q) die "已取消" ;;
        *) warn "无效选择"; choose_profile ;;
    esac
}

execute_plan() {
    local id m rc
    TOTAL_STEPS="${#PLAN[@]}"
    (( TOTAL_STEPS > 0 )) || die "没有选中任何组件"
    print_plan
    confirm "开始安装这 ${TOTAL_STEPS} 项? [Y/n] " || die "已取消"

    STEP_INDEX=0
    for id in "${PLAN[@]}"; do
        STEP_INDEX=$((STEP_INDEX + 1))
        m="$(mod_by_id "$id")"
        printf '\n\033[1m[%d/%d]\033[0m %s  (%s)\n' \
            "$STEP_INDEX" "$TOTAL_STEPS" "$(field "$m" 3)" "$(field "$m" 4)"
        log "step $STEP_INDEX/$TOTAL_STEPS $id"
        rc=0
        run_one "$id" || rc=$?
        case "$rc" in
            0)  RESULT_OK+=("$id"); log "ok $id" ;;
            10) RESULT_SKIP+=("$id"); log "skip $id" ;;
            *)  RESULT_FAIL+=("$id"); err "$id 失败 (exit $rc)"; log "fail $id rc=$rc" ;;
        esac
    done
}

print_summary() {
    printf '\n%s\n' "================ 完成 ================="
    printf '成功 %d  跳过 %d  失败 %d\n' \
        "${#RESULT_OK[@]}" "${#RESULT_SKIP[@]}" "${#RESULT_FAIL[@]}"
    (( ${#RESULT_OK[@]} )) && printf '  OK   %s\n' "${RESULT_OK[*]}"
    (( ${#RESULT_SKIP[@]} )) && printf '  SKIP %s\n' "${RESULT_SKIP[*]}"
    (( ${#RESULT_FAIL[@]} )) && printf '  FAIL %s\n' "${RESULT_FAIL[*]}"
    printf '\n当前终端可执行:  source /etc/profile.d/android.sh 2>/dev/null; hash -r\n'
    printf 'cpa 需自行登录:  cpa --claude-login / --codex-login / --login\n'
    printf '日志: %s\n' "$LOG_FILE"
    (( ${#RESULT_FAIL[@]} )) && exit 1
}

usage() {
    cat <<EOF
CommonUserScripts 新机安装引导  v${VERSION}

用法:
  bash <(curl -fsSL ${RAW_BASE}/setupv11.sh)
  bash setupv11.sh
  bash setupv11.sh --profile new
  bash setupv11.sh --yes --profile apk
  bash setupv11.sh --items nano,htop,claude,grok

选项:
  --profile new|base|apk|ai|clean|custom
  --items id,id,...     直接指定组件
  --yes                 不再确认
  --force               已装也重装
  --list                列出组件
  -h, --help

并存入口:
  v1.0  ${RAW_BASE}/setupV10.sh
  v1.1  ${RAW_BASE}/setupv11.sh
EOF
}

list_modules() {
    local m
    printf 'id            组      名称\n'
    for m in "${MODULES[@]}"; do
        printf '%-14s %-8s %s\n' "$(field "$m" 1)" "$(field "$m" 2)" "$(field "$m" 3)"
    done
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -l|--list) list_modules; exit 0 ;;
            -f|--force) FORCE=1 ;;
            -y|--yes) ASSUME_YES=1 ;;
            --profile) PROFILE="${2:-}"; shift ;;
            --items) ITEMS_ARG="${2:-}"; shift ;;
            -*) die "未知参数: $1" ;;
            *) die "未知参数: $1 (见 --help)" ;;
        esac
        shift
    done

    preflight
    if [[ -n "$ITEMS_ARG" ]]; then
        set_plan_from_ids "$ITEMS_ARG"
    elif [[ -n "$PROFILE" ]]; then
        set_plan_profile "$PROFILE"
        if [[ "$PROFILE" == custom ]] && (( ASSUME_YES == 0 )); then
            custom_loop || true
        fi
    else
        choose_profile
    fi
    execute_plan
    print_summary
}

main "$@"

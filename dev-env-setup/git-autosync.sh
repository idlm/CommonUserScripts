#!/usr/bin/env bash
#
# Git 仓库自动双向同步
#   本地变更(含删除) -> 自动提交并推送到云端
#   云端变更(含删除) -> 拉取到本地
#   两端分叉         -> 尝试 rebase 自动合并,冲突则回滚并告警
#
# 用法: bash git-autosync.sh
# 幂等,可重复执行;由 cron 周期调用
#
set -euo pipefail

# ---------- 配置 ----------
REPO_DIR="${REPO_DIR:-$PWD}"
BRANCH="${BRANCH:-main}"
REMOTE="${REMOTE:-origin}"
LOG_FILE="${LOG_FILE:-/var/log/git-autosync.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"   # 日志超过 1MB 时截断,保留后半部分
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_github}"

# 危险开关:置 1 时,rebase 冲突将丢弃本地提交强制与云端一致(不可恢复)。默认关闭。
FORCE_REMOTE_WINS="${FORCE_REMOTE_WINS:-0}"

# 敏感文件名模式:命中则拒绝提交,避免密钥被自动推送到远端
SECRET_PATTERNS='(^|/)\.env($|\.)|\.pem$|\.key$|(^|/)id_(rsa|ed25519|ecdsa)$|(^|/)\.netrc$|credentials(\.json)?$'
# ---------- 配置结束 ----------

log() {
    printf '%s [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG_FILE"
}
die() { log ERROR "$1"; exit 1; }

# 日志轮转:无人值守场景下日志会无限增长,超限只保留后半部分
rotate_log() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size="$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)"
    if (( size > LOG_MAX_BYTES )); then
        tail -c $(( LOG_MAX_BYTES / 2 )) "$LOG_FILE" >"$LOG_FILE.tmp" \
            && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# 提交前扫描:密钥一旦推到远端就进了 Git 历史,删不掉,宁可停下
check_secrets() {
    local staged hits
    staged="$(git diff --cached --name-only --diff-filter=d)"
    [[ -n "$staged" ]] || return 0
    hits="$(printf '%s\n' "$staged" | grep -Ei "$SECRET_PATTERNS" || true)"
    if [[ -n "$hits" ]]; then
        git reset -q
        die "检测到疑似密钥文件,已取消暂存并中止: $(printf '%s' "$hits" | tr '\n' ' ')"
    fi
}

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
rotate_log

# 防并发:同步耗时超过 cron 周期时,避免多实例争抢 .git 索引锁
LOCK_FILE="/tmp/git-autosync-$(printf '%s' "$REPO_DIR" | md5sum | cut -c1-8).lock"
exec 9>"$LOCK_FILE"
flock -n 9 || { log WARN "上一次同步仍在运行,本次跳过"; exit 0; }

cd "$REPO_DIR" 2>/dev/null || die "仓库目录不存在: $REPO_DIR"
git rev-parse --git-dir >/dev/null 2>&1 || die "不是 Git 仓库: $REPO_DIR"

# cron 环境无 SSH agent 且 PATH 极简,显式补齐
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
export HOME="${HOME:-/root}"
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o BatchMode=yes"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$current_branch" == "$BRANCH" ]] \
    || die "当前分支 $current_branch 与配置的 $BRANCH 不一致,中止以免误推"

# merge/rebase/cherry-pick 中间状态需人工处理,自动介入只会让局面更糟
if [[ -d "$(git rev-parse --git-path rebase-merge)" ]] \
    || [[ -d "$(git rev-parse --git-path rebase-apply)" ]] \
    || [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]] \
    || [[ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]]; then
    die "仓库处于 merge/rebase 中间状态,需人工处理后再启用同步"
fi

# --- 1. 提交本地变更。git add -A 会把删除一并记录,这是"本地删除同步到云端"的关键 ---
if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    check_secrets
    # add -A 之后索引可能与 HEAD 无差异(例如只有空目录变动,或索引残留脏状态)。
    # 此时 git commit 会失败,set -e 会让脚本静默退出且不写日志,必须显式跳过。
    if git diff --cached --quiet; then
        log INFO "索引已与 HEAD 一致,无需提交"
    else
        summary="$(git diff --cached --shortstat | sed 's/^ *//')"
        git commit -q -m "autosync: $(date '+%Y-%m-%d %H:%M:%S')" -m "${summary:-无统计信息}"
        log INFO "已提交本地变更: ${summary:-无}"
    fi
fi

# --- 2. 获取远端最新状态 ---
git fetch -q "$REMOTE" "$BRANCH" || die "fetch 失败,检查网络或 SSH 密钥 $SSH_KEY"

local_rev="$(git rev-parse HEAD)"
remote_rev="$(git rev-parse "$REMOTE/$BRANCH")"
base_rev="$(git merge-base HEAD "$REMOTE/$BRANCH")"

# --- 3. 按同步状态分四种情况处理 ---
if [[ "$local_rev" == "$remote_rev" ]]; then
    log INFO "已同步,无需操作"
    exit 0
fi

if [[ "$local_rev" == "$base_rev" ]]; then
    # 仅远端领先:快进即可,云端的删除随之落到本地
    git merge -q --ff-only "$REMOTE/$BRANCH" || die "快进合并失败"
    log INFO "已拉取云端变更 -> $(git rev-parse --short HEAD)"
    exit 0
fi

if [[ "$remote_rev" != "$base_rev" ]]; then
    # 两端分叉:先尝试 rebase 自动合并。改动落在不同文件时总能成功
    log WARN "两端分叉,尝试 rebase 自动合并"
    if ! git rebase "$REMOTE/$BRANCH" >>"$LOG_FILE" 2>&1; then
        # rebase --abort 会完整恢复到同步前状态,不丢数据
        git rebase --abort 2>/dev/null || true
        if [[ "$FORCE_REMOTE_WINS" == "1" ]]; then
            log WARN "rebase 冲突,FORCE_REMOTE_WINS=1,丢弃本地提交强制与云端一致"
            git reset -q --hard "$REMOTE/$BRANCH"
            log INFO "已强制与云端一致 -> $(git rev-parse --short HEAD)"
            exit 0
        fi
        die "rebase 冲突,已回滚到同步前状态,需人工合并后再运行"
    fi
    log INFO "rebase 合并成功"
fi

# --- 4. 本地领先(或 rebase 后领先):推送到云端 ---
git push -q "$REMOTE" "$BRANCH" || die "push 失败,检查远端权限或分支保护规则"
log INFO "已推送到云端 -> $(git rev-parse --short HEAD)"




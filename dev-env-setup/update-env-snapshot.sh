#!/usr/bin/env bash
#
# 刷新 README 运行环境快照
#   采集当前环境数据 -> 重写 README 中 SNAPSHOT 标记区块
#
# 用法: bash update-env-snapshot.sh
# 幂等,可重复执行;由 cron 每日调用
#
# 只改标记区块内的内容,标记之外的人工维护部分不受影响。
# 不自行 git 提交推送:交给 git-autosync.sh 统一处理,避免两个脚本争抢索引锁。
#
set -euo pipefail

# ---------- 配置 ----------
REPO_DIR="${REPO_DIR:-$PWD}"
README="${README:-$REPO_DIR/README.md}"
LOG_FILE="${LOG_FILE:-/var/log/env-snapshot.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"
SYNC_LOG="${SYNC_LOG:-/var/log/git-autosync.log}"
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"

BEGIN_MARK='<!-- SNAPSHOT:START -->'
END_MARK='<!-- SNAPSHOT:END -->'
# ---------- 配置结束 ----------

log() {
    printf '%s [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG_FILE"
}
die() { log ERROR "$1"; exit 1; }

rotate_log() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size="$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)"
    if (( size > LOG_MAX_BYTES )); then
        tail -c $(( LOG_MAX_BYTES / 2 )) "$LOG_FILE" >"$LOG_FILE.tmp" \
            && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

TMP_FILES=()
cleanup() {
    local f
    for f in ${TMP_FILES+"${TMP_FILES[@]}"}; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    return 0
}
trap cleanup EXIT

# 采集失败时统一填这个值,而不是留空表格或让 set -e 中断整轮采集
UNKNOWN='—'

# 单项采集失败不致命: 缺一个字段好过整份快照不更新。
# 采集表达式多含管道(cmd | grep),管道末尾命令的非 0 退出会被 set -e 捕获,
# 因此统一在这里吞掉退出码并回退到占位符。参数均为脚本内的字面量,无注入面。
val() {
    local out
    out="$(eval "$1" 2>/dev/null)" || out=''
    printf '%s' "${out:-$UNKNOWN}"
}

# 从 README 快照区块里回读某表格行的旧值(第二列)。
# 限定在标记区块内匹配,避免命中标记之外人工维护的同名表格行。
prev_row() {
    local label="$1"
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v label="$label" '
        index($0, begin) == 1 { inblock = 1; next }
        index($0, end) == 1   { inblock = 0 }
        inblock && $0 ~ ("^\\| " label " \\|") {
            sub("^\\| " label " \\| *", "")
            sub(" *\\| *$", "")
            gsub("`", "")
            print
            exit
        }
    ' "$README"
}

# 回读上一次的采集时间戳(> 采集时间:**...** 那一行)
prev_snap_time() {
    awk -v begin="$BEGIN_MARK" '
        index($0, begin) == 1 { inblock = 1; next }
        inblock && /^> 采集时间/ {
            if (match($0, /\*\*[^*]+\*\*/)) print substr($0, RSTART + 2, RLENGTH - 4)
            exit
        }
    ' "$README"
}

# 网络与日志类字段采集失败时,保留 README 中上次的有效值。
# 这类字段网络抖一下就采不到,写占位符等于用坏数据盖掉好数据;
# 版本号、内核这些本地字段则相反,采不到就该显式暴露,所以不走这个回退。
# 用法: fallback_prev <变量名> <表格行标签>
DEGRADED=0
fallback_prev() {
    local -n ref="$1"
    local label="$2" prev
    [[ "$ref" == "$UNKNOWN" ]] || return 0
    DEGRADED=1
    prev="$(prev_row "$label")"
    if [[ -n "$prev" && "$prev" != "$UNKNOWN" ]]; then
        ref="$prev"
        log WARN "$label 采集失败,保留上次值: $prev"
    else
        log WARN "$label 采集失败,且无上次值可用"
    fi
}

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
rotate_log

# 防并发:与自身的上一轮互斥
LOCK_FILE="/tmp/env-snapshot-$(printf '%s' "$README" | md5sum | cut -c1-8).lock"
exec 9>"$LOCK_FILE"
flock -n 9 || { log WARN "上一次采集仍在运行,本次跳过"; exit 0; }

[[ -f "$README" ]] || die "README 不存在: $README"
grep -qF "$BEGIN_MARK" "$README" || die "未找到起始标记 $BEGIN_MARK,请先在 README 中放置标记"
grep -qF "$END_MARK" "$README" || die "未找到结束标记 $END_MARK"

# cron 的 PATH 极简,go/node 等不在其中,显式补齐否则版本列会采成占位符
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/go/bin:/go/bin:$PATH"

# ---------- 采集 ----------
snap_time="$(date '+%F %H:%M %z' | sed 's/+0800/+08/')"
tz_name="$(val 'cat /etc/timezone')"
tz_link="$(val 'readlink -f /etc/localtime')"
tz_offset="$(date '+%z')"
# uptime -p 的措辞随 locale 变化,cron 下是英文。直接读 /proc/uptime 自行格式化,输出稳定
uptime_h="$(val 'awk "{d=int(\$1/86400); h=int((\$1%86400)/3600); m=int((\$1%3600)/60);
    printf \"%d 天 %d 小时 %d 分\", d, h, m}" /proc/uptime')"

distro="$(val 'grep -oP "(?<=^PRETTY_NAME=\").*(?=\")" /etc/os-release')"
kernel="$(val 'uname -r')"
arch="$(val 'uname -m')"
host="$(val 'hostname')"
# /proc/1/comm 被内核截断到 15 字符(firecracker-init -> firecracker-ini),取 cmdline 拿全名
init_proc="$(val 'tr "\0" "\n" < /proc/1/cmdline | head -1 | xargs -r basename')"

cpu_model="$(val 'grep -m1 -oP "(?<=model name\t: ).*" /proc/cpuinfo')"
cpu_cores="$(val 'nproc')"
# 不加 --si: 保持 GiB/MiB 二进制单位,与 df 的 -h 口径一致
mem_total="$(val 'free -h | awk "/^Mem:/{print \$2}"')"
mem_used="$(val 'free -h | awk "/^Mem:/{print \$3}"')"
mem_avail="$(val 'free -h | awk "/^Mem:/{print \$7}"')"
disk_size="$(val 'df -h --output=size / | tail -1 | tr -d " "')"
disk_used="$(val 'df -h --output=used / | tail -1 | tr -d " "')"
disk_pct="$(val 'df -h --output=pcent / | tail -1 | tr -d " "')"

jdk_ver="$(val 'java -version 2>&1 | grep -oP "(?<=version \")[^\"]+"')"
gradle_ver="$(val '/opt/gradle-8.7/bin/gradle -v | grep -oP "(?<=^Gradle ).*"')"
sdk_bt="$(val 'ls /opt/android-sdk/build-tools | tr "\n" " " | sed "s/ $//"')"
adb_ver="$(val '/opt/android-sdk/platform-tools/adb version | grep -oP "(?<=version ).*" | head -1')"
go_ver="$(val 'go version | grep -oP "(?<=go)[0-9.]+(?= )"')"
node_ver="$(val 'node -v')"
npm_ver="$(val 'npm -v')"
py_ver="$(val 'python3 -V | grep -oP "(?<=Python ).*"')"
git_ver="$(val 'git --version | grep -oP "(?<=version ).*"')"
bash_ver="$(val 'bash --version | head -1 | grep -oP "(?<=version )[^ ]+"')"

ip_abroad="$(val 'curl -fsSL --max-time '"$CURL_TIMEOUT"' https://api.ipify.org | tr -d "\r"')"
ip_cn="$(val 'curl -fsSL --max-time '"$CURL_TIMEOUT"' https://cip.cc | grep -oP "(?<=^IP\t: ).*" | head -1')"

lan_addr="$(val 'ip -4 -o addr show dev eth0 | awk "{print \$4}" | grep -v "^169\.254" | head -1')"
gateway="$(val 'ip route | grep -oP "(?<=^default via )[0-9.]+" | head -1')"

if pgrep -x cron >/dev/null 2>&1; then
    cron_state='运行中'
else
    cron_state='**未运行**(需手动 `cron` 拉起)'
fi

last_sync="$(val 'grep -E "\[(INFO |WARN |ERROR)" '"$SYNC_LOG"' | tail -1')"

# ---------- 降级处理 ----------
# 网络类与日志类字段失败时回退到上次值,并标记本轮为降级采集
fallback_prev ip_abroad '境外出口'
fallback_prev ip_cn '境内出口'
fallback_prev last_sync '最近同步'

# 出口探测失败时时间戳也保留原值,否则会呈现"时间是新的、数据是旧的"误导
if (( DEGRADED )); then
    prev_time="$(prev_snap_time)"
    if [[ -n "$prev_time" ]]; then
        snap_time="$prev_time"
        log WARN "本轮为降级采集,采集时间保留为 $prev_time"
    fi
fi

# ---------- 渲染 ----------
BODY="$(mktemp)"; TMP_FILES+=("$BODY")
cat >"$BODY" <<EOF
$BEGIN_MARK
> 采集时间:**$snap_time**($tz_name)

### 时间与时区

| 项目 | 值 |
| --- | --- |
| 时区 | $tz_name(UTC+8,\`$tz_offset\`) |
| 时区配置 | \`/etc/localtime\` → \`$tz_link\` |
| 系统运行时长 | $uptime_h |

### 系统

| 项目 | 值 |
| --- | --- |
| 发行版 | $distro |
| 内核 | $kernel |
| 架构 | $arch |
| 主机名 | \`$host\` |
| Init 进程 | \`$init_proc\` |

### 硬件资源

| 项目 | 值 |
| --- | --- |
| CPU | $cpu_model × $cpu_cores |
| 内存 | $mem_total(已用 $mem_used / 可用 $mem_avail) |
| 磁盘 | $disk_size(已用 $disk_used,占用 $disk_pct) |

### 开发环境

| 组件 | 版本 | 路径 |
| --- | --- | --- |
| OpenJDK | $jdk_ver | 系统默认 |
| Gradle | $gradle_ver | \`/opt/gradle-8.7/bin\` |
| Android SDK | build-tools $sdk_bt / platform android-34 | \`/opt/android-sdk\` |
| adb | $adb_ver | \`/opt/android-sdk/platform-tools\` |
| Go | $go_ver | \`/go\` |
| Node.js | $node_ver | 系统默认 |
| npm | $npm_ver | 系统默认 |
| Python | $py_ver | 系统默认 |
| Git | $git_ver | 系统默认 |
| Bash | $bash_ver | \`/usr/bin/bash\` |

Gradle 与 Android SDK 的 PATH 由 \`/etc/profile.d/android.sh\` 注入,只在登录 shell 生效。cron、\`bash -c\`、CI 等非登录环境下 \`gradle\`/\`adb\` 不在 PATH 中,需用绝对路径或先 \`source /etc/profile.d/android.sh\`。

### 当前出口与同步状态

| 项目 | 值 |
| --- | --- |
| 境外出口 | \`$ip_abroad\` |
| 境内出口 | \`$ip_cn\` |
| 内网地址 | \`$lan_addr\`(eth0),网关 \`$gateway\` |
| cron 进程 | $cron_state |
| 最近同步 | $last_sync |

$END_MARK
EOF

# 用 awk 做区块替换: sed 处理多行插入需要转义正文里的 & 和反斜杠,awk 逐行判断更稳
OUT="$(mktemp)"; TMP_FILES+=("$OUT")
awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v bodyfile="$BODY" '
    index($0, begin) == 1 && !done {
        while ((getline line < bodyfile) > 0) print line
        close(bodyfile)
        skip = 1; done = 1; next
    }
    skip && index($0, end) == 1 { skip = 0; next }
    !skip { print }
' "$README" >"$OUT"

[[ -s "$OUT" ]] || die "渲染结果为空,已放弃写入"
grep -qF "$BEGIN_MARK" "$OUT" || die "渲染后丢失标记,已放弃写入"
grep -qF "$END_MARK" "$OUT" || die "渲染后丢失结束标记,已放弃写入"

if cmp -s "$README" "$OUT"; then
    log INFO "环境数据无变化,未改动文件"
    exit 0
fi

cat "$OUT" >"$README"
if (( DEGRADED )); then
    log WARN "已更新快照(降级): 境外 $ip_abroad / 内存可用 $mem_avail / 磁盘 $disk_pct"
else
    log INFO "已更新快照: 境外 $ip_abroad / 内存可用 $mem_avail / 磁盘 $disk_pct"
fi

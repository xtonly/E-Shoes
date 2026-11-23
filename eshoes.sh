#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ======================================================================
# E-Shoes 代理节点一键管理脚本 (v4.6.1 — 深度适配 Shoes v0.3.8+)
# 修复：GitHub 最新版本号探测移除致命 -I (HEAD) 请求，改用零限流 302 Location 提取 + 双栈/镜像多级兜底
# 修复：SS-2022 128-GCM (16B) 与 256-GCM (32B) 密钥长度自适应校验
# 强化：无损原子更新核心 (沙盒预检 --version 与 --dry-run 通过才替换，清理 licenses/ 残留)
# 修复：订阅链接节点名称标准 URL 编码 + 国旗 Emoji 4字节终端列宽精准对齐
# 修复：独立 98-shoes 系统调优配置，卸载时绝不误伤全局 BBR 配置 + 锁定 bindv6only=0
# 适配：Shoes v0.3.8 TLS SNI 规范化 (剥离末尾点号与非法纯十六进制后缀)
# ======================================================================

# ================== 颜色代码与风格统一 ==================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
RESET='\033[0m'

LINE_HEAVY="${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
LINE_LIGHT="${GRAY}───────────────────────────────────────────────────────────────────${RESET}"

# ================== 常量定义 ==================
SHOES_BIN="/usr/local/bin/shoes"
SHOES_CONF_DIR="/etc/shoes"
SHOES_CONF_FILE="${SHOES_CONF_DIR}/config.yaml"
SHOES_LINK_FILE="${SHOES_CONF_DIR}/config.txt"
SHOES_ENV_FILE="${SHOES_CONF_DIR}/.env"
SYSTEMD_FILE="/etc/systemd/system/shoes.service"
IP_SYNC_BIN="/usr/local/bin/shoes-ip-sync"
IP_SYNC_SERVICE="/etc/systemd/system/shoes-ip-sync.service"
IP_SYNC_TIMER="/etc/systemd/system/shoes-ip-sync.timer"
LIMITS_CONF="/etc/security/limits.d/98-shoes-limits.conf"
SYSCTL_CONF="/etc/sysctl.d/98-shoes-tuning.conf"
SCRIPT_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
TMP_DIR="/tmp/shoesdl"
GH_DL_PREFIX="https://github.com"

# 默认 SS-2022 算法 (兼容外部 sed 替换为 2022-blake3-aes-128-gcm)
DEFAULT_SS_METHOD="2022-blake3-aes-256-gcm"

# 动态 IP 面板状态缓存变量
SYNC_V4_CHANGED=0
SYNC_V4_OLD=""
SYNC_V6_CHANGED=0
SYNC_V6_OLD=""
CACHED_LIVE_V4=""
CACHED_LIVE_V6=""

# 端口范围常量：严格限制在 20300 之后 (20301 - 60000)
PORT_MIN=20301
PORT_MAX=60000

# ================== Root 与基础依赖检查 ==================
require_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}错误：请使用 root 用户运行此脚本${RESET}"; exit 1; }
}

ensure_base_deps() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v wget >/dev/null 2>&1 || missing+=("wget")
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    if (( ${#missing[@]} > 0 )); then
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >/dev/null 2>&1 && apt-get install -y "${missing[@]}" ca-certificates >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing[@]}" ca-certificates >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache "${missing[@]}" ca-certificates >/dev/null 2>&1
        fi
    fi
}

# ================== 辅助与编码排版函数 ==================
check_installed() { [[ -f "$SHOES_BIN" ]] && [[ -f "$SYSTEMD_FILE" ]]; }
check_running() { systemctl is-active --quiet shoes; }

get_local_version() {
    if [[ -x "$SHOES_BIN" ]]; then
        local ver
        ver=$("$SHOES_BIN" --version 2>/dev/null | awk 'NR==1 {sub(/^v/, "", $2); print $2}')
        [[ -n "$ver" ]] && echo "v${ver}" || echo "未知"
    else
        echo "未安装"
    fi
}

# 纯 Bash URI 编码 (保留安全 ASCII 字符，将中文/Emoji/空格转为 %XX，确保全客户端订阅兼容)
urlencode() {
    local LC_ALL=C
    local str="$1"
    local i c hex
    local out=""
    for (( i=0; i<${#str}; i++ )); do
        c="${str:i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out+="$c" ;;
            *)
                printf -v hex '%%%02X' "'$c"
                out+="$hex"
                ;;
        esac
    done
    printf "%s" "$out"
}

# 根据 SS-2022 算法精准生成并校验对应字节长度的 Base64 密钥 (兼容 128-gcm=16B 与 256-gcm=32B)
generate_ss2022_key() {
    local cipher="$1"
    local key_bytes=32
    local expected_len=44
    if [[ "$cipher" == *"128"* ]]; then
        key_bytes=16
        expected_len=24
    fi

    local pw=""
    if [[ -x "${SHOES_BIN}" ]]; then
        pw=$("${SHOES_BIN}" generate-shadowsocks-2022-password --cipher "${cipher}" 2>/dev/null | tail -n 1 | awk '{print $NF}' | tr -d '\r\n[:space:]')
    fi
    if [[ ${#pw} -ne $expected_len ]]; then
        pw=$(openssl rand -base64 "$key_bytes" | tr -d '\r\n[:space:]')
    fi
    echo "$pw"
}

# 校验现有密钥长度是否匹配当前 SS-2022 算法
is_valid_ss2022_key() {
    local cipher="$1"
    local pw="$2"
    if [[ "$cipher" == *"128"* ]]; then
        [[ ${#pw} -eq 24 ]]
    else
        [[ ${#pw} -eq 44 ]]
    fi
}

# 计算包含 ANSI 颜色、CJK 汉字及 4 字节国旗/Emoji 的真实终端显示列宽
str_display_width() {
    local s clean_sym ascii_str non_ascii rem_chars rem_bytes
    s=$(printf "%b" "$1" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    # 将单宽度的制表/状态符号归一为单字节 X
    clean_sym=$(printf "%s" "$s" | sed 's/[●○✔→—─━│╭╮╰╯├┤┬┴┼]/X/g')

    # 若系统存在 wc -L 且当前 locale 支持 UTF-8，优先用结合补偿算法精确计算
    ascii_str=$(LC_ALL=C printf "%s" "$clean_sym" | tr -cd '\000-\177')
    local ascii_len=${#ascii_str}
    non_ascii=$(LC_ALL=C printf "%s" "$clean_sym" | tr -d '\000-\177')
    if [[ -z "$non_ascii" ]]; then
        echo "$ascii_len"
        return
    fi

    # 区分 3 字节 CJK (每字符占 2 列) 与 4 字节 Emoji/区域指示符 (国旗由 2 个 4 字节 RIS 组成共占 2 列，普通 Emoji 1 个 4 字节占 2 列)
    rem_chars=${#non_ascii}
    rem_bytes=$(LC_ALL=C printf "%s" "$non_ascii" | wc -c)
    # 估算 4 字节字符个数: total_bytes = 3*cjk + 4*emoji4, total_chars = cjk + emoji4 => emoji4 = rem_bytes - 3*rem_chars
    local emoji4=$(( rem_bytes - 3 * rem_chars ))
    (( emoji4 < 0 )) && emoji4=0
    local cjk=$(( rem_chars - emoji4 ))
    (( cjk < 0 )) && cjk=0

    # 国旗由成对 Regional Indicator 组成，若存在偶数个 4 字节且含国旗组合则折算显示列宽
    local wide_cols=$(( cjk * 2 + emoji4 * 2 ))
    if command -v python3 >/dev/null 2>&1 && (( emoji4 > 0 )); then
        local py_w
        py_w=$(python3 - "$clean_sym" <<'PY' 2>/dev/null
import sys, unicodedata
s = sys.argv[1]
w, i, n = 0, 0, len(s)
while i < n:
    cp = ord(s[i])
    if 0x1F1E6 <= cp <= 0x1F1FF and i + 1 < n and 0x1F1E6 <= ord(s[i+1]) <= 0x1F1FF:
        w += 2; i += 2; continue
    if cp in (0x200D, 0xFE0F):
        i += 1; continue
    eaw = unicodedata.east_asian_width(s[i])
    w += 2 if eaw in ('W', 'F') or cp >= 0x1F300 else 1
    i += 1
print(w)
PY
)
        if [[ "$py_w" =~ ^[0-9]+$ ]]; then
            echo "$py_w"
            return
        fi
    fi
    echo $(( ascii_len + wide_cols ))
}

# 按指定终端列宽填充单元格
pad_cell() {
    local text="$1"
    local target_w="$2"
    local w pad
    w=$(str_display_width "$text")
    pad=$(( target_w - w ))
    (( pad < 0 )) && pad=0
    printf "%b%*s" "$text" "$pad" ""
}

# 双栏状态行输出
print_kv_2col() {
    local left
    left=$(pad_cell "$1" 29)
    echo -e "  ${left}  ${GRAY}│${RESET}  $2"
}

# 3列表格行输出 (总宽 67 列)
print_ip_table_row() {
    local c1 c2 c3
    c1=$(pad_cell "$1" 8)
    c2=$(pad_cell "$2" 23)
    c3=$(pad_cell "$3" 24)
    echo -e "  ${GRAY}│${RESET} ${c1} ${GRAY}│${RESET} ${c2} ${GRAY}│${RESET} ${c3} ${GRAY}│${RESET}"
}

# 优雅缩写超长文本 / DDNS 域名 / IPv6 地址以适配表格列宽
shorten_middle() {
    local str="$1"
    local max_len="${2:-22}"
    [[ -z "$str" ]] && { echo ""; return; }
    if (( $(str_display_width "$str") <= max_len )); then
        echo "$str"
    else
        local half=$(( (max_len - 2) / 2 ))
        (( half < 2 )) && half=2
        echo "${str:0:$half}..${str: -$half}"
    fi
}

format_ipv6_short() {
    local ip="$1"
    local max_len="${2:-22}"
    [[ -z "$ip" ]] && { echo ""; return; }
    if (( ${#ip} <= max_len )); then
        echo "$ip"
    else
        local h t
        h=$(echo "$ip" | awk -F: '{print $1":"$2}')
        t=$(echo "$ip" | awk -F: '{print $(NF-1)":"$NF}')
        h="${h%:}"
        t="${t#:}"
        local res="${h}:..:${t}"
        if (( ${#res} > max_len )); then
            shorten_middle "$ip" "$max_len"
        else
            echo "$res"
        fi
    fi
}

compact_old_ipv4() {
    local old="$1"
    local new="$2"
    [[ -z "$old" ]] && { echo "首次记录"; return; }
    local o1 o2 o3 o4 n1 n2 n3 n4
    IFS='.' read -r o1 o2 o3 o4 <<< "$old"
    IFS='.' read -r n1 n2 n3 n4 <<< "$new"
    if [[ "$o1.$o2" == "$n1.$n2" ]]; then
        echo "原 .${o3}.${o4}"
    elif (( ${#old} <= 11 )); then
        echo "原 ${old}"
    else
        echo "原 ..${o3}.${o4}"
    fi
}

compact_old_ipv6() {
    local old="$1"
    [[ -z "$old" ]] && { echo "新分配"; return; }
    local t
    t=$(echo "$old" | awk -F: '{print $NF}')
    [[ -z "$t" ]] && t="0"
    echo "原 ..:${t:0:6}"
}

# 规范化并校验 TLS SNI 域名 (适配 Shoes v0.3.8: 去末尾点号，拒绝纯十六进制数字顶级域)
normalize_and_validate_sni() {
    local raw="$1"
    local cleaned
    cleaned=$(echo "$raw" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##; s#:[0-9]+$##; s#\.*$##')
    [[ -z "$cleaned" ]] && return 1
    # 必须包含点号且符合标准域名字符
    [[ "$cleaned" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z0-9-]+$ ]] || return 1
    # 拒绝纯数字或 0x 十六进制结尾的顶级标签 (v0.3.8 强制拒绝)
    local final_label="${cleaned##*.}"
    if [[ "$final_label" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then
        return 1
    fi
    echo "$cleaned"
    return 0
}

# 检测端口是否被系统占用
is_port_used() {
    local port="$1"
    ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":${port}$"
}

# 在 20301-60000 范围内获取未占用的随机端口
pick_random_port() {
    local rand_p
    while true; do
        rand_p=$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)
        if ! is_port_used "$rand_p"; then
            echo "$rand_p"
            return
        fi
    done
}

# 为 VLESS 优先挑选 20300 之后的类 HTTPS 尾号端口，若均被占用则回退随机端口
pick_vless_port() {
    local alt_ports=(20443 21443 22443 23443 24443 25443 28443 30443 38443 44443 58443)
    local shuffled=($(shuf -e "${alt_ports[@]}"))
    for p in "${shuffled[@]}"; do
        if ! is_port_used "$p"; then
            echo "$p"
            return
        fi
    done
    pick_random_port
}

# ================== 增强型智能防火墙探测与自动放行模块 ==================
detect_firewall() {
    if command -v ufw >/dev/null 2>&1; then
        if LANG=C ufw status 2>/dev/null | grep -qiE "Status:\s*active" || \
           ufw status 2>/dev/null | grep -qE "激活|active" || \
           grep -qi "^ENABLED=yes" /etc/ufw/ufw.conf 2>/dev/null; then
            echo "ufw"
            return
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null || firewall-cmd --state >/dev/null 2>&1; then
            echo "firewalld"
            return
        fi
    fi

    if command -v nft >/dev/null 2>&1; then
        local nft_rules
        nft_rules=$(nft list ruleset 2>/dev/null)
        if [[ -n "$nft_rules" ]] && echo "$nft_rules" | grep -q "hook input"; then
            if systemctl is-active --quiet nftables 2>/dev/null || \
               echo "$nft_rules" | grep -qiE "policy drop|policy reject|drop|reject"; then
                if ! command -v iptables >/dev/null 2>&1 || systemctl is-active --quiet nftables 2>/dev/null; then
                    echo "nftables"
                    return
                fi
            fi
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        if iptables -S 2>/dev/null | grep -qE "^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)|-j InstanceServices" || \
           systemctl is-active --quiet netfilter-persistent 2>/dev/null || \
           systemctl is-active --quiet iptables 2>/dev/null || \
           [[ -s /etc/iptables/rules.v4 ]] || [[ -s /etc/sysconfig/iptables ]]; then
            echo "iptables"
            return
        fi
    fi

    if command -v nft >/dev/null 2>&1; then
        if nft list ruleset 2>/dev/null | grep -q "hook input"; then
            echo "nftables"
            return
        fi
    fi

    echo "none"
}

fw_open_port() {
    local port="$1"
    local fw_type="$2"
    [[ -z "$port" ]] && return

    case "$fw_type" in
        ufw)
            ufw allow "${port}/tcp" comment 'Shoes-Proxy' >/dev/null 2>&1
            ufw allow "${port}/udp" comment 'Shoes-Proxy' >/dev/null 2>&1
            ;;
        firewalld)
            firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1
            firewall-cmd --zone=public --add-port="${port}/udp" --permanent >/dev/null 2>&1
            ;;
        nftables)
            local nft_info
            nft_info=$(nft list ruleset 2>/dev/null | awk '/^table /{f=$2; t=$3} /hook input/{print f, t; exit}')
            if [[ -n "$nft_info" ]]; then
                local fam=$(echo "$nft_info" | awk '{print $1}')
                local tab=$(echo "$nft_info" | awk '{print $2}')
                local chn=$(nft list table "$fam" "$tab" 2>/dev/null | awk '/chain /{c=$2} /hook input/{print c; exit}')
                [[ -z "$chn" ]] && chn="input"
                nft insert rule "$fam" "$tab" "$chn" tcp dport "$port" counter accept comment \"Shoes-Proxy\" >/dev/null 2>&1
                nft insert rule "$fam" "$tab" "$chn" udp dport "$port" counter accept comment \"Shoes-Proxy\" >/dev/null 2>&1
            fi
            ;;
        iptables)
            for cmd in iptables ip6tables; do
                if command -v "$cmd" >/dev/null 2>&1; then
                    "$cmd" -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || "$cmd" -I INPUT 1 -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
                    "$cmd" -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || "$cmd" -I INPUT 1 -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
                fi
            done
            ;;
    esac
}

fw_close_port() {
    local port="$1"
    local fw_type="$2"
    [[ -z "$port" ]] && return

    case "$fw_type" in
        ufw)
            ufw delete allow "${port}/tcp" >/dev/null 2>&1
            ufw delete allow "${port}/udp" >/dev/null 2>&1
            ;;
        firewalld)
            firewall-cmd --zone=public --remove-port="${port}/tcp" --permanent >/dev/null 2>&1
            firewall-cmd --zone=public --remove-port="${port}/udp" --permanent >/dev/null 2>&1
            ;;
        nftables)
            local nft_info
            nft_info=$(nft list ruleset 2>/dev/null | awk '/^table /{f=$2; t=$3} /hook input/{print f, t; exit}')
            if [[ -n "$nft_info" ]]; then
                local fam=$(echo "$nft_info" | awk '{print $1}')
                local tab=$(echo "$nft_info" | awk '{print $2}')
                local chn=$(nft list table "$fam" "$tab" 2>/dev/null | awk '/chain /{c=$2} /hook input/{print c; exit}')
                [[ -z "$chn" ]] && chn="input"
                local handles
                handles=$(nft -a list chain "$fam" "$tab" "$chn" 2>/dev/null | grep -E "dport ${port} .*Shoes-Proxy" | awk '{print $NF}')
                for h in $handles; do
                    nft delete rule "$fam" "$tab" "$chn" handle "$h" >/dev/null 2>&1
                done
            fi
            ;;
        iptables)
            for cmd in iptables ip6tables; do
                if command -v "$cmd" >/dev/null 2>&1; then
                    while "$cmd" -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do
                        "$cmd" -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
                    done
                    while "$cmd" -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; do
                        "$cmd" -D INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
                    done
                fi
            done
            ;;
    esac
}

fw_reload_save() {
    local fw_type="$1"
    case "$fw_type" in
        ufw)
            ufw reload >/dev/null 2>&1
            ;;
        firewalld)
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        nftables)
            if [[ -w /etc/nftables.conf ]] && systemctl is-active --quiet nftables 2>/dev/null; then
                nft list ruleset > /etc/nftables.conf 2>/dev/null
            fi
            ;;
        iptables)
            command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
            command -v service >/dev/null 2>&1 && service iptables save >/dev/null 2>&1
            if [[ -d /etc/iptables ]]; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
                command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
            fi
            ;;
    esac
}

sync_firewall_ports() {
    local old_ss="$1"
    local old_vless="$2"
    local old_anytls="$3"

    echo -e "${YELLOW}--> 正在探测本机防火墙状态...${RESET}"
    local fw_type
    fw_type=$(detect_firewall)

    if [[ "$fw_type" == "none" ]]; then
        echo -e "${GREEN}未检测到启用中的拦截型防火墙 (默认策略为全放行)。${RESET}"
        if command -v iptables >/dev/null 2>&1; then
            fw_open_port "$SS_PORT" "iptables"
            fw_open_port "$VLESS_PORT" "iptables"
            fw_open_port "$ANYTLS_PORT" "iptables"
            echo -e "${CYAN}--> 已通过 iptables 写入底层端口放行规则 (${SS_PORT}, ${VLESS_PORT}, ${ANYTLS_PORT})${RESET}"
        fi
        return
    fi

    echo -e "${CYAN}--> 检测到活动防火墙: [${fw_type}]，正在同步节点端口放行规则...${RESET}"

    for old_p in "$old_ss" "$old_vless" "$old_anytls"; do
        if [[ -n "$old_p" ]] && [[ "$old_p" != "$SS_PORT" ]] && [[ "$old_p" != "$VLESS_PORT" ]] && [[ "$old_p" != "$ANYTLS_PORT" ]]; then
            fw_close_port "$old_p" "$fw_type"
            echo -e "  - 已移除旧端口防火墙放行规则: ${YELLOW}${old_p}${RESET} (TCP/UDP)"
        fi
    done

    for new_p in "$SS_PORT" "$VLESS_PORT" "$ANYTLS_PORT"; do
        fw_open_port "$new_p" "$fw_type"
    done

    fw_reload_save "$fw_type"
    echo -e "${GREEN}防火墙 (${fw_type}) 已成功放行端口: ${SS_PORT}, ${VLESS_PORT}, ${ANYTLS_PORT} (TCP/UDP)${RESET}"
}

# === 强制系统时间同步 ===
sync_system_time() {
    echo -e "${YELLOW}--> 正在强制同步服务器时间 (SS-2022 要求时间误差 <30 秒)...${RESET}"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true >/dev/null 2>&1
    fi
    if command -v apt-get >/dev/null 2>&1 && ! command -v chronyc >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y chrony >/dev/null 2>&1
    fi
    systemctl restart chronyd >/dev/null 2>&1 || systemctl restart chrony >/dev/null 2>&1 || true
    command -v chronyc >/dev/null 2>&1 && chronyc makestep >/dev/null 2>&1 || true
    echo -e "${GREEN}时间同步完成，当前服务器时间: $(date)${RESET}"
}

# === 加固版智能动态公网 IP 获取 ===
get_public_ipv4() {
    local ip=""
    local urls=(
        "https://api-ipv4.ip.sb/ip"
        "http://ip.sb"
        "https://4.ipw.cn"
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "http://checkip.amazonaws.com"
        "http://ifconfig.me/ip"
    )
    for url in "${urls[@]}"; do
        ip=$(curl -fsSL -4 -A "Mozilla/5.0" --connect-timeout 3 --max-time 5 -H "Cache-Control: no-cache" "$url" 2>/dev/null | tr -d '\r\n[:space:]')
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
}

get_public_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep -q "inet6" || { echo ""; return 0; }
    local ip=""
    local urls=(
        "https://api-ipv6.ip.sb/ip"
        "https://6.ipw.cn"
        "https://v6.ident.me"
        "https://ipv6.icanhazip.com"
        "https://api6.ipify.org"
    )
    for url in "${urls[@]}"; do
        ip=$(curl -fsSL -6 -A "Mozilla/5.0" --connect-timeout 3 --max-time 4 -H "Cache-Control: no-cache" "$url" 2>/dev/null | tr -d '\r\n[:space:]')
        if [[ "$ip" == *":"* ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
}

extract_link_ipv4() {
    [[ -f "${SHOES_LINK_FILE}" ]] && grep -oE '@([0-9]{1,3}\.){3}[0-9]{1,3}:' "${SHOES_LINK_FILE}" 2>/dev/null | head -n 1 | tr -d '@:' || echo ""
}

extract_link_ipv6() {
    [[ -f "${SHOES_LINK_FILE}" ]] && grep -oE '@\[[0-9a-fA-F:]+\]:' "${SHOES_LINK_FILE}" 2>/dev/null | head -n 1 | tr -d '@[]:' || echo ""
}

save_env_file() {
    mkdir -p "${SHOES_CONF_DIR}"
    cat > "${SHOES_ENV_FILE}" <<EOF
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHID="${SHID}"
SS_METHOD="${SS_METHOD}"
SS_PASSWORD="${SS_PASSWORD}"
VLESS_PORT="${VLESS_PORT}"
ANYTLS_PORT="${ANYTLS_PORT}"
SS_PORT="${SS_PORT}"
HOST_NAME="${HOST_NAME}"
SNI="${SNI}"
ANYTLS_SNI="${ANYTLS_SNI}"
CONNECT_HOST="${CONNECT_HOST}"
LAST_IPV4="${LAST_IPV4}"
LAST_IPV6="${LAST_IPV6}"
EOF
    chmod 600 "${SHOES_ENV_FILE}" 2>/dev/null || true
}

# ================== 配置文件写入函数 ==================
write_shoes_configs() {
    save_env_file

    # 严谨检测内核 IPv6 协议栈是否启用，并强制确保双栈套接字同时监听 IPv4+IPv6 (bindv6only=0)
    if [[ -f /proc/net/if_inet6 ]] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]; then
        sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
        BIND_ADDR="[::]"
    else
        BIND_ADDR="0.0.0.0"
    fi

    cat > "${SHOES_CONF_FILE}" <<EOF
- address: "${BIND_ADDR}:${SS_PORT}"
  protocol:
    type: shadowsocks
    cipher: "${SS_METHOD}"
    password: "${SS_PASSWORD}"
    udp_enabled: true

- address: "${BIND_ADDR}:${VLESS_PORT}"
  protocol:
    type: tls
    reality_targets:
      "${SNI}":
        private_key: "${PRIVATE_KEY}"
        short_ids: ["${SHID}"]
        dest: "${SNI}:443"
        vision: true
        protocol:
          type: vless
          user_id: "${UUID}"
          udp_enabled: true

- address: "${BIND_ADDR}:${ANYTLS_PORT}"
  protocol:
    type: tls
    tls_targets:
      "${ANYTLS_SNI}":
        cert: "${SHOES_CONF_DIR}/cert.pem"
        key: "${SHOES_CONF_DIR}/key.pem"
        protocol:
          type: anytls
          users:
            - name: anytls
              password: "${PUBLIC_KEY}"
          udp_enabled: true
EOF
}

# ================== 节点链接生成函数 (支持 URL 编码、动态 IP 与 DDNS) ==================
generate_links() {
    local quiet_mode="$1"
    local live_v4="$2"
    local live_v6="$3"
    local target_host

    [[ -z "$live_v4" ]] && live_v4=$(get_public_ipv4)
    [[ -z "$live_v6" ]] && live_v6=$(get_public_ipv6)
    CACHED_LIVE_V4="$live_v4"
    CACHED_LIVE_V6="$live_v6"

    if [[ -n "$live_v4" ]]; then
        LAST_IPV4="$live_v4"
        [[ "$quiet_mode" != "quiet" ]] && echo -e "${GREEN}成功获取最新公网 IPv4: ${LAST_IPV4}${RESET}"
    else
        [[ "$quiet_mode" != "quiet" ]] && echo -e "${RED}警告：无法探测公网 IPv4，将使用缓存或占位符。${RESET}"
    fi

    if [[ -n "$live_v6" ]]; then
        LAST_IPV6="$live_v6"
        [[ "$quiet_mode" != "quiet" ]] && echo -e "${GREEN}成功获取最新公网 IPv6: ${LAST_IPV6}${RESET} (仅用于 SS2022 置顶节点)"
    else
        LAST_IPV6=""
    fi

    if [[ -n "$CONNECT_HOST" ]]; then
        target_host="$CONNECT_HOST"
        [[ "$quiet_mode" != "quiet" ]] && echo -e "${CYAN}当前节点连接地址使用自定义域名/IP: ${target_host}${RESET}"
    else
        target_host="${LAST_IPV4:-YOUR_IPV4_HERE}"
    fi

    [[ -f "${SHOES_ENV_FILE}" ]] && save_env_file

    SS_LINK_BASE=$(echo -n "${SS_METHOD}:${SS_PASSWORD}" | base64 -w 0 | tr -d '\n')

    # 对节点备注名称做标准 URL 编码，确保包含 Emoji/中文/空格时在所有订阅转换器与客户端中不丢字
    local tag_ss tag_ss_v6 tag_reality tag_anytls
    tag_ss=$(urlencode "${HOST_NAME}-SS")
    tag_ss_v6=$(urlencode "${HOST_NAME}-SS-V6")
    tag_reality=$(urlencode "${HOST_NAME}-Reality")
    tag_anytls=$(urlencode "${HOST_NAME}-AnyTLS")

    # 1. 置顶输出 Shadowsocks-2022 (支持 IPv4/DDNS & IPv6)
    cat > "${SHOES_LINK_FILE}" <<EOF
# ==================== [置顶] Shadowsocks-2022 (${SS_METHOD}) ====================
# SS2022 (IPv4) — ${HOST_NAME}-SS
ss://${SS_LINK_BASE}@${target_host}:${SS_PORT}#${tag_ss}
EOF

    if [[ -n "$LAST_IPV6" ]]; then
        cat >> "${SHOES_LINK_FILE}" <<EOF
# SS2022 (IPv6) — ${HOST_NAME}-SS-V6
ss://${SS_LINK_BASE}@[${LAST_IPV6}]:${SS_PORT}#${tag_ss_v6}
EOF
    fi

    # 2. 其他协议分组：VLESS-Reality (仅保留 IPv4/DDNS)
    cat >> "${SHOES_LINK_FILE}" <<EOF

# ==================== [分组 1] VLESS-Reality ====================
# Reality (IPv4) — ${HOST_NAME}-Reality
vless://${UUID}@${target_host}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHID}&spx=%2F&type=tcp#${tag_reality}
EOF

    # 3. 其他协议分组：AnyTLS (仅保留 IPv4/DDNS)
    cat >> "${SHOES_LINK_FILE}" <<EOF

# ==================== [分组 2] AnyTLS ====================
# AnyTLS (IPv4) — ${HOST_NAME}-AnyTLS
anytls://${PUBLIC_KEY}@${target_host}:${ANYTLS_PORT}?security=tls&sni=${ANYTLS_SNI}&allowInsecure=1&insecure=1&type=tcp#${tag_anytls}
EOF
}

# ================== 动态公网 IP 自动巡检与实时同步引擎 ==================
setup_ip_sync_timer() {
    local quiet_mode="$1"
    if [[ -f "$SCRIPT_SOURCE" ]] && grep -q "SHOES_CONF_DIR" "$SCRIPT_SOURCE" 2>/dev/null; then
        cp -f "$SCRIPT_SOURCE" "${IP_SYNC_BIN}"
        chmod +x "${IP_SYNC_BIN}"
    fi
    [[ ! -x "${IP_SYNC_BIN}" ]] && return

    cat > "${IP_SYNC_SERVICE}" <<EOF
[Unit]
Description=Shoes Dynamic Public IP Link Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${IP_SYNC_BIN} --sync-ip
EOF

    cat > "${IP_SYNC_TIMER}" <<EOF
[Unit]
Description=Periodic Dynamic IP Check for Shoes Links

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now shoes-ip-sync.timer >/dev/null 2>&1
    [[ "$quiet_mode" != "quiet" ]] && echo -e "${GREEN}--> 已启用动态公网 IP 后台自动同步定时任务 (每 5 分钟巡检更新)${RESET}"
}

sync_dynamic_ip() {
    local mode="$1" # cron | startup | verbose

    if [[ ! -f "${SHOES_ENV_FILE}" ]]; then
        if [[ "$mode" == "startup" ]]; then
            CACHED_LIVE_V4=$(get_public_ipv4)
            CACHED_LIVE_V6=$(get_public_ipv6)
            return 0
        fi
        [[ "$mode" == "verbose" ]] && echo -e "\n${YELLOW}配置文件不存在，请先执行安装步骤。${RESET}"
        return 1
    fi

    source "${SHOES_ENV_FILE}"
    [[ -z "$ANYTLS_SNI" ]] && ANYTLS_SNI="cdn.cloudflare.net"

    if [[ "$mode" != "cron" ]] && check_installed && [[ ! -f "${IP_SYNC_TIMER}" ]]; then
        setup_ip_sync_timer "quiet"
    fi

    [[ "$mode" == "verbose" ]] && echo -e "\n${YELLOW}--> 正在实时核验当前公网 IPv4 / IPv6 与节点订阅状态...${RESET}"

    local live_v4 live_v6 old_v4 old_v6 need_regen=0 v4_diff=0 v6_diff=0
    live_v4=$(get_public_ipv4)
    live_v6=$(get_public_ipv6)
    CACHED_LIVE_V4="$live_v4"
    CACHED_LIVE_V6="$live_v6"

    old_v4="${LAST_IPV4:-$(extract_link_ipv4)}"
    old_v6="${LAST_IPV6:-$(extract_link_ipv6)}"

    if [[ -n "$CONNECT_HOST" ]]; then
        if [[ ! -f "${SHOES_LINK_FILE}" ]] || [[ "$live_v6" != "$old_v6" ]] || [[ -n "$live_v4" && "$live_v4" != "$LAST_IPV4" ]]; then
            [[ "$live_v6" != "$old_v6" ]] && v6_diff=1
            generate_links "quiet" "${live_v4:-$old_v4}" "$live_v6"
            if [[ "$v6_diff" -eq 1 ]]; then
                SYNC_V6_CHANGED=1
                SYNC_V6_OLD="$old_v6"
                logger -t shoes-ip-sync "Dynamic IPv6 updated (DDNS mode): ${old_v6:-none}->${live_v6:-none}" 2>/dev/null || true
            fi
        fi
        if [[ "$mode" == "verbose" ]]; then
            echo -e "${GREEN}--> 当前 IPv4 节点绑定 DDNS/固定地址: ${CYAN}${CONNECT_HOST}${RESET} ${GRAY}(实时 IPv4: ${live_v4:-未知})${RESET}"
            [[ -n "$live_v6" ]] && echo -e "${GREEN}--> 当前 IPv6 节点地址 (SS2022): ${CYAN}${live_v6}${RESET}"
        fi
        return 0
    fi

    if [[ -z "$live_v4" ]]; then
        [[ "$mode" == "verbose" ]] && echo -e "${YELLOW}--> 暂时无法探测外部公网 IPv4，当前保留上次缓存节点信息。${RESET}"
        return 0
    fi

    [[ "$live_v4" != "$old_v4" ]] && v4_diff=1
    [[ "$live_v6" != "$old_v6" ]] && v6_diff=1

    if [[ ! -f "${SHOES_LINK_FILE}" ]] || grep -q "YOUR_IPV4_HERE" "${SHOES_LINK_FILE}" 2>/dev/null || [[ "$v4_diff" -eq 1 ]] || [[ "$v6_diff" -eq 1 ]]; then
        need_regen=1
    fi

    if [[ "$need_regen" -eq 1 ]]; then
        generate_links "quiet" "$live_v4" "$live_v6"
        logger -t shoes-ip-sync "Dynamic IP updated: IPv4 ${old_v4:-none}->${live_v4}, IPv6 ${old_v6:-none}->${live_v6:-none}" 2>/dev/null || true
        if [[ "$v4_diff" -eq 1 ]]; then
            SYNC_V4_CHANGED=1
            SYNC_V4_OLD="$old_v4"
        fi
        if [[ "$v6_diff" -eq 1 ]]; then
            SYNC_V6_CHANGED=1
            SYNC_V6_OLD="$old_v6"
        fi
        if [[ "$mode" == "verbose" ]]; then
            [[ "$v4_diff" -eq 1 ]] && echo -e "${GREEN}--> 检测到动态 IPv4 已变更: ${YELLOW}${old_v4:-未知}${RESET} -> ${CYAN}${live_v4}${RESET}"
            [[ "$v6_diff" -eq 1 ]] && echo -e "${GREEN}--> 检测到动态 IPv6 已变更: ${YELLOW}${old_v6:-无}${RESET} -> ${CYAN}${live_v6:-无}${RESET}"
            echo -e "${GREEN}--> 节点订阅链接已自动更新为最新公网 IP (Shoes 0.3.8+ 已自动重置内部 Worker)！${RESET}"
        fi
    else
        if [[ -z "$LAST_IPV4" ]] || [[ "$LAST_IPV6" != "$live_v6" ]]; then
            LAST_IPV4="$live_v4"
            LAST_IPV6="$live_v6"
            save_env_file
        fi
        if [[ "$mode" == "verbose" ]]; then
            echo -e "${GREEN}--> 当前公网 IP 未变动 (IPv4: ${CYAN}${live_v4}${GREEN}${live_v6:+ | IPv6: ${CYAN}${live_v6}${GREEN}})，节点已是最新状态。${RESET}"
        fi
    fi
    return 0
}

# ================== 架构检测与无损沙盒原子下载 (适配 v0.3.8 打包结构与多源防限流) ==================
check_arch() {
    case "$(uname -m)" in
        x86_64)
            GNU_FILE="shoes-x86_64-unknown-linux-gnu.tar.gz"
            MUSL_FILE="shoes-x86_64-unknown-linux-musl.tar.gz"
            ;;
        aarch64|arm64)
            GNU_FILE="shoes-aarch64-unknown-linux-gnu.tar.gz"
            MUSL_FILE="shoes-aarch64-unknown-linux-musl.tar.gz"
            ;;
        *)
            echo -e "${RED}不支持的 CPU 架构: $(uname -m)！${RESET}"
            return 1
            ;;
    esac
    return 0
}

get_latest_version() {
    LATEST_VER=""
    GH_DL_PREFIX="https://github.com"

    # 方式 1：优先通过 HTTP GET 读取 /releases/latest 的 302 Location 头提取版本号（零 API 限流、不下载网页正文、修复原 -I HEAD 拒跳 Bug）
    local loc_ver="" effective_url=""
    for flag in "-4" ""; do
        loc_ver=$(curl $flag -sS --connect-timeout 6 --max-time 10 -D - -o /dev/null \
            "https://github.com/cfal/shoes/releases/latest" 2>/dev/null \
            | grep -i '^location:' | tail -n 1 | tr -d '\r\n[:space:]' \
            | awk -F'/releases/tag/' '{print $2}' | sed 's/^v//; s/[/?#].*//')
        if [[ -n "$loc_ver" ]]; then
            LATEST_VER="$loc_ver"
            return 0
        fi

        effective_url=$(curl $flag -fsSL --connect-timeout 6 --max-time 10 -o /dev/null -w '%{url_effective}' \
            "https://github.com/cfal/shoes/releases/latest" 2>/dev/null || true)
        if [[ "$effective_url" == *"/releases/tag/"* ]]; then
            LATEST_VER=$(echo "$effective_url" | awk -F'/releases/tag/' '{print $2}' | sed 's/^v//; s/[/?#].*//' | tr -d '\r\n[:space:]')
            [[ -n "$LATEST_VER" ]] && return 0
        fi
    done

    # 方式 2：GitHub 官方 Releases API 兜底（使用合规 CLI UA，并用 grep -oE 兼容单行压缩 JSON）
    for flag in "-4" ""; do
        LATEST_VER=$(curl $flag -fsSL -H "Accept: application/vnd.github+json" -A "eshoes-updater/4.6.1" \
            --connect-timeout 6 --max-time 10 "https://api.github.com/repos/cfal/shoes/releases/latest" 2>/dev/null \
            | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v?[^"]+"' | head -n 1 \
            | sed -E 's/.*"v?([^"]+)"/\1/' | tr -d '\r\n[:space:]')
        [[ -n "$LATEST_VER" ]] && return 0
    done

    # 方式 3：GitHub 直连受阻（纯 IPv6 / 受限网络）时，自动轮询加速镜像获取版本并同步切换下载源
    local mirrors=(
        "https://ghfast.top/https://github.com"
        "https://gh-proxy.com/https://github.com"
    )
    for m in "${mirrors[@]}"; do
        effective_url=$(curl -fsSL --connect-timeout 6 --max-time 10 -o /dev/null -w '%{url_effective}' \
            "${m}/cfal/shoes/releases/latest" 2>/dev/null || true)
        if [[ "$effective_url" == *"/releases/tag/"* ]]; then
            LATEST_VER=$(echo "$effective_url" | awk -F'/releases/tag/' '{print $2}' | sed 's/^v//; s/[/?#].*//' | tr -d '\r\n[:space:]')
            if [[ -n "$LATEST_VER" ]]; then
                GH_DL_PREFIX="$m"
                echo -e "${YELLOW}--> GitHub 直连受限，已自动切换至镜像源: ${m%/https://*}${RESET}"
                return 0
            fi
        fi
    done

    echo -e "${RED}无法获取 Shoes 最新版本号，请检查服务器到 GitHub 的网络连接！${RESET}"
    return 1
}

# 沙盒无损下载：绝不提前删除现网运行中的二进制，校验通过后再原子替换，并清理 v0.3.8 新增的 licenses/ 临时文件
download_shoes_smart() {
    local force_update="$1"

    echo -e "${YELLOW}--> 正在准备 Shoes 核心文件...${RESET}"

    if [[ "$force_update" != "force" ]] && [[ -x "${SHOES_BIN}" ]]; then
        if "${SHOES_BIN}" --version >/dev/null 2>&1; then
            echo -e "${GREEN}检测到当前核心可用 ($(get_local_version))，跳过下载。${RESET}"
            return 0
        fi
    fi

    get_latest_version || return 1
    check_arch || return 1

    local cur_ver
    cur_ver=$(get_local_version | sed 's/^v//')
    if [[ "$force_update" == "force" ]] && [[ "$cur_ver" == "$LATEST_VER" ]]; then
        echo -e "${GREEN}当前核心已是最新版本 (v${LATEST_VER})，无需重复下载！${RESET}"
        return 0
    fi

    rm -rf "${TMP_DIR}"
    mkdir -p "${TMP_DIR}"

    local candidate_bin=""
    local variant_label=""
    local dl_prefixes=("${GH_DL_PREFIX}")
    if [[ "$GH_DL_PREFIX" == "https://github.com" ]]; then
        dl_prefixes+=(
            "https://ghfast.top/https://github.com"
            "https://gh-proxy.com/https://github.com"
        )
    fi

    for item in "GNU:${GNU_FILE}" "MUSL:${MUSL_FILE}"; do
        variant_label="${item%%:*}"
        local pkg_name="${item#*:}"
        echo -e "${YELLOW}--> 尝试下载 ${variant_label} 版本 (v${LATEST_VER})...${RESET}"

        for prefix in "${dl_prefixes[@]}"; do
            rm -rf "${TMP_DIR:?}"/*
            local dl_url="${prefix}/cfal/shoes/releases/download/v${LATEST_VER}/${pkg_name}"
            if curl -4 -fsSL --connect-timeout 10 --max-time 60 --retry 1 -o "${TMP_DIR}/shoes.tar.gz" "$dl_url" 2>/dev/null || \
               curl -fsSL --connect-timeout 10 --max-time 60 --retry 1 -o "${TMP_DIR}/shoes.tar.gz" "$dl_url" 2>/dev/null || \
               wget -4 --no-check-certificate --timeout=15 --tries=2 -qO "${TMP_DIR}/shoes.tar.gz" "$dl_url" 2>/dev/null || \
               wget --no-check-certificate --timeout=15 --tries=2 -qO "${TMP_DIR}/shoes.tar.gz" "$dl_url" 2>/dev/null; then
                if [[ -s "${TMP_DIR}/shoes.tar.gz" ]] && tar -xzf "${TMP_DIR}/shoes.tar.gz" -C "${TMP_DIR}" 2>/dev/null; then
                    # 精确查找可执行主文件 (自动忽略 v0.3.8 新增的 LICENSE, THIRD_PARTY_NOTICES.md 与 licenses/ 目录)
                    local found_bin
                    found_bin=$(find "${TMP_DIR}" -maxdepth 2 -type f -name "shoes" | head -n 1)
                    if [[ -n "$found_bin" ]]; then
                        chmod +x "$found_bin"
                        if "$found_bin" --version >/dev/null 2>&1; then
                            candidate_bin="$found_bin"
                            break 2
                        fi
                    fi
                fi
            fi
        done
        echo -e "${YELLOW}${variant_label} 版本不可用或运行环境不匹配，正在尝试备选包...${RESET}"
    done

    if [[ -z "$candidate_bin" ]]; then
        rm -rf "${TMP_DIR}"
        echo -e "${RED}严重错误：新版本下载或运行校验失败！已保留原有核心不受影响。${RESET}"
        return 1
    fi

    # 若当前已有配置文件，升级前用新核心预跑 --dry-run，防止未来新版本配置不兼容导致服务挂死
    if [[ -f "${SHOES_CONF_FILE}" ]]; then
        if ! "$candidate_bin" --dry-run "${SHOES_CONF_FILE}" >/dev/null 2>&1; then
            echo -e "${RED}警告：新核心 (v${LATEST_VER}) 对现有 config.yaml 预检 (--dry-run) 未通过！已中止替换以保护现网节点：${RESET}"
            "$candidate_bin" --dry-run "${SHOES_CONF_FILE}" || true
            rm -rf "${TMP_DIR}"
            return 1
        fi
    fi

    # 原子替换至目标路径 (避免 Text file busy 报错，无需提前 rm 破坏失败回退)
    install -m 755 "$candidate_bin" "${SHOES_BIN}.new" && mv -f "${SHOES_BIN}.new" "${SHOES_BIN}"
    rm -rf "${TMP_DIR}"
    echo -e "${GREEN}${variant_label} 版本部署并通过校验！当前核心版本: $(get_local_version)${RESET}"
    return 0
}

# ================== 核心安装逻辑 ==================
install_shoes() {
    local install_mode="$1"
    clear
    echo -e "${LINE_HEAVY}"
    echo -e "  ${CYAN}开始部署 E-Shoes 代理节点${RESET}"
    echo -e "${LINE_HEAVY}"
    
    sync_system_time
    if ! download_shoes_smart "normal"; then
        echo -e "${RED}核心准备失败，已中止安装流程。${RESET}"
        return 1
    fi
    mkdir -p "${SHOES_CONF_DIR}"

    local OLD_SS_PORT=""
    local OLD_VLESS_PORT=""
    local OLD_ANYTLS_PORT=""
    if [[ -f "${SHOES_ENV_FILE}" ]]; then
        OLD_SS_PORT=$(grep '^SS_PORT=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
        OLD_VLESS_PORT=$(grep '^VLESS_PORT=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
        OLD_ANYTLS_PORT=$(grep '^ANYTLS_PORT=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
    fi

    if [[ "$install_mode" == "keep" ]] && [[ -f "${SHOES_ENV_FILE}" ]] && [[ -f "${SHOES_CONF_FILE}" ]]; then
        echo -e "${GREEN}--> 正在读取现有配置文件，检查端口、算法与节点信息...${RESET}"
        source "${SHOES_ENV_FILE}"
        
        if [[ -z "$PRIVATE_KEY" ]]; then
            PRIVATE_KEY=$(grep 'private_key:' "${SHOES_CONF_FILE}" | head -n 1 | awk -F'"' '{print $2}')
        fi
        [[ -z "$HOST_NAME" ]] && HOST_NAME=$(hostname)
        [[ -z "$SS_METHOD" ]] && SS_METHOD="${DEFAULT_SS_METHOD}"

        # 自动修复旧版因 128-gcm / 256-gcm 混用导致的密钥长度不匹配问题
        if ! is_valid_ss2022_key "$SS_METHOD" "$SS_PASSWORD"; then
            SS_PASSWORD=$(generate_ss2022_key "$SS_METHOD")
            echo -e "${YELLOW}--> 检测到原 SS-2022 密钥长度与 ${SS_METHOD} 不匹配，已自动重新生成合规密钥！${RESET}"
        fi
        
        if [[ -z "$VLESS_PORT" ]] || [[ "$VLESS_PORT" -lt "$PORT_MIN" ]]; then
            VLESS_PORT=$(pick_vless_port)
            echo -e "${YELLOW}--> 检测到原 VLESS 端口 <= 20300，已自动迁移至: ${VLESS_PORT}${RESET}"
        fi
        if [[ -z "$SS_PORT" ]] || [[ "$SS_PORT" -lt "$PORT_MIN" ]] || [[ "$SS_PORT" == "$VLESS_PORT" ]]; then
            while true; do
                SS_PORT=$(pick_random_port)
                [[ "$SS_PORT" != "$VLESS_PORT" ]] && break
            done
            echo -e "${YELLOW}--> 检测到原 SS2022 端口 <= 20300，已自动迁移至: ${SS_PORT}${RESET}"
        fi
        if [[ -z "$ANYTLS_PORT" ]] || [[ "$ANYTLS_PORT" -lt "$PORT_MIN" ]] || [[ "$ANYTLS_PORT" == "$VLESS_PORT" ]] || [[ "$ANYTLS_PORT" == "$SS_PORT" ]]; then
            while true; do
                ANYTLS_PORT=$(pick_random_port)
                [[ "$ANYTLS_PORT" != "$VLESS_PORT" ]] && [[ "$ANYTLS_PORT" != "$SS_PORT" ]] && break
            done
            echo -e "${YELLOW}--> 检测到原 AnyTLS 端口 <= 20300，已自动迁移至: ${ANYTLS_PORT}${RESET}"
        fi

        SNI=$(normalize_and_validate_sni "$SNI" || echo "www.apple.com")
        if [[ "$SNI" == "icloud.com" ]]; then
            SNI="www.apple.com"
            echo -e "${YELLOW}--> 已自动将旧的 Reality SNI (icloud.com) 升级为 ${SNI}${RESET}"
        fi
        
        SKIP_CERT=0
        ANYTLS_SNI=$(normalize_and_validate_sni "$ANYTLS_SNI" || echo "")
        if [[ -z "$ANYTLS_SNI" ]] || [[ "$ANYTLS_SNI" == "icloud.com" ]] || [[ "$ANYTLS_SNI" == "$SNI" ]]; then
            ANYTLS_SNI="cdn.cloudflare.net"
            echo -e "${YELLOW}--> 已分离 AnyTLS 自签证书域名为 ${ANYTLS_SNI}，即将重新生成证书...${RESET}"
            SKIP_CERT=0
        elif [[ -f "${SHOES_CONF_DIR}/cert.pem" ]] && [[ -f "${SHOES_CONF_DIR}/key.pem" ]]; then
            echo -e "${GREEN}--> 检测到现有合规 TLS 证书，跳过生成...${RESET}"
            SKIP_CERT=1
        fi
    else
        if [[ "$install_mode" == "keep" ]]; then
            echo -e "${RED}警告：未检测到完整的旧配置环境，将自动执行全新安装！${RESET}"
        fi
        
        echo -e "${YELLOW}--> 正在生成全新的安全密钥与端口 (全部锁定在 ${PORT_MIN}-${PORT_MAX})...${RESET}"
        HOST_NAME=$(hostname)
        [[ -z "$HOST_NAME" ]] && HOST_NAME="ShoeServer"
        
        SNI="www.apple.com"
        ANYTLS_SNI="cdn.cloudflare.net"
        CONNECT_HOST=""
        LAST_IPV4=""
        LAST_IPV6=""

        systemctl stop shoes >/dev/null 2>&1

        VLESS_PORT=$(pick_vless_port)
        while true; do
            SS_PORT=$(pick_random_port)
            [[ "$SS_PORT" != "$VLESS_PORT" ]] && break
        done
        while true; do
            ANYTLS_PORT=$(pick_random_port)
            [[ "$ANYTLS_PORT" != "$SS_PORT" ]] && [[ "$ANYTLS_PORT" != "$VLESS_PORT" ]] && break
        done

        UUID=$(cat /proc/sys/kernel/random/uuid)
        KEYPAIR=$("${SHOES_BIN}" generate-reality-keypair)
        PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "private key" | awk '{print $NF}')
        PUBLIC_KEY=$(echo "$KEYPAIR" | grep -i "public key" | awk '{print $NF}')
        SHID=$(openssl rand -hex 8)

        SS_METHOD="${DEFAULT_SS_METHOD}"
        SS_PASSWORD=$(generate_ss2022_key "$SS_METHOD")
        SKIP_CERT=0
    fi

    if [[ "$SKIP_CERT" -eq 0 ]]; then
        echo -e "${YELLOW}--> 正在生成包含 SAN 扩展的自签 TLS 证书 (365天标准周期)...${RESET}"
        openssl ecparam -genkey -name prime256v1 -out "${SHOES_CONF_DIR}/key.pem"
        openssl req -new -x509 -days 365 -key "${SHOES_CONF_DIR}/key.pem" -out "${SHOES_CONF_DIR}/cert.pem" -subj "/CN=${ANYTLS_SNI}" -addext "subjectAltName=DNS:${ANYTLS_SNI}" >/dev/null 2>&1
        chmod 600 "${SHOES_CONF_DIR}/key.pem" 2>/dev/null || true
    fi

    echo -e "${YELLOW}--> 正在检测服务器网络栈环境并写入配置...${RESET}"
    write_shoes_configs
    if [[ "$BIND_ADDR" == "[::]" ]]; then
        echo -e "${GREEN}检测到本地已开启 IPv6 协议栈，核心服务已启用双栈监听 [::] (IPv4+IPv6)${RESET}"
    else
        echo -e "${YELLOW}系统底层已禁用 IPv6，将仅监听 0.0.0.0 (IPv4) 防止核心 Panic${RESET}"
    fi

    sync_firewall_ports "$OLD_SS_PORT" "$OLD_VLESS_PORT" "$OLD_ANYTLS_PORT"

    cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=Shoes Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${SHOES_CONF_DIR}
Environment="RUST_LOG=error,shoes::tcp::tcp_server=off"
ExecStartPre=${SHOES_BIN} --dry-run ${SHOES_CONF_FILE}
ExecStart=${SHOES_BIN} ${SHOES_CONF_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${YELLOW}--> 正在优化系统级文件描述符与网络参数 (独立配置文件，不冲突全局 BBR)...${RESET}"
    mkdir -p /etc/security/limits.d /etc/sysctl.d
    cat > "${LIMITS_CONF}" <<EOF
* soft nofile 65535
* hard nofile 1048576
root soft nofile 65535
root hard nofile 1048576
EOF

    cat > "${SYSCTL_CONF}" <<'EOF'
fs.file-max = 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_tw_reuse = 1
EOF
    sysctl --system >/dev/null 2>&1

    echo -e "${YELLOW}--> 正在注册并启动系统服务...${RESET}"
    systemctl daemon-reload
    systemctl enable shoes >/dev/null 2>&1
    systemctl restart shoes
    sleep 2

    if check_running; then
        echo -e "${YELLOW}--> 正在生成节点订阅链接 (VLESS/AnyTLS 仅保留 IPv4)...${RESET}"
        generate_links
        setup_ip_sync_timer
        
        echo -e "\n${GREEN}Shoes 部署完成！当前分配端口均在 20300 之后：${RESET}"
        echo -e "  - ${CYAN}SS-2022 端口:${RESET} ${SS_PORT} (${SS_METHOD} | IPv4 & IPv6)"
        echo -e "  - ${CYAN}VLESS 端口:${RESET}   ${VLESS_PORT} (仅 IPv4)"
        echo -e "  - ${CYAN}AnyTLS 端口:${RESET}  ${ANYTLS_PORT} (仅 IPv4)"
        
        echo -e "${LINE_LIGHT}"
        cat "${SHOES_LINK_FILE}"
        echo -e "${LINE_LIGHT}"
    else
        echo -e "${RED}服务启动失败！以下为调试信息：${RESET}"
        "${SHOES_BIN}" --dry-run "${SHOES_CONF_FILE}"
    fi
}

# ================== 修改协议端口功能 ==================
prompt_single_port() {
    local proto_name="$1"
    local current_port="$2"
    local other_p1="$3"
    local other_p2="$4"
    local is_vless="$5"
    local input_port=""

    while true; do
        read -p "  请输入新的 ${proto_name} 端口 [范围 ${PORT_MIN}-${PORT_MAX}，直接回车则随机分配]: " input_port
        if [[ -z "$input_port" ]]; then
            while true; do
                if [[ "$is_vless" == "1" ]]; then
                    input_port=$(pick_vless_port)
                else
                    input_port=$(pick_random_port)
                fi
                [[ "$input_port" != "$current_port" ]] && [[ "$input_port" != "$other_p1" ]] && [[ "$input_port" != "$other_p2" ]] && break
            done
            echo -e "  ${GREEN}--> 已随机分配新端口: ${input_port}${RESET}"
            NEW_PORT_RESULT="$input_port"
            return 0
        elif [[ "$input_port" =~ ^[0-9]+$ ]] && [[ "$input_port" -ge "$PORT_MIN" ]] && [[ "$input_port" -le "$PORT_MAX" ]]; then
            if [[ "$input_port" == "$other_p1" ]] || [[ "$input_port" == "$other_p2" ]]; then
                echo -e "  ${RED}错误：该端口已与其他协议端口冲突，请换一个！${RESET}"
            elif [[ "$input_port" != "$current_port" ]] && is_port_used "$input_port"; then
                echo -e "  ${RED}错误：端口 ${input_port} 已被系统其他程序占用，请换一个！${RESET}"
            else
                echo -e "  ${GREEN}--> 端口设置为: ${input_port}${RESET}"
                NEW_PORT_RESULT="$input_port"
                return 0
            fi
        else
            echo -e "  ${RED}错误：端口必须是 ${PORT_MIN} 到 ${PORT_MAX} 之间的数字（20300 之后）！${RESET}"
        fi
    done
}

change_ports_menu() {
    if [[ ! -f "${SHOES_ENV_FILE}" ]] || [[ ! -f "${SHOES_CONF_FILE}" ]]; then
        echo -e "\n${RED}错误：未检测到已安装的配置文件，请先执行安装！${RESET}"
        return
    fi

    source "${SHOES_ENV_FILE}"
    [[ -z "$ANYTLS_SNI" ]] && ANYTLS_SNI="cdn.cloudflare.net"

    while true; do
        clear
        local fw_status
        fw_status=$(detect_firewall)
        echo -e "${LINE_HEAVY}"
        echo -e "  ${CYAN}修改协议端口${RESET}  ${GRAY}(安全范围 ${PORT_MIN}-${PORT_MAX})${RESET}"
        echo -e "${LINE_HEAVY}"
        echo -e "  ${GRAY}防护状态 :${RESET} $( [[ "$fw_status" == "none" ]] && echo -e "${GREEN}● 未启用 (默认全放行)${RESET}" || echo -e "${YELLOW}● ${fw_status}${RESET} ${GRAY}(自动同步放行新端口)${RESET}" )"
        echo -e "  ${GRAY}当前端口 :${RESET} ${WHITE}SS${RESET} ${CYAN}${SS_PORT}${RESET}  ${GRAY}|${RESET}  ${WHITE}VLESS${RESET} ${CYAN}${VLESS_PORT}${RESET}  ${GRAY}|${RESET}  ${WHITE}AnyTLS${RESET} ${CYAN}${ANYTLS_PORT}${RESET}"
        echo -e "${LINE_LIGHT}"
        echo -e "  ${CYAN}1.${RESET} ${WHITE}修改 SS-2022 端口${RESET}        ${GRAY}(当前: ${SS_PORT})${RESET}"
        echo -e "  ${CYAN}2.${RESET} ${WHITE}修改 VLESS-Reality 端口${RESET}  ${GRAY}(当前: ${VLESS_PORT})${RESET}"
        echo -e "  ${CYAN}3.${RESET} ${WHITE}修改 AnyTLS 端口${RESET}         ${GRAY}(当前: ${ANYTLS_PORT})${RESET}"
        echo -e "  ${CYAN}4.${RESET} ${WHITE}随机重置全部协议端口${RESET}     ${GRAY}(自动避开占用端口)${RESET}"
        echo -e "${LINE_LIGHT}"
        echo -e "  ${CYAN}0.${RESET} ${WHITE}返回上级菜单${RESET}"
        echo -e "${LINE_HEAVY}"
        echo -ne "  ${WHITE}请选择操作 [0-4]: ${RESET}"
        read -r p_choice

        local old_ss="$SS_PORT"
        local old_vless="$VLESS_PORT"
        local old_anytls="$ANYTLS_PORT"

        case "$p_choice" in
            1)
                prompt_single_port "Shadowsocks-2022" "$SS_PORT" "$VLESS_PORT" "$ANYTLS_PORT" "0"
                SS_PORT="$NEW_PORT_RESULT"
                ;;
            2)
                prompt_single_port "VLESS-Reality" "$VLESS_PORT" "$SS_PORT" "$ANYTLS_PORT" "1"
                VLESS_PORT="$NEW_PORT_RESULT"
                ;;
            3)
                prompt_single_port "AnyTLS" "$ANYTLS_PORT" "$SS_PORT" "$VLESS_PORT" "0"
                ANYTLS_PORT="$NEW_PORT_RESULT"
                ;;
            4)
                echo -e "\n${YELLOW}--> 正在随机重新分配所有协议端口 (20301-60000)...${RESET}"
                systemctl stop shoes >/dev/null 2>&1
                VLESS_PORT=$(pick_vless_port)
                while true; do
                    SS_PORT=$(pick_random_port)
                    [[ "$SS_PORT" != "$VLESS_PORT" ]] && break
                done
                while true; do
                    ANYTLS_PORT=$(pick_random_port)
                    [[ "$ANYTLS_PORT" != "$SS_PORT" ]] && [[ "$ANYTLS_PORT" != "$VLESS_PORT" ]] && break
                done
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入！${RESET}"
                sleep 1
                continue
                ;;
        esac

        echo -e "\n${YELLOW}--> 正在写入新端口配置并重启 Shoes 服务...${RESET}"
        write_shoes_configs
        sync_firewall_ports "$old_ss" "$old_vless" "$old_anytls"
        systemctl restart shoes
        sleep 2

        if check_running; then
            generate_links
            echo -e "${GREEN}端口修改成功并已生效！最新端口信息：${RESET}"
            echo -e "  - ${CYAN}SS-2022 端口:${RESET} ${SS_PORT}"
            echo -e "  - ${CYAN}VLESS 端口:${RESET}   ${VLESS_PORT}"
            echo -e "  - ${CYAN}AnyTLS 端口:${RESET}  ${ANYTLS_PORT}"
            echo -e "${LINE_LIGHT}"
            cat "${SHOES_LINK_FILE}"
            echo -e "${LINE_LIGHT}"
        else
            echo -e "${RED}服务重启失败，请检查端口冲突或系统日志！${RESET}"
        fi
        echo "" && read -n 1 -s -r -p "按任意键继续..."
    done
}

# ================== 修改伪装域名 (SNI) 功能 (适配 v0.3.8 证书根库与名称校验) ==================
change_sni_menu() {
    if [[ ! -f "${SHOES_ENV_FILE}" ]] || [[ ! -f "${SHOES_CONF_FILE}" ]]; then
        echo -e "\n${RED}错误：未检测到已安装的配置文件，请先执行安装！${RESET}"
        return
    fi

    source "${SHOES_ENV_FILE}"
    [[ -z "$ANYTLS_SNI" ]] && ANYTLS_SNI="cdn.cloudflare.net"

    while true; do
        clear
        echo -e "${LINE_HEAVY}"
        echo -e "  ${CYAN}修改 Reality / AnyTLS 伪装域名${RESET}"
        echo -e "${LINE_HEAVY}"
        echo -e "  ${GRAY}伪装域名 :${RESET} ${GREEN}${SNI}${RESET} ${GRAY}(VLESS-Reality)${RESET}"
        echo -e "  ${GRAY}证书域名 :${RESET} ${CYAN}${ANYTLS_SNI}${RESET} ${GRAY}(AnyTLS 自签)${RESET}"
        echo -e "${LINE_LIGHT}"
        echo -e "  ${YELLOW}推荐预设域名 (TLS 1.3 + H2 + 兼容 v0.3.8 根证书束):${RESET}"
        echo -e "  ${CYAN}1.${RESET} ${WHITE}www.apple.com         ${RESET}  ${GRAY}— Apple 全球节点 (通用稳定)${RESET}"
        echo -e "  ${CYAN}2.${RESET} ${WHITE}dl.google.com         ${RESET}  ${GRAY}— Google 下载源 (欧美/亚太)${RESET}"
        echo -e "  ${CYAN}3.${RESET} ${WHITE}www.microsoft.com     ${RESET}  ${GRAY}— Microsoft 官网 (全球双栈)${RESET}"
        echo -e "  ${CYAN}4.${RESET} ${WHITE}www.amd.com           ${RESET}  ${GRAY}— AMD 官网 (高频 CDN 节点)${RESET}"
        echo -e "  ${CYAN}5.${RESET} ${WHITE}aws.amazon.com        ${RESET}  ${GRAY}— AWS 官网 (AWS/欧美优选)${RESET}"
        echo -e "  ${CYAN}6.${RESET} ${WHITE}www.lovelive-anime.jp ${RESET}  ${GRAY}— 日本二次元站 (日本机房优选)${RESET}"
        echo -e "${LINE_LIGHT}"
        echo -e "  ${CYAN}7.${RESET} ${WHITE}自定义 Reality 伪装域名${RESET}  ${GRAY}— 手动输入目标 SNI 并检测证书链${RESET}"
        echo -e "  ${CYAN}8.${RESET} ${WHITE}修改 AnyTLS 证书域名   ${RESET}  ${GRAY}— 更换域名并自动重签 TLS 证书${RESET}"
        echo -e "  ${CYAN}0.${RESET} ${WHITE}返回上级菜单${RESET}"
        echo -e "${LINE_HEAVY}"
        echo -ne "  ${WHITE}请选择操作 [0-8]: ${RESET}"
        read -r sni_choice

        local new_sni=""
        local need_re_cert=0

        case "$sni_choice" in
            1) new_sni="www.apple.com" ;;
            2) new_sni="dl.google.com" ;;
            3) new_sni="www.microsoft.com" ;;
            4) new_sni="www.amd.com" ;;
            5) new_sni="aws.amazon.com" ;;
            6) new_sni="www.lovelive-anime.jp" ;;
            7)
                read -p "  请输入自定义 Reality SNI 域名 (如 www.sony.jp): " custom_sni
                if ! new_sni=$(normalize_and_validate_sni "$custom_sni"); then
                    echo -e "  ${RED}错误：域名格式无效或含非法数字/十六进制顶级标签 (v0.3.8 限制)！${RESET}"
                    sleep 1.8
                    continue
                fi
                ;;
            8)
                read -p "  请输入新的 AnyTLS 自签证书域名 [当前: ${ANYTLS_SNI}]: " custom_anytls
                local parsed_anytls
                if ! parsed_anytls=$(normalize_and_validate_sni "$custom_anytls"); then
                    echo -e "  ${RED}错误：域名格式无效或含非法数字/十六进制顶级标签！${RESET}"
                    sleep 1.8
                    continue
                fi
                if [[ "$parsed_anytls" == "$SNI" ]]; then
                    echo -e "  ${RED}错误：AnyTLS 证书域名不能与 Reality SNI (${SNI}) 相同，以免暴露自签特征！${RESET}"
                    sleep 2
                    continue
                fi
                ANYTLS_SNI="$parsed_anytls"
                need_re_cert=1
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入！${RESET}"
                sleep 1
                continue
                ;;
        esac

        if [[ -n "$new_sni" ]]; then
            echo -e "\n${YELLOW}--> 正在测试本机到 ${new_sni}:443 的 TLS 1.3 握手与根证书链兼容性...${RESET}"
            local tls_out
            tls_out=$(timeout 5 openssl s_client -tls1_3 -connect "${new_sni}:443" -servername "${new_sni}" </dev/null 2>/dev/null)
            if echo "$tls_out" | grep -q "Verify return code: 0"; then
                if echo "$tls_out" | grep -qiE "DigiCert Trusted Root G4|QuoVadis Root CA|Buypass Class|Certigna Root CA"; then
                    echo -e "${YELLOW}注意：该站点证书链包含 Shoes v0.3.8 已移除的根证书 (如 DigiCert G4 / QuoVadis / Buypass)。${RESET}"
                    read -p "  是否仍然继续使用该域名？[y/N]: " force_ca
                    [[ ! "$force_ca" =~ ^[yY]$ ]] && continue
                else
                    echo -e "${GREEN}--> 域名 ${new_sni}:443 TLS 1.3 握手与证书链校验完美通过！${RESET}"
                fi
            else
                echo -e "${YELLOW}警告：本机连接 ${new_sni}:443 超时、不支持 TLS 1.3 或证书校验异常。${RESET}"
                read -p "  是否仍然强制使用该域名？[y/N]: " force_sni
                [[ ! "$force_sni" =~ ^[yY]$ ]] && continue
            fi
            SNI="$new_sni"
            if [[ "$ANYTLS_SNI" == "$SNI" ]]; then
                ANYTLS_SNI="cdn.cloudflare.net"
                need_re_cert=1
            fi
        fi

        if [[ "$need_re_cert" -eq 1 ]]; then
            echo -e "${YELLOW}--> 正在为 AnyTLS (${ANYTLS_SNI}) 重新生成自签 TLS 证书...${RESET}"
            openssl ecparam -genkey -name prime256v1 -out "${SHOES_CONF_DIR}/key.pem"
            openssl req -new -x509 -days 365 -key "${SHOES_CONF_DIR}/key.pem" -out "${SHOES_CONF_DIR}/cert.pem" -subj "/CN=${ANYTLS_SNI}" -addext "subjectAltName=DNS:${ANYTLS_SNI}" >/dev/null 2>&1
            chmod 600 "${SHOES_CONF_DIR}/key.pem" 2>/dev/null || true
        fi

        echo -e "${YELLOW}--> 正在更新配置文件并重启 Shoes 服务...${RESET}"
        write_shoes_configs
        systemctl restart shoes
        sleep 2

        if check_running; then
            generate_links
            echo -e "${GREEN}伪装域名修改成功并已生效！${RESET}"
            echo -e "  - ${CYAN}当前 Reality SNI:${RESET} ${SNI}"
            echo -e "  - ${CYAN}当前 AnyTLS SNI:${RESET}  ${ANYTLS_SNI}"
            echo -e "${LINE_LIGHT}"
            cat "${SHOES_LINK_FILE}"
            echo -e "${LINE_LIGHT}"
        else
            echo -e "${RED}服务重启失败，请检查配置或系统日志！${RESET}"
        fi
        echo "" && read -n 1 -s -r -p "按任意键继续..."
    done
}

# ================== 切换 SS-2022 加密算法 (128-GCM / 256-GCM) ==================
change_ss_cipher_menu() {
    if [[ ! -f "${SHOES_ENV_FILE}" ]] || [[ ! -f "${SHOES_CONF_FILE}" ]]; then
        echo -e "\n${RED}错误：未检测到已安装的配置文件，请先执行安装！${RESET}"
        return
    fi

    source "${SHOES_ENV_FILE}"
    [[ -z "$ANYTLS_SNI" ]] && ANYTLS_SNI="cdn.cloudflare.net"

    clear
    echo -e "${LINE_HEAVY}"
    echo -e "  ${CYAN}切换 Shadowsocks-2022 加密套件${RESET}"
    echo -e "${LINE_HEAVY}"
    echo -e "  ${GRAY}当前算法 :${RESET} ${GREEN}${SS_METHOD}${RESET}"
    echo -e "${LINE_LIGHT}"
    echo -e "  ${CYAN}1.${RESET} ${WHITE}2022-blake3-aes-128-gcm${RESET}       ${GRAY}— 极速低延迟 (16字节密钥，推荐移动/家宽)${RESET}"
    echo -e "  ${CYAN}2.${RESET} ${WHITE}2022-blake3-aes-256-gcm${RESET}       ${GRAY}— 高强加密   (32字节密钥，通用标准)${RESET}"
    echo -e "  ${CYAN}3.${RESET} ${WHITE}2022-blake3-chacha20-poly1305${RESET} ${GRAY}— 纯软算优化 (32字节密钥，无AES指令集适用)${RESET}"
    echo -e "${LINE_LIGHT}"
    echo -e "  ${CYAN}0.${RESET} ${WHITE}返回上级菜单${RESET}"
    echo -e "${LINE_HEAVY}"
    echo -ne "  ${WHITE}请选择加密算法 [0-3]: ${RESET}"
    read -r c_choice

    local target_method=""
    case "$c_choice" in
        1) target_method="2022-blake3-aes-128-gcm" ;;
        2) target_method="2022-blake3-aes-256-gcm" ;;
        3) target_method="2022-blake3-chacha20-poly1305" ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${RESET}"; sleep 1; return ;;
    esac

    if [[ "$target_method" == "$SS_METHOD" ]] && is_valid_ss2022_key "$SS_METHOD" "$SS_PASSWORD"; then
        echo -e "\n${YELLOW}当前已是 ${target_method} 且密钥正常，无需变更。${RESET}"
        return
    fi

    SS_METHOD="$target_method"
    SS_PASSWORD=$(generate_ss2022_key "$SS_METHOD")
    echo -e "\n${YELLOW}--> 已切换算法为 ${SS_METHOD} 并同步生成对应长度密钥，正在重启服务...${RESET}"
    write_shoes_configs
    systemctl restart shoes
    sleep 2

    if check_running; then
        generate_links
        echo -e "${GREEN}SS-2022 加密算法更新成功！最新节点链接：${RESET}"
        echo -e "${LINE_LIGHT}"
        cat "${SHOES_LINK_FILE}"
        echo -e "${LINE_LIGHT}"
    else
        echo -e "${RED}服务重启失败，请检查日志！${RESET}"
    fi
}

# ================== 修改节点名称前缀 (HOST_NAME) 功能 ==================
change_hostname_menu() {
    if [[ ! -f "${SHOES_ENV_FILE}" ]] || [[ ! -f "${SHOES_CONF_FILE}" ]]; then
        echo -e "\n${RED}错误：未检测到已安装的配置文件，请先执行安装！${RESET}"
        return
    fi

    source "${SHOES_ENV_FILE}"
    [[ -z "$ANYTLS_SNI" ]] && ANYTLS_SNI="cdn.cloudflare.net"

    clear
    echo -e "${LINE_HEAVY}"
    echo -e "  ${CYAN}修改节点名称前缀 (HOST_NAME)${RESET}"
    echo -e "${LINE_HEAVY}"
    echo -e "  ${GRAY}当前前缀 :${RESET} ${GREEN}${HOST_NAME}${RESET}"
    echo -e "  ${GRAY}预览效果 :${RESET} ${WHITE}${HOST_NAME}-SS${RESET} ${GRAY}/${RESET} ${WHITE}${HOST_NAME}-Reality${RESET} ${GRAY}/${RESET} ${WHITE}${HOST_NAME}-AnyTLS${RESET}"
    echo -e "${LINE_LIGHT}"
    echo -e "  ${GRAY}提示：输入 ${CYAN}0${GRAY} 恢复系统主机名 ($(hostname))，直接回车取消修改 (支持中文与国旗 Emoji)。${RESET}"
    echo ""
    echo -ne "  ${WHITE}请输入新的节点名称前缀 (如 HK-BGP 或 IKuuu-广电1 🇭🇰): ${RESET}"
    read -r new_name

    new_name=$(echo "$new_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '#?&"')

    if [[ -z "$new_name" ]]; then
        echo -e "\n${YELLOW}未输入内容，已取消修改。${RESET}"
        return
    elif [[ "$new_name" == "0" ]]; then
        HOST_NAME=$(hostname)
        [[ -z "$HOST_NAME" ]] && HOST_NAME="ShoeServer"
        echo -e "\n${GREEN}--> 已恢复为系统默认主机名: ${HOST_NAME}${RESET}"
    else
        HOST_NAME="$new_name"
        echo -e "\n${GREEN}--> 节点名称前缀已更新为: ${HOST_NAME}${RESET}"
    fi

    write_shoes_configs
    generate_links

    echo -e "${GREEN}节点订阅链接已无缝刷新（自动完成标准 URI 编码，无需重启服务）：${RESET}"
    echo -e "${LINE_LIGHT}"
    cat "${SHOES_LINK_FILE}"
    echo -e "${LINE_LIGHT}"
}

# ================== 动态 IP 刷新与连接地址 (DDNS) 管理 ==================
change_connect_host_menu() {
    if [[ ! -f "${SHOES_ENV_FILE}" ]] || [[ ! -f "${SHOES_CONF_FILE}" ]]; then
        echo -e "\n${RED}错误：未检测到已安装的配置文件，请先执行安装！${RESET}"
        return
    fi

    while true; do
        source "${SHOES_ENV_FILE}"
        [[ -z "$ANYTLS_SNI" ]] && ANYTLS_SNI="cdn.cloudflare.net"
        local live_v4 live_v6 rec_v4 rec_v6 v4_cell v6_cell v4_stat v6_stat
        live_v4=$(get_public_ipv4)
        live_v6=$(get_public_ipv6)
        CACHED_LIVE_V4="$live_v4"
        CACHED_LIVE_V6="$live_v6"
        rec_v4="${LAST_IPV4:-$(extract_link_ipv4)}"
        rec_v6="${LAST_IPV6:-$(extract_link_ipv6)}"

        if [[ -n "$CONNECT_HOST" ]]; then
            v4_cell="${CYAN}$(shorten_middle "$CONNECT_HOST" 22)${RESET}"
            v4_stat="${CYAN}● 固定地址${RESET}"
            [[ -n "$live_v4" ]] && v4_stat="${CYAN}● 固定${RESET} ${GRAY}(公网 ${live_v4})${RESET}"
            if (( $(str_display_width "$v4_stat") > 24 )); then
                v4_stat="${CYAN}● DDNS / 固定地址模式${RESET}"
            fi
        else
            v4_cell="${WHITE}${live_v4:-${rec_v4:-未获取}}${RESET}"
            if [[ -n "$live_v4" ]] && [[ "$live_v4" == "$rec_v4" ]]; then
                v4_stat="${GREEN}● 动态追踪 (已同步)${RESET}"
            elif [[ -n "$live_v4" ]]; then
                v4_stat="${YELLOW}● 待刷新 (${rec_v4:-无})${RESET}"
            else
                v4_stat="${RED}○ 公网探测超时${RESET}"
            fi
        fi

        if [[ -n "$live_v6" ]]; then
            v6_cell="${WHITE}$(format_ipv6_short "$live_v6" 22)${RESET}"
            if [[ "$live_v6" == "$rec_v6" ]]; then
                v6_stat="${GREEN}● 动态追踪 (仅SS节点)${RESET}"
            else
                v6_stat="${YELLOW}● 检测到新 IPv6 待刷新${RESET}"
            fi
        else
            v6_cell="${GRAY}未分配 / 纯 IPv4 环境${RESET}"
            v6_stat="${GRAY}— 未启用 IPv6 节点${RESET}"
        fi

        clear
        echo -e "${LINE_HEAVY}"
        echo -e "  ${CYAN}动态 IP 同步与节点连接地址设置${RESET}"
        echo -e "${LINE_HEAVY}"
        echo -e "  ${GRAY}╭──────────┬─────────────────────────┬──────────────────────────╮${RESET}"
        print_ip_table_row "${GRAY}地址类型${RESET}" "${GRAY}当前节点地址 / 实时公网${RESET}" "${GRAY}追踪模式与同步状态${RESET}"
        echo -e "  ${GRAY}├──────────┼─────────────────────────┼──────────────────────────┤${RESET}"
        print_ip_table_row "${CYAN}IPv4${RESET}" "$v4_cell" "$v4_stat"
        print_ip_table_row "${CYAN}IPv6${RESET}" "$v6_cell" "$v6_stat"
        echo -e "  ${GRAY}╰──────────┴─────────────────────────┴──────────────────────────╯${RESET}"
        [[ -n "$live_v6" ]] && (( ${#live_v6} > 22 )) && echo -e "  ${GRAY}完整 IPv6 : ${live_v6}${RESET}"
        echo -e "${LINE_LIGHT}"
        echo -e "  ${CYAN}1.${RESET} ${WHITE}立即强制刷新动态公网 IP${RESET}  ${GRAY}— 重新探测 IPv4/IPv6 并重写订阅链接${RESET}"
        echo -e "  ${CYAN}2.${RESET} ${WHITE}绑定 DDNS 域名/指定地址${RESET}  ${GRAY}— 填入 DDNS 域名，换 IP 免重导订阅${RESET}"
        echo -e "  ${CYAN}3.${RESET} ${WHITE}恢复自动追踪动态 IP 模式${RESET} ${GRAY}— 清除自定义域名，跟随实时公网 IP${RESET}"
        echo -e "${LINE_LIGHT}"
        echo -e "  ${CYAN}0.${RESET} ${WHITE}返回上级菜单${RESET}"
        echo -e "${LINE_HEAVY}"
        echo -ne "  ${WHITE}请选择操作 [0-3]: ${RESET}"
        read -r addr_choice

        case "$addr_choice" in
            1)
                echo -e "\n${YELLOW}--> 正在强制重新探测公网 IP 并刷新节点链接...${RESET}"
                generate_links
                setup_ip_sync_timer "quiet"
                echo -e "${GREEN}节点链接已强制更新！${RESET}"
                echo -e "${LINE_LIGHT}"
                cat "${SHOES_LINK_FILE}"
                echo -e "${LINE_LIGHT}"
                echo "" && read -n 1 -s -r -p "按任意键继续..."
                ;;
            2)
                echo ""
                echo -ne "  ${WHITE}请输入 DDNS 域名或指定连接 IP (直接回车取消): ${RESET}"
                read -r custom_host
                custom_host=$(echo "$custom_host" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##; s#:[0-9]+$##; s#\.*$##')
                if [[ -z "$custom_host" ]]; then
                    echo -e "  ${YELLOW}未输入内容，已取消修改。${RESET}"
                    sleep 1
                    continue
                fi
                if ! [[ "$custom_host" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                    echo -e "  ${RED}错误：输入的域名或 IP 格式无效！${RESET}"
                    sleep 1.5
                    continue
                fi
                CONNECT_HOST="$custom_host"
                save_env_file
                generate_links
                echo -e "\n${GREEN}--> 已绑定连接地址为: ${CONNECT_HOST} (无需重启服务)${RESET}"
                echo -e "${LINE_LIGHT}"
                cat "${SHOES_LINK_FILE}"
                echo -e "${LINE_LIGHT}"
                echo "" && read -n 1 -s -r -p "按任意键继续..."
                ;;
            3)
                CONNECT_HOST=""
                save_env_file
                echo -e "\n${YELLOW}--> 已切换回自动追踪动态公网 IP 模式，正在同步当前 IP...${RESET}"
                generate_links
                setup_ip_sync_timer "quiet"
                echo -e "${LINE_LIGHT}"
                cat "${SHOES_LINK_FILE}"
                echo -e "${LINE_LIGHT}"
                echo "" && read -n 1 -s -r -p "按任意键继续..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入！${RESET}"
                sleep 1
                ;;
        esac
    done
}

# ================== 证书管理 ==================
update_certificate() {
    echo -e "\n${YELLOW}--> 正在重新生成 TLS 证书...${RESET}"
    if [[ ! -d "${SHOES_CONF_DIR}" ]] || [[ ! -f "${SHOES_ENV_FILE}" ]]; then
        echo -e "${RED}错误：配置目录不存在或缺失环境文件，请先进行安装部署！${RESET}"
        return
    fi
    
    source "${SHOES_ENV_FILE}"
    [[ -z "$ANYTLS_SNI" ]] && ANYTLS_SNI="cdn.cloudflare.net"
    
    [[ -f "${SHOES_CONF_DIR}/key.pem" ]] && cp -a "${SHOES_CONF_DIR}/key.pem" "${SHOES_CONF_DIR}/key.pem.bak"
    [[ -f "${SHOES_CONF_DIR}/cert.pem" ]] && cp -a "${SHOES_CONF_DIR}/cert.pem" "${SHOES_CONF_DIR}/cert.pem.bak"

    openssl ecparam -genkey -name prime256v1 -out "${SHOES_CONF_DIR}/key.pem"
    openssl req -new -x509 -days 365 -key "${SHOES_CONF_DIR}/key.pem" -out "${SHOES_CONF_DIR}/cert.pem" -subj "/CN=${ANYTLS_SNI}" -addext "subjectAltName=DNS:${ANYTLS_SNI}" >/dev/null 2>&1
    chmod 600 "${SHOES_CONF_DIR}/key.pem" 2>/dev/null || true

    echo -e "${YELLOW}--> 正在重启服务以应用新证书...${RESET}"
    systemctl restart shoes
    
    if check_running; then
        echo -e "${GREEN}服务已重启，新自签证书已生效。正在更新节点链接...${RESET}"
        generate_links
        echo -e "${GREEN}节点链接已同步更新！您可以返回主菜单查看。${RESET}"
    else
        echo -e "${RED}服务重启失败，正在自动回滚旧证书...${RESET}"
        [[ -f "${SHOES_CONF_DIR}/key.pem.bak" ]] && mv -f "${SHOES_CONF_DIR}/key.pem.bak" "${SHOES_CONF_DIR}/key.pem"
        [[ -f "${SHOES_CONF_DIR}/cert.pem.bak" ]] && mv -f "${SHOES_CONF_DIR}/cert.pem.bak" "${SHOES_CONF_DIR}/cert.pem"
        systemctl restart shoes
    fi
}

# ================== 服务管理子菜单 (无损更新与纯净卸载) ==================
update_core() {
    echo -e "\n${YELLOW}--> 正在执行无损预检与更新 Shoes 核心...${RESET}"
    if download_shoes_smart "force"; then
        if check_installed; then
            systemctl restart shoes
            sleep 1
            if check_running; then
                echo -e "${GREEN}核心平滑更新并重启成功！当前运行版本: $(get_local_version)${RESET}"
            else
                echo -e "${RED}核心已替换，但服务启动异常，请通过日志排查！${RESET}"
            fi
        fi
    else
        echo -e "${YELLOW}更新未执行或未通过预检，原有运行中的节点服务未受任何中断。${RESET}"
    fi
}

uninstall_shoes() {
    echo -e "\n${YELLOW}--> 正在停止并卸载 Shoes 服务...${RESET}"
    if [[ -f "${SHOES_ENV_FILE}" ]]; then
        source "${SHOES_ENV_FILE}"
        local fw_type
        fw_type=$(detect_firewall)
        if [[ "$fw_type" != "none" ]]; then
            echo -e "${YELLOW}--> 正在清理防火墙 (${fw_type}) 节点端口放行规则...${RESET}"
            fw_close_port "$SS_PORT" "$fw_type"
            fw_close_port "$VLESS_PORT" "$fw_type"
            fw_close_port "$ANYTLS_PORT" "$fw_type"
            fw_reload_save "$fw_type"
        fi
    fi
    systemctl stop shoes-ip-sync.timer shoes-ip-sync.service >/dev/null 2>&1
    systemctl disable shoes-ip-sync.timer shoes-ip-sync.service >/dev/null 2>&1
    rm -f "${IP_SYNC_TIMER}" "${IP_SYNC_SERVICE}" "${IP_SYNC_BIN}"
    systemctl stop shoes >/dev/null 2>&1
    systemctl disable shoes >/dev/null 2>&1
    rm -f "${SYSTEMD_FILE}"
    rm -rf "${SHOES_CONF_DIR}" "${TMP_DIR}"
    rm -f "${SHOES_BIN}" "${SHOES_BIN}.new"
    # 仅移除 Shoes 专属调优文件，保留系统全局 /etc/sysctl.d/99-bbr-optimization.conf 不受影响
    rm -f "${LIMITS_CONF}" "${SYSCTL_CONF}"
    systemctl daemon-reload
    echo -e "${GREEN}Shoes 及其相关配置与防火墙规则已完全卸载 (系统原有 BBR 配置已完整保留)。${RESET}"
}

# 渲染双栈动态地址状态表格
render_address_table() {
    local v4_addr="未配置" v4_stat="${GRAY}— 等待安装部署${RESET}"
    local v6_addr="未配置" v6_stat="${GRAY}— 等待安装部署${RESET}"

    if [[ -f "${SHOES_ENV_FILE}" ]]; then
        local env_conn env_v4 env_v6
        env_conn=$(grep '^CONNECT_HOST=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
        env_v4=$(grep '^LAST_IPV4=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
        env_v6=$(grep '^LAST_IPV6=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
        [[ -z "$env_v4" ]] && env_v4=$(extract_link_ipv4)
        [[ -z "$env_v6" ]] && env_v6=$(extract_link_ipv6)
        [[ -z "$env_v4" && -n "$CACHED_LIVE_V4" ]] && env_v4="$CACHED_LIVE_V4"
        [[ -z "$env_v6" && -n "$CACHED_LIVE_V6" ]] && env_v6="$CACHED_LIVE_V6"

        if [[ -n "$env_conn" ]]; then
            v4_addr="${CYAN}$(shorten_middle "$env_conn" 22)${RESET}"
            v4_stat="${CYAN}● DDNS / 固定地址${RESET}"
        elif [[ -n "$env_v4" ]]; then
            v4_addr="${WHITE}${env_v4}${RESET}"
            if [[ "$SYNC_V4_CHANGED" -eq 1 ]]; then
                local old_s4
                old_s4=$(compact_old_ipv4 "$SYNC_V4_OLD" "$env_v4")
                v4_stat="${GREEN}✔ 已更新${RESET} ${GRAY}(${old_s4})${RESET}"
            else
                v4_stat="${GREEN}● 动态追踪 (每5分巡检)${RESET}"
            fi
        else
            v4_addr="${YELLOW}未获取${RESET}"
            v4_stat="${YELLOW}○ 等待公网探测${RESET}"
        fi

        if [[ -n "$env_v6" ]]; then
            v6_addr="${WHITE}$(format_ipv6_short "$env_v6" 22)${RESET}"
            if [[ "$SYNC_V6_CHANGED" -eq 1 ]]; then
                local old_s6
                old_s6=$(compact_old_ipv6 "$SYNC_V6_OLD")
                v6_stat="${GREEN}✔ 已更新${RESET} ${GRAY}(${old_s6})${RESET}"
            else
                v6_stat="${GREEN}● 动态追踪 (仅SS节点)${RESET}"
            fi
        else
            if [[ "$SYNC_V6_CHANGED" -eq 1 ]] && [[ -n "$SYNC_V6_OLD" ]]; then
                v6_addr="${YELLOW}已失效 / 无 IPv6${RESET}"
                v6_stat="${YELLOW}✔ 已移除旧 IPv6 节点${RESET}"
            else
                v6_addr="${GRAY}未分配 / 纯 IPv4 环境${RESET}"
                v6_stat="${GRAY}— 未启用 IPv6 节点${RESET}"
            fi
        fi
    else
        if [[ -n "$CACHED_LIVE_V4" ]]; then
            v4_addr="${WHITE}${CACHED_LIVE_V4}${RESET}"
            v4_stat="${CYAN}○ 实时公网 (待部署)${RESET}"
        else
            v4_addr="${YELLOW}无法获取${RESET}"
            v4_stat="${RED}○ 公网探测超时${RESET}"
        fi

        if [[ -n "$CACHED_LIVE_V6" ]]; then
            v6_addr="${WHITE}$(format_ipv6_short "$CACHED_LIVE_V6" 22)${RESET}"
            v6_stat="${CYAN}○ 实时公网 (待部署)${RESET}"
        else
            v6_addr="${GRAY}未分配 / 纯 IPv4 环境${RESET}"
            v6_stat="${GRAY}— 无全局 IPv6${RESET}"
        fi
    fi

    echo -e "  ${GRAY}╭──────────┬─────────────────────────┬──────────────────────────╮${RESET}"
    print_ip_table_row "${GRAY}地址类型${RESET}" "${GRAY}当前生效地址${RESET}" "${GRAY}动态同步与状态${RESET}"
    echo -e "  ${GRAY}├──────────┼─────────────────────────┼──────────────────────────┤${RESET}"
    print_ip_table_row "${CYAN}IPv4${RESET}" "$v4_addr" "$v4_stat"
    print_ip_table_row "${CYAN}IPv6${RESET}" "$v6_addr" "$v6_stat"
    echo -e "  ${GRAY}╰──────────┴─────────────────────────┴──────────────────────────╯${RESET}"

    SYNC_V4_CHANGED=0
    SYNC_V6_CHANGED=0
}

service_menu() {
    while true; do
        clear
        local cur_sni="未配置"
        local cur_host="未配置"
        local cur_cipher="未配置"
        if [[ -f "${SHOES_ENV_FILE}" ]]; then
            cur_sni=$(grep '^SNI=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
            cur_host=$(grep '^HOST_NAME=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
            cur_cipher=$(grep '^SS_METHOD=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
        fi
        local ver_str ver_disp run_disp
        ver_str=$(get_local_version)
        ver_disp=$( [[ "$ver_str" == "未安装" ]] && echo "${YELLOW}${ver_str}${RESET}" || echo "${CYAN}${ver_str}${RESET}" )
        run_disp=$( check_running && echo "${GREEN}● 运行中${RESET}" || echo "${RED}○ 未运行${RESET}" )

        echo -e "${LINE_HEAVY}"
        echo -e "  ${CYAN}E-Shoes 节点与服务管理${RESET}"
        echo -e "${LINE_HEAVY}"
        print_kv_2col "${GRAY}核心版本 :${RESET} ${ver_disp}" "${GRAY}运行状态 :${RESET} ${run_disp}"
        print_kv_2col "${GRAY}伪装域名 :${RESET} ${WHITE}$(shorten_middle "$cur_sni" 18)${RESET}" "${GRAY}节点前缀 :${RESET} ${WHITE}$(shorten_middle "$cur_host" 18)${RESET}"
        render_address_table
        echo -e "  ${CYAN}1.${RESET} ${WHITE}更新核心版本${RESET}  ${GRAY}— 沙盒无损预检并平滑升级 Shoes (v0.3.8+)${RESET}"
        echo -e "  ${CYAN}2.${RESET} ${WHITE}卸载节点服务${RESET}  ${GRAY}— 彻底清理程序、配置及放行规则 (保留BBR)${RESET}"
        echo -e "  ${CYAN}3.${RESET} ${WHITE}启动节点服务${RESET}  ${GRAY}— 启动 Shoes 系统守护进程${RESET}"
        echo -e "  ${CYAN}4.${RESET} ${WHITE}停止节点服务${RESET}  ${GRAY}— 停止 Shoes 系统守护进程${RESET}"
        echo -e "  ${CYAN}5.${RESET} ${WHITE}重启节点服务${RESET}  ${GRAY}— 重新加载配置并重启进程${RESET}"
        echo -e "  ${CYAN}6.${RESET} ${WHITE}重签自签证书${RESET}  ${GRAY}— 重新生成 AnyTLS 365天证书${RESET}"
        echo -e "${LINE_LIGHT}"
        echo -e "  ${CYAN}7.${RESET} ${WHITE}修改协议端口${RESET}  ${GRAY}— 单独或随机换端口，自动同步防火墙${RESET}"
        echo -e "  ${CYAN}8.${RESET} ${WHITE}修改伪装域名${RESET}  ${GRAY}— 切换预设/自定义 Reality 与 AnyTLS${RESET}"
        echo -e "  ${CYAN}9.${RESET} ${WHITE}修改节点前缀${RESET}  ${GRAY}— 自定义节点别名 (自动URI编码，免重启)${RESET}"
        echo -e " ${CYAN}10.${RESET} ${WHITE}设置节点地址${RESET}  ${GRAY}— 强制刷新动态 IP 或绑定 DDNS 域名${RESET}"
        echo -e " ${CYAN}11.${RESET} ${WHITE}切换SS加密法${RESET}  ${GRAY}— 切换 128-GCM / 256-GCM (${cur_cipher#2022-blake3-})${RESET}"
        echo -e "${LINE_LIGHT}"
        echo -e "  ${CYAN}0.${RESET} ${WHITE}返回上级菜单${RESET}"
        echo -e "${LINE_HEAVY}"
        echo -ne "  ${WHITE}请选择操作 [0-11]: ${RESET}"
        read -r sub_choice

        case "$sub_choice" in
            1) update_core; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2) uninstall_shoes; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3) systemctl start shoes; echo -e "\n${GREEN}服务已启动${RESET}"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            4) systemctl stop shoes; echo -e "\n${RED}服务已停止${RESET}"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            5) systemctl restart shoes; echo -e "\n${GREEN}服务已重启${RESET}"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            6) update_certificate; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            7) change_ports_menu ;;
            8) change_sni_menu ;;
            9) change_hostname_menu; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            10) change_connect_host_menu ;;
            11) change_ss_cipher_menu; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
            *) echo -e "${RED}无效选项，请重新输入！${RESET}"; sleep 1 ;;
        esac
    done
}

# ================== 主菜单 ==================
show_main_menu() {
    clear
    local fw_status ver_str inst_disp run_disp ver_disp fw_disp
    fw_status=$(detect_firewall)
    ver_str=$(get_local_version)
    inst_disp=$( check_installed && echo "${GREEN}● 已安装${RESET}" || echo "${YELLOW}○ 未安装${RESET}" )
    run_disp=$( check_running && echo "${GREEN}● 运行中${RESET}" || echo "${RED}○ 未运行${RESET}" )
    ver_disp=$( [[ "$ver_str" == "未安装" ]] && echo "${YELLOW}${ver_str}${RESET}" || echo "${CYAN}${ver_str}${RESET}" )
    fw_disp=$( [[ "$fw_status" == "none" ]] && echo "${GREEN}● 未启用 (全放行)${RESET}" || echo "${YELLOW}● ${fw_status} (运行中)${RESET}" )

    echo -e "${LINE_HEAVY}"
    echo -e "  ${CYAN}E-Shoes 代理节点一键管理脚本${RESET} ${GRAY}v4.6.1${RESET}"
    echo -e "${LINE_HEAVY}"
    print_kv_2col "${GRAY}服务状态 :${RESET} ${inst_disp}" "${GRAY}运行状态 :${RESET} ${run_disp}"
    print_kv_2col "${GRAY}核心版本 :${RESET} ${ver_disp}" "${GRAY}防护状态 :${RESET} ${fw_disp}"
    render_address_table
    echo -e "  ${CYAN}1.${RESET} ${WHITE}全新安装部署${RESET}  ${GRAY}— 随机分配 >20300 端口并自动放行${RESET}"
    echo -e "  ${CYAN}2.${RESET} ${WHITE}修复系统环境${RESET}  ${GRAY}— 保留原有节点配置、校准密钥与防火墙${RESET}"
    echo -e "  ${CYAN}3.${RESET} ${WHITE}节点服务管理${RESET}  ${GRAY}— 无损更新 / 改端口 / 改SNI / 切换加密${RESET}"
    echo -e "  ${CYAN}4.${RESET} ${WHITE}查看节点链接${RESET}  ${GRAY}— 实时校准双栈动态 IP 并输出订阅${RESET}"
    echo -e "  ${CYAN}5.${RESET} ${WHITE}查看实时日志${RESET}  ${GRAY}— 追踪 Shoes 核心运行状态与排错${RESET}"
    echo -e "${LINE_LIGHT}"
    echo -e "  ${CYAN}0.${RESET} ${WHITE}退出管理脚本${RESET}"
    echo -e "${LINE_HEAVY}"
    echo -ne "  ${WHITE}请选择操作 [0-5]: ${RESET}"
    read -r choice
}

require_root
ensure_base_deps

# 支持 systemd 定时器后台静默调用: shoes-ip-sync --sync-ip
if [[ "$1" == "--sync-ip" ]]; then
    sync_dynamic_ip "cron"
    exit 0
fi

# 启动面板时自动校准一次动态公网 IP
sync_dynamic_ip "startup"

while true; do
    show_main_menu
    case "$choice" in
        1) 
            install_shoes "new"
            echo "" && read -n 1 -s -r -p "按任意键继续..." 
            ;;
        2) 
            install_shoes "keep"
            echo "" && read -n 1 -s -r -p "按任意键继续..." 
            ;;
        3) 
            service_menu 
            ;;
        4) 
            if sync_dynamic_ip "verbose" && [[ -f "${SHOES_LINK_FILE}" ]]; then
                echo -e "\n${LINE_HEAVY}"
                echo -e "  ${CYAN}当前节点配置链接${RESET} ${GRAY}(文件: ${SHOES_LINK_FILE})${RESET}"
                echo -e "${LINE_HEAVY}"
                cat "${SHOES_LINK_FILE}"
                echo -e "${LINE_LIGHT}"
            fi
            echo "" && read -n 1 -s -r -p "按任意键继续..." 
            ;;
        5) 
            echo -e "\n${YELLOW}--> 按 Ctrl+C 退出日志查看${RESET}"
            journalctl -u shoes -f 
            ;;
        0) 
            echo -e "已退出脚本。"
            exit 0 
            ;;
        *) 
            echo -e "${RED}无效选项，请重新输入！${RESET}"; sleep 1 ;;
    esac
done

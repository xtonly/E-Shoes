#!/bin/bash

# ================== 颜色代码与风格统一 ==================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

# ================== 常量定义 ==================
SHOES_BIN="/usr/local/bin/shoes"
SHOES_CONF_DIR="/etc/shoes"
SHOES_CONF_FILE="${SHOES_CONF_DIR}/config.yaml"
SHOES_LINK_FILE="${SHOES_CONF_DIR}/config.txt"
SHOES_ENV_FILE="${SHOES_CONF_DIR}/.env"
SYSTEMD_FILE="/etc/systemd/system/shoes.service"
TMP_DIR="/tmp/shoesdl"

# 端口范围常量：严格限制在 20300 之后 (20301 - 60000)
PORT_MIN=20301
PORT_MAX=60000

# ================== Root 检查 ==================
require_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}错误：请使用 root 用户运行此脚本${RESET}"; exit 1; }
}

# ================== 辅助函数 ==================
check_installed() { [[ -f "$SHOES_BIN" ]] && [[ -f "$SYSTEMD_FILE" ]]; }
check_running() { systemctl is-active --quiet shoes; }

get_local_version() {
    if [[ -x "$SHOES_BIN" ]]; then
        "$SHOES_BIN" --version 2>/dev/null | awk '{print $2}' || echo "未知"
    else
        echo "未安装"
    fi
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

# ================== 智能防火墙探测与自动放行模块 ==================
detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw"
        return
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"
        return
    fi
    if command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null; then
        if nft list tables 2>/dev/null | grep -q .; then
            echo "nftables"
            return
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        if iptables -S INPUT 2>/dev/null | grep -qE "^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)"; then
            echo "iptables"
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
            nft_info=$(nft list ruleset 2>/dev/null | awk '/table /{t=$2; f=$3} /hook input/{print t, f; exit}')
            if [[ -n "$nft_info" ]]; then
                local fam=$(echo "$nft_info" | awk '{print $1}')
                local tab=$(echo "$nft_info" | awk '{print $2}')
                nft insert rule "$fam" "$tab" input tcp dport "$port" counter accept comment \"Shoes-Proxy\" >/dev/null 2>&1
                nft insert rule "$fam" "$tab" input udp dport "$port" counter accept comment \"Shoes-Proxy\" >/dev/null 2>&1
            fi
            ;;
        iptables)
            for cmd in iptables ip6tables; do
                if command -v "$cmd" >/dev/null 2>&1; then
                    "$cmd" -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || "$cmd" -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
                    "$cmd" -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || "$cmd" -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
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
            nft_info=$(nft list ruleset 2>/dev/null | awk '/table /{t=$2; f=$3} /hook input/{print t, f; exit}')
            if [[ -n "$nft_info" ]]; then
                local fam=$(echo "$nft_info" | awk '{print $1}')
                local tab=$(echo "$nft_info" | awk '{print $2}')
                local handles
                handles=$(nft -a list chain "$fam" "$tab" input 2>/dev/null | grep -E "dport ${port} .*Shoes-Proxy" | awk '{print $NF}')
                for h in $handles; do
                    nft delete rule "$fam" "$tab" input handle "$h" >/dev/null 2>&1
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
        firewalld)
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        iptables)
            command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
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
        echo -e "${GREEN}未检测到启用中的防火墙 (或默认策略为全放行)，保持系统现状。${RESET}"
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
    echo -e "${YELLOW}--> 正在强制同步服务器时间 (SS-2022 精准时间)...${RESET}"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true >/dev/null 2>&1
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y chrony >/dev/null 2>&1
        systemctl restart chronyd >/dev/null 2>&1
        chronyc makestep >/dev/null 2>&1
    fi
    echo -e "${GREEN}时间同步完成，当前服务器时间: $(date)${RESET}"
}

# === 智能 IP 获取 ===
get_public_ipv4() {
    local ip=""
    for url in "http://checkip.amazonaws.com" "http://ifconfig.me/ip" "http://api.ipify.org"; do
        ip=$(curl -s -4 --max-time 5 "$url" | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    echo ""
}

get_public_ipv6() {
    local ip=""
    for url in "http://ifconfig.co/ip" "http://icanhazip.com" "http://api64.ipify.org"; do
        ip=$(curl -s -6 --max-time 5 "$url" | tr -d '[:space:]')
        if [[ "$ip" == *":"* ]] && [[ "$ip" != *"<"* ]]; then
            echo "$ip"
            return
        fi
    done
    echo ""
}

# ================== 配置文件写入函数 ==================
write_shoes_configs() {
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
EOF

    if ip a | grep -qw inet6; then
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

# ================== 节点链接生成函数 (VLESS 与 AnyTLS 仅保留 IPv4) ==================
generate_links() {
    HOST_IP=$(get_public_ipv4)
    HOST_IPV6=$(get_public_ipv6)

    if [[ -z "$HOST_IP" ]]; then
        echo -e "${RED}警告：无法自动获取 IPv4 地址，链接中将使用占位符。${RESET}"
        HOST_IP="YOUR_IPV4_HERE"
    else
        echo -e "${GREEN}成功获取 IPv4: ${HOST_IP}${RESET}"
    fi

    [[ -n "$HOST_IPV6" ]] && echo -e "${GREEN}成功获取 IPv6: ${HOST_IPV6}${RESET} (仅用于 SS2022 置顶节点)"

    SS_LINK_BASE=$(echo -n "${SS_METHOD}:${SS_PASSWORD}" | base64 -w 0 | tr -d '\n')

    # 1. 置顶输出 Shadowsocks-2022 (支持 IPv4 & IPv6)
    cat > "${SHOES_LINK_FILE}" <<EOF
# ==================== [置顶] Shadowsocks-2022 ====================
# SS2022 (IPv4)
ss://${SS_LINK_BASE}@${HOST_IP}:${SS_PORT}#${HOST_NAME}-SS2022-v4
EOF

    if [[ -n "$HOST_IPV6" ]]; then
        cat >> "${SHOES_LINK_FILE}" <<EOF
# SS2022 (IPv6)
ss://${SS_LINK_BASE}@[${HOST_IPV6}]:${SS_PORT}#${HOST_NAME}-SS2022-v6
EOF
    fi

    # 2. 其他协议分组：VLESS-Reality (仅保留 IPv4)
    cat >> "${SHOES_LINK_FILE}" <<EOF

# ==================== [分组 1] VLESS-Reality ====================
# Reality (IPv4)
vless://${UUID}@${HOST_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHID}&spx=%2F&type=tcp#${HOST_NAME}-Reality-v4
EOF

    # 3. 其他协议分组：AnyTLS (仅保留 IPv4)
    cat >> "${SHOES_LINK_FILE}" <<EOF

# ==================== [分组 2] AnyTLS ====================
# AnyTLS (IPv4)
anytls://${PUBLIC_KEY}@${HOST_IP}:${ANYTLS_PORT}?security=tls&sni=${ANYTLS_SNI}&allowInsecure=1&insecure=1&type=tcp#${HOST_NAME}-AnyTLS-v4
EOF
}

# ================== 架构检测与下载 ==================
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
            echo -e "${RED}不支持的 CPU 架构！${RESET}"
            exit 1
            ;;
    esac
}

get_latest_version() {
    LATEST_VER=$(curl -s --connect-timeout 10 https://api.github.com/repos/cfal/shoes/releases/latest \
        | grep '"tag_name":' \
        | sed -E 's/.*"v?([^"]+)".*/\1/')
    [[ -z "$LATEST_VER" ]] && {
        echo -e "${RED}无法获取 Shoes 最新版本，请检查网络！${RESET}"
        exit 1
    }
}

download_shoes_smart() {
    local force_update="$1"

    echo -e "${YELLOW}--> 正在准备 Shoes 核心文件...${RESET}"
    
    if [[ "$force_update" != "force" ]] && [[ -f "${SHOES_BIN}" ]]; then
        chmod +x "${SHOES_BIN}"
        if ${SHOES_BIN} --version >/dev/null 2>&1; then
            echo -e "${GREEN}检测到当前核心可用 ($(get_local_version))，跳过下载。${RESET}"
            return
        fi
    fi

    rm -f "${SHOES_BIN}"
    get_latest_version
    check_arch
    mkdir -p "${TMP_DIR}"
    cd "${TMP_DIR}" || exit 1

    echo -e "${YELLOW}--> 尝试下载 GNU 版本 (v${LATEST_VER})...${RESET}"
    wget --timeout=15 --tries=3 -O shoes.tar.gz "https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${GNU_FILE}"
    
    if [[ -f shoes.tar.gz ]] && tar -xzf shoes.tar.gz 2>/dev/null; then
        mv shoes "${SHOES_BIN}"
        chmod +x "${SHOES_BIN}"
        if ${SHOES_BIN} --version >/dev/null 2>&1; then
            echo -e "${GREEN}GNU 版本运行正常！版本: $(${SHOES_BIN} --version)${RESET}"
            return
        fi
    fi

    echo -e "${RED}GNU 版本下载失败或无法运行，自动切换 MUSL 版本...${RESET}"
    rm -f "${SHOES_BIN}" shoes.tar.gz
    wget --timeout=15 --tries=3 -O shoes.tar.gz "https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${MUSL_FILE}"
    
    if [[ -f shoes.tar.gz ]] && tar -xzf shoes.tar.gz 2>/dev/null; then
        mv shoes "${SHOES_BIN}"
        chmod +x "${SHOES_BIN}"
        if ${SHOES_BIN} --version >/dev/null 2>&1; then
            echo -e "${GREEN}MUSL 版本运行正常！版本: $(${SHOES_BIN} --version)${RESET}"
            return
        fi
    fi
    
    echo -e "${RED}严重错误：所有版本下载均失败或无法运行！请检查服务器网络与 GitHub 的连接状况。${RESET}"
    exit 1
}

# ================== 核心安装逻辑 (全自动流程不变) ==================
install_shoes() {
    local install_mode="$1"
    clear
    echo -e "${CYAN}============= 开始部署 Shoes 代理节点 =============${RESET}"
    
    sync_system_time
    download_shoes_smart "normal"
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
        echo -e "${GREEN}--> 正在读取现有配置文件，检查端口与节点信息...${RESET}"
        source "${SHOES_ENV_FILE}"
        
        if [[ -z "$PRIVATE_KEY" ]]; then
            PRIVATE_KEY=$(grep 'private_key:' "${SHOES_CONF_FILE}" | head -n 1 | awk -F'"' '{print $2}')
        fi
        [[ -z "$HOST_NAME" ]] && HOST_NAME=$(hostname)
        
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

        if [[ -z "$SNI" ]] || [[ "$SNI" == "icloud.com" ]]; then
            SNI="www.apple.com"
            echo -e "${YELLOW}--> 已自动将旧的 Reality SNI (icloud.com) 升级为 ${SNI}${RESET}"
        fi
        
        SKIP_CERT=0
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
        KEYPAIR=$(${SHOES_BIN} generate-reality-keypair)
        PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "private key" | awk '{print $NF}')
        PUBLIC_KEY=$(echo "$KEYPAIR" | grep -i "public key" | awk '{print $NF}')
        SHID=$(openssl rand -hex 8)

        SS_METHOD="2022-blake3-aes-256-gcm"
        SS_PASSWORD=$(${SHOES_BIN} generate-shadowsocks-2022-password --cipher "${SS_METHOD}" 2>/dev/null | tail -n 1 | awk '{print $NF}')
        if [[ -z "$SS_PASSWORD" ]] || [[ ${#SS_PASSWORD} -lt 32 ]]; then
            SS_PASSWORD=$(openssl rand -base64 32 | tr -d '\n\r')
        fi
        SKIP_CERT=0
    fi

    if [[ "$SKIP_CERT" -eq 0 ]]; then
        echo -e "${YELLOW}--> 正在生成包含 SAN 扩展的自签 TLS 证书 (365天标准周期)...${RESET}"
        openssl ecparam -genkey -name prime256v1 -out "${SHOES_CONF_DIR}/key.pem"
        openssl req -new -x509 -days 365 -key "${SHOES_CONF_DIR}/key.pem" -out "${SHOES_CONF_DIR}/cert.pem" -subj "/CN=${ANYTLS_SNI}" -addext "subjectAltName=DNS:${ANYTLS_SNI}" >/dev/null 2>&1
    fi

    echo -e "${YELLOW}--> 正在检测服务器网络栈环境并写入配置...${RESET}"
    write_shoes_configs
    if [[ "$BIND_ADDR" == "[::]" ]]; then
        echo -e "${GREEN}检测到本地已开启 IPv6 协议栈，核心服务支持双栈监听 [::]${RESET}"
    else
        echo -e "${YELLOW}系统底层未开启 IPv6，将仅监听 IPv4 防止核心 Panic${RESET}"
    fi

    sync_firewall_ports "$OLD_SS_PORT" "$OLD_VLESS_PORT" "$OLD_ANYTLS_PORT"

    cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=Shoes Proxy Server
After=network.target

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

    echo -e "${YELLOW}--> 正在优化系统级文件描述符与网络参数...${RESET}"
    cat > /etc/security/limits.d/99-bbr-optimization.conf <<EOF
* soft nofile 65535
* hard nofile 1048576
root soft nofile 65535
root hard nofile 1048576
EOF

    cat > /etc/sysctl.d/99-bbr-optimization.conf <<'EOF'
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
        
        echo -e "\n${GREEN}Shoes 部署完成！当前分配端口均在 20300 之后：${RESET}"
        echo -e "  - ${CYAN}SS-2022 端口:${RESET} ${SS_PORT} (含 IPv4 & IPv6)"
        echo -e "  - ${CYAN}VLESS 端口:${RESET}   ${VLESS_PORT} (仅 IPv4)"
        echo -e "  - ${CYAN}AnyTLS 端口:${RESET}  ${ANYTLS_PORT} (仅 IPv4)"
        
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        cat "${SHOES_LINK_FILE}"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
    else
        echo -e "${RED}服务启动失败！以下为调试信息：${RESET}"
        ${SHOES_BIN} "${SHOES_CONF_FILE}"
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
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e "${CYAN}               修改协议端口 (限制 > 20300)               ${RESET}"
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e "  ${BLUE}防火墙状态:${RESET}   $( [[ "$fw_status" == "none" ]] && echo -e "${GREEN}未启用/全放行${RESET}" || echo -e "${YELLOW}${fw_status} (将自动同步放行新端口)${RESET}" )"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        echo -e "  1. 修改 ${GREEN}SS-2022${RESET} 端口       (当前: ${YELLOW}${SS_PORT}${RESET})"
        echo -e "  2. 修改 ${GREEN}VLESS-Reality${RESET} 端口 (当前: ${YELLOW}${VLESS_PORT}${RESET})"
        echo -e "  3. 修改 ${GREEN}AnyTLS${RESET} 端口        (当前: ${YELLOW}${ANYTLS_PORT}${RESET})"
        echo -e "  4. 一键随机更换所有协议端口 (${CYAN}20301-60000${RESET})"
        echo -e "  0. 返回上级菜单"
        echo -e "${MAGENTA}=========================================================${RESET}"
        read -p "  请选择要修改的选项 [0-4]: " p_choice

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
            echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
            cat "${SHOES_LINK_FILE}"
            echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        else
            echo -e "${RED}服务重启失败，请检查端口冲突或系统日志！${RESET}"
        fi
        echo "" && read -n 1 -s -r -p "按任意键继续..."
    done
}

# ================== 修改伪装域名 (SNI) 功能 ==================
change_sni_menu() {
    if [[ ! -f "${SHOES_ENV_FILE}" ]] || [[ ! -f "${SHOES_CONF_FILE}" ]]; then
        echo -e "\n${RED}错误：未检测到已安装的配置文件，请先执行安装！${RESET}"
        return
    fi

    source "${SHOES_ENV_FILE}"
    [[ -z "$ANYTLS_SNI" ]] && ANYTLS_SNI="cdn.cloudflare.net"

    while true; do
        clear
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e "${CYAN}               修改 Reality / AnyTLS 伪装域名            ${RESET}"
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e "  ${BLUE}当前 VLESS-Reality SNI:${RESET} ${GREEN}${SNI}${RESET}"
        echo -e "  ${BLUE}当前 AnyTLS 证书域名:${RESET}    ${GREEN}${ANYTLS_SNI}${RESET}"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        echo -e "  ${YELLOW}推荐 Reality 预设域名 (TLS 1.3 + H2 高信誉目标):${RESET}"
        echo "  1. www.apple.com           (Apple 全球静态节点，通用稳定)"
        echo "  2. dl.google.com           (Google 下载源，欧美/亚太推荐)"
        echo "  3. www.microsoft.com       (Microsoft 官网，全球双栈优选)"
        echo "  4. www.amd.com             (AMD 官网，高频 CDN 节点)"
        echo "  5. aws.amazon.com          (AWS 官网，AWS/欧美机房优选)"
        echo "  6. www.lovelive-anime.jp   (日本二次元站点，日本机房优选)"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        echo -e "  7. ${CYAN}手动输入自定义 Reality 伪装域名 (SNI)${RESET}"
        echo -e "  8. ${CYAN}修改 AnyTLS 自签证书域名 (并自动重签证书)${RESET}"
        echo "  0. 返回上级菜单"
        echo -e "${MAGENTA}=========================================================${RESET}"
        read -p "  请选择操作选项 [0-8]: " sni_choice

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
                custom_sni=$(echo "$custom_sni" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##')
                if [[ -z "$custom_sni" ]] || ! [[ "$custom_sni" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    echo -e "  ${RED}错误：域名格式无效，请重新输入！${RESET}"
                    sleep 1.5
                    continue
                fi
                new_sni="$custom_sni"
                ;;
            8)
                read -p "  请输入新的 AnyTLS 自签证书域名 [当前: ${ANYTLS_SNI}]: " custom_anytls
                custom_anytls=$(echo "$custom_anytls" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##')
                if [[ -z "$custom_anytls" ]] || ! [[ "$custom_anytls" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    echo -e "  ${RED}错误：域名格式无效，请重新输入！${RESET}"
                    sleep 1.5
                    continue
                fi
                if [[ "$custom_anytls" == "$SNI" ]]; then
                    echo -e "  ${RED}错误：AnyTLS 证书域名不能与 Reality SNI (${SNI}) 相同，以免暴露自签特征！${RESET}"
                    sleep 2
                    continue
                fi
                ANYTLS_SNI="$custom_anytls"
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
            echo -e "\n${YELLOW}--> 正在测试本机到 ${new_sni}:443 的 TLS 握手连通性...${RESET}"
            if timeout 5 openssl s_client -connect "${new_sni}:443" -servername "${new_sni}" </dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
                echo -e "${GREEN}--> 域名 ${new_sni}:443 TLS 证书校验通过！${RESET}"
            else
                echo -e "${YELLOW}警告：本机连接 ${new_sni}:443 超时或证书校验异常。${RESET}"
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
            echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
            cat "${SHOES_LINK_FILE}"
            echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        else
            echo -e "${RED}服务重启失败，请检查配置或系统日志！${RESET}"
        fi
        echo "" && read -n 1 -s -r -p "按任意键继续..."
    done
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
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e "${CYAN}               修改节点名称前缀 (HOST_NAME)              ${RESET}"
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e "  ${BLUE}当前节点名称前缀:${RESET} ${GREEN}${HOST_NAME}${RESET}"
    echo -e "  ${BLUE}生成后的节点示例:${RESET} ${YELLOW}${HOST_NAME}-SS2022-v4 / ${HOST_NAME}-Reality-v4${RESET}"
    echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
    echo -e "  提示：输入 ${CYAN}0${RESET} 可恢复为系统默认主机名 ($(hostname))，直接回车取消修改。"
    echo ""
    read -p "  请输入新的节点名称前缀 (如 HK-BGP 或 🇭🇰香港): " new_name

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

    echo -e "${GREEN}节点订阅链接已无缝刷新（无需重启服务）：${RESET}"
    echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
    cat "${SHOES_LINK_FILE}"
    echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
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
    
    [[ -f "${SHOES_CONF_DIR}/key.pem" ]] && mv "${SHOES_CONF_DIR}/key.pem" "${SHOES_CONF_DIR}/key.pem.bak"
    [[ -f "${SHOES_CONF_DIR}/cert.pem" ]] && mv "${SHOES_CONF_DIR}/cert.pem" "${SHOES_CONF_DIR}/cert.pem.bak"

    openssl ecparam -genkey -name prime256v1 -out "${SHOES_CONF_DIR}/key.pem"
    openssl req -new -x509 -days 365 -key "${SHOES_CONF_DIR}/key.pem" -out "${SHOES_CONF_DIR}/cert.pem" -subj "/CN=${ANYTLS_SNI}" -addext "subjectAltName=DNS:${ANYTLS_SNI}" >/dev/null 2>&1

    echo -e "${YELLOW}--> 正在重启服务以应用新证书...${RESET}"
    systemctl restart shoes
    
    if check_running; then
        echo -e "${GREEN}服务已重启，新自签证书已生效。正在更新节点链接...${RESET}"
        generate_links
        echo -e "${GREEN}节点链接已同步更新！您可以返回主菜单查看。${RESET}"
    else
        echo -e "${RED}服务重启失败，请检查系统日志！${RESET}"
    fi
}

# ================== 服务管理子菜单 ==================
update_core() {
    echo -e "\n${YELLOW}--> 正在更新 Shoes 核心...${RESET}"
    systemctl stop shoes
    download_shoes_smart "force"
    systemctl restart shoes
    echo -e "${GREEN}核心更新完成并已重启服务！当前版本: $(get_local_version)${RESET}"
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
    systemctl stop shoes >/dev/null 2>&1
    systemctl disable shoes >/dev/null 2>&1
    rm -f "${SYSTEMD_FILE}"
    rm -rf "${SHOES_CONF_DIR}"
    rm -f "${SHOES_BIN}"
    rm -f /etc/security/limits.d/99-bbr-optimization.conf
    rm -f /etc/sysctl.d/99-bbr-optimization.conf
    systemctl daemon-reload
    echo -e "${GREEN}Shoes 及其相关配置与防火墙规则已完全卸载。${RESET}"
}

service_menu() {
    while true; do
        clear
        local cur_sni="未配置"
        local cur_host="未配置"
        if [[ -f "${SHOES_ENV_FILE}" ]]; then
            cur_sni=$(grep '^SNI=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
            cur_host=$(grep '^HOST_NAME=' "${SHOES_ENV_FILE}" | awk -F'"' '{print $2}')
        fi
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e "${CYAN}                 Shoes 节点服务管理子菜单                ${RESET}"
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e " ${BLUE}当前核心版本:${RESET} $(get_local_version)"
        echo -e " ${BLUE}运行状态:${RESET}     $(check_running && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}")"
        echo -e " ${BLUE}当前伪装SNI:${RESET}  ${YELLOW}${cur_sni}${RESET}  |  ${BLUE}节点前缀:${RESET} ${YELLOW}${cur_host}${RESET}"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        echo "  1. 更新 Shoes 核心 (保留配置)"
        echo "  2. 卸载服务"
        echo "  3. 启动服务"
        echo "  4. 停止服务"
        echo "  5. 重启服务"
        echo "  6. 更新 TLS 证书 (自签证书)"
        echo -e "  7. 修改协议端口 (${GREEN}支持单独/随机更换，自动同步防火墙${RESET})"
        echo -e "  8. 修改伪装域名 (${CYAN}支持预设/自定义 Reality SNI 与 AnyTLS 域名${RESET})"
        echo -e "  9. 修改节点名称前缀 (${CYAN}自定义 HOST_NAME 别名，无需重启服务${RESET})"
        echo "  0. 返回主菜单"
        echo -e "${MAGENTA}=========================================================${RESET}"
        read -p "  请输入对应的数字选项: " sub_choice

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
            0) return ;;
            *) echo -e "${RED}无效选项，请重新输入！${RESET}"; sleep 1 ;;
        esac
    done
}

# ================== 主菜单 ==================
show_main_menu() {
    clear
    local fw_status
    fw_status=$(detect_firewall)
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e "${CYAN}            E-Shoes 代理节点一键管理脚本 4.2             ${RESET}"
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e " ${BLUE}服务状态:${RESET} $(check_installed && echo -e "${GREEN}已安装${RESET}" || echo -e "${YELLOW}未安装${RESET}")"
    echo -e " ${BLUE}核心版本:${RESET} $(get_local_version)"
    echo -e " ${BLUE}运行状态:${RESET} $(check_running && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}")"
    echo -e " ${BLUE}防火墙:${RESET}   $( [[ "$fw_status" == "none" ]] && echo -e "${GREEN}未启用/全放行${RESET}" || echo -e "${YELLOW}${fw_status} (运行中)${RESET}" )"
    echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
    echo -e "  1. 全新安装/重置密钥与端口 (${RED}自动分配 > 20300，自动放行${RESET})"
    echo -e "  2. 修复/优化系统环境 (${GREEN}保留原有节点，同步防火墙规则${RESET})"
    echo -e "  3. 服务管理 (${CYAN}更新/卸载/修改端口/自定义SNI/修改节点名称${RESET})"
    echo "  4. 查看节点链接配置"
    echo "  5. 查看系统实时日志"
    echo "  0. 退出脚本"
    echo -e "${MAGENTA}=========================================================${RESET}"
    read -p "  请输入对应的数字选项: " choice
}

require_root

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
            echo -e "\n${CYAN}--- 当前节点配置链接 ---${RESET}"
            if [[ -f "${SHOES_LINK_FILE}" ]]; then
                cat "${SHOES_LINK_FILE}"
            else
                echo -e "${YELLOW}配置文件不存在，请先执行安装步骤。${RESET}"
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

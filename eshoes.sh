#!/bin/bash

# ================== 颜色代码 ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

# ================== 常量定义 ==================
SHOES_BIN="/usr/local/bin/shoes"
SHOES_CONF_DIR="/etc/shoes"
SHOES_CONF_FILE="${SHOES_CONF_DIR}/config.yaml"
SHOES_LINK_FILE="${SHOES_CONF_DIR}/config.txt"
SYSTEMD_FILE="/etc/systemd/system/shoes.service"
TMP_DIR="/tmp/shoesdl"

# ================== Root 检查 ==================
require_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}必须使用 root 权限！${RESET}"; exit 1; }
}

# ================== 辅助函数 ==================
check_installed() { [[ -f "$SHOES_BIN" ]] && [[ -f "$SYSTEMD_FILE" ]]; }
check_running() { systemctl is-active --quiet shoes; }

# === 关键修复：智能 IP 获取 (带格式校验) ===
get_public_ipv4() {
    local ip=""
    # 源1: AWS 官方 (最稳)
    ip=$(curl -s -4 --max-time 5 http://checkip.amazonaws.com)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return; fi
    
    # 源2: ifconfig.me
    ip=$(curl -s -4 --max-time 5 http://ifconfig.me/ip)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return; fi
    
    # 源3: api.ipify.org
    ip=$(curl -s -4 --max-time 5 http://api.ipify.org)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return; fi

    # 如果都失败，返回空
    echo ""
}

get_public_ipv6() {
    local ip=""
    # 源1: ifconfig.co (JSON模式更稳)
    ip=$(curl -s -6 --max-time 5 http://ifconfig.co/ip)
    # 简单的 IPv6 正则校验 (包含冒号且不含HTML标签)
    if [[ "$ip" == *":"* ]] && [[ "$ip" != *"<"* ]]; then echo "$ip"; return; fi
    
    # 源2: icanhazip
    ip=$(curl -s -6 --max-time 5 http://icanhazip.com)
    if [[ "$ip" == *":"* ]] && [[ "$ip" != *"<"* ]]; then echo "$ip"; return; fi
    
    echo ""
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
    LATEST_VER=$(curl -s https://api.github.com/repos/cfal/shoes/releases/latest \
        | grep '"tag_name":' \
        | sed -E 's/.*"v?([^"]+)".*/\1/')
    [[ -z "$LATEST_VER" ]] && {
        echo -e "${RED}无法获取 Shoes 最新版本，请检查网络！${RESET}"
        exit 1
    }
}

download_shoes_smart() {
    local force_update="$1"

    echo -e "${GREEN}正在准备 Shoes 核心文件...${RESET}"
    
    if [[ "$force_update" != "force" ]] && [[ -f "${SHOES_BIN}" ]]; then
        chmod +x "${SHOES_BIN}"
        if ${SHOES_BIN} generate-reality-keypair >/dev/null 2>&1; then
            echo -e "${GREEN}检测到当前核心可用，跳过下载。${RESET}"
            return
        fi
    fi

    rm -f "${SHOES_BIN}"
    get_latest_version
    check_arch
    mkdir -p "${TMP_DIR}"
    cd "${TMP_DIR}" || exit 1

    echo -e "${YELLOW}尝试下载 GNU 版本 (v${LATEST_VER})...${RESET}"
    wget -O shoes.tar.gz "https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${GNU_FILE}"
    tar -xzf shoes.tar.gz
    mv shoes "${SHOES_BIN}"
    chmod +x "${SHOES_BIN}"

    if ${SHOES_BIN} generate-reality-keypair >/dev/null 2>&1; then
        echo -e "${GREEN}GNU 版本运行正常！${RESET}"
        return
    fi

    echo -e "${RED}GNU 版本无法运行，自动切换 MUSL 版本...${RESET}"
    rm -f "${SHOES_BIN}"
    wget -O shoes.tar.gz "https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${MUSL_FILE}"
    tar -xzf shoes.tar.gz
    mv shoes "${SHOES_BIN}"
    chmod +x "${SHOES_BIN}"

    if ${SHOES_BIN} generate-reality-keypair >/dev/null 2>&1; then
        echo -e "${GREEN}MUSL 版本运行正常！${RESET}"
        return
    else
        echo -e "${RED}严重错误：所有版本均无法运行！请检查系统环境。${RESET}"
        exit 1
    fi
}

# ================== 核心安装逻辑 ==================
install_shoes() {
    echo -e "${GREEN}=== 开始安装 Shoes (v14 IP校验版) ===${RESET}"
    
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
    
    download_shoes_smart "normal"
    mkdir -p "${SHOES_CONF_DIR}"

    HOST_NAME=$(hostname)
    [[ -z "$HOST_NAME" ]] && HOST_NAME="ShoeServer"
    SNI="icloud.com"

    VLESS_PORT=$(shuf -i 20000-60000 -n 1)
    ANYTLS_PORT=$(shuf -i 20000-60000 -n 1)
    SS_PORT=$(shuf -i 20000-60000 -n 1)
    while [[ "$ANYTLS_PORT" == "$VLESS_PORT" ]]; do ANYTLS_PORT=$(shuf -i 20000-60000 -n 1); done
    while [[ "$SS_PORT" == "$VLESS_PORT" || "$SS_PORT" == "$ANYTLS_PORT" ]]; do SS_PORT=$(shuf -i 20000-60000 -n 1); done

    echo -e "${YELLOW}生成密钥...${RESET}"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$(${SHOES_BIN} generate-reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "private key" | awk '{print $4}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "public key" | awk '{print $4}')
    SHID=$(openssl rand -hex 8)

    SS_METHOD="2022-blake3-aes-256-gcm"
    SS_PASSWORD=$(openssl rand -base64 32)

    echo -e "${YELLOW}生成证书...${RESET}"
    openssl ecparam -genkey -name prime256v1 -out "${SHOES_CONF_DIR}/key.pem"
    openssl req -new -x509 -days 3650 -key "${SHOES_CONF_DIR}/key.pem" -out "${SHOES_CONF_DIR}/cert.pem" -subj "/CN=${SNI}" >/dev/null 2>&1

    cat > "${SHOES_CONF_FILE}" <<EOF
- address: "[::]:${VLESS_PORT}"
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
- address: "[::]:${ANYTLS_PORT}"
  protocol:
    type: tls
    tls_targets:
      "${SNI}":
        cert: "${SHOES_CONF_DIR}/cert.pem"
        key: "${SHOES_CONF_DIR}/key.pem"
        protocol:
          type: anytls
          users:
            - name: anylts
              password: "${PUBLIC_KEY}"
          udp_enabled: true
- address: "[::]:${SS_PORT}"
  protocol:
    type: shadowsocks
    cipher: "${SS_METHOD}"
    password: "${SS_PASSWORD}"
    udp_enabled: true
EOF

    cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=Shoes Proxy Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${SHOES_CONF_DIR}
ExecStart=${SHOES_BIN} ${SHOES_CONF_FILE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shoes
    systemctl restart shoes
    sleep 3

    if check_running; then
        echo -e "${YELLOW}正在获取公网 IP (已启用校验机制)...${RESET}"
        
        # === 智能获取 IP ===
        HOST_IP=$(get_public_ipv4)
        HOST_IPV6=$(get_public_ipv6)

        if [[ -z "$HOST_IP" ]]; then
            echo -e "${RED}警告：无法自动获取 IPv4 地址，链接中可能为空。${RESET}"
            HOST_IP="YOUR_IPV4_HERE"
        else
            echo -e "${GREEN}成功获取 IPv4: ${HOST_IP}${RESET}"
        fi

        SS_BASE=$(echo -n "${SS_METHOD}:${SS_PASSWORD}" | base64 -w 0)

        cat > "${SHOES_LINK_FILE}" <<EOF
# Reality (IPv4)
vless://${UUID}@${HOST_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=random&pbk=${PUBLIC_KEY}&sid=${SHID}&type=tcp#${HOST_NAME}
# AnyTLS (IPv4)
anytls://${PUBLIC_KEY}@${HOST_IP}:${ANYTLS_PORT}?security=tls&sni=${SNI}&allowInsecure=1&type=tcp#${HOST_NAME}_Anytls
# Shadowsocks-2022 (IPv4)
ss://${SS_BASE}@${HOST_IP}:${SS_PORT}#${HOST_NAME}_SS
EOF
        if [[ -n "$HOST_IPV6" ]]; then
            echo -e "\n# Reality (IPv6)\nvless://${UUID}@[${HOST_IPV6}]:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=random&pbk=${PUBLIC_KEY}&sid=${SHID}&type=tcp#${HOST_NAME}_v6" >> "${SHOES_LINK_FILE}"
            echo -e "${GREEN}成功获取 IPv6: ${HOST_IPV6}${RESET}"
        fi
        
        echo -e "${GREEN}安装成功！${RESET}"
        echo -e "${GREEN}------------------------------------------------${RESET}"
        cat "${SHOES_LINK_FILE}"
        echo -e "${GREEN}------------------------------------------------${RESET}"
    else
        echo -e "${RED}启动失败！${RESET}"
        ${SHOES_BIN} ${SHOES_CONF_FILE}
    fi
}

# ================== 服务管理子菜单 ==================
update_core() {
    echo -e "${YELLOW}正在更新 Shoes 核心...${RESET}"
    systemctl stop shoes
    download_shoes_smart "force"
    systemctl restart shoes
    echo -e "${GREEN}核心更新完成并已重启服务！${RESET}"
}

uninstall_shoes() {
    echo -e "${YELLOW}正在卸载...${RESET}"
    systemctl stop shoes
    systemctl disable shoes
    rm -f "${SYSTEMD_FILE}"
    rm -rf "${SHOES_CONF_DIR}"
    rm -f "${SHOES_BIN}"
    systemctl daemon-reload
    echo -e "${GREEN}Shoes 已完全卸载。${RESET}"
}

service_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 服务管理 ===${RESET}"
        echo -e "运行状态: $(check_running && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}")"
        echo ""
        echo "1. 更新 Shoes 核心 (保留配置)"
        echo "2. 卸载服务"
        echo "3. 启动服务"
        echo "4. 停止服务"
        echo "5. 重启服务"
        echo "0. 返回主菜单"
        echo -e "${GREEN}===============${RESET}"
        read -p "请输入选项: " sub_choice

        case "$sub_choice" in
            1) update_core; read -p "按回车继续..." ;;
            2) uninstall_shoes; read -p "按回车继续..." ;;
            3) systemctl start shoes; echo -e "${GREEN}已启动${RESET}"; read -p "按回车继续..." ;;
            4) systemctl stop shoes; echo -e "${RED}已停止${RESET}"; read -p "按回车继续..." ;;
            5) systemctl restart shoes; echo -e "${GREEN}已重启${RESET}"; read -p "按回车继续..." ;;
            0) return ;;
            *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

# ================== 主菜单 ==================
show_main_menu() {
    clear
    echo -e "${GREEN}=== Shoes 管理脚本 (v14 IP校验版) ===${RESET}"
    echo -e "状态: $(check_running && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}") | $(check_installed && echo -e "${GREEN}已安装${RESET}" || echo -e "${YELLOW}未安装${RESET}")"
    echo ""
    echo "1. 安装/重置服务 (全新安装)"
    echo "2. 服务管理 (更新/卸载/启停)"
    echo "3. 查看节点链接"
    echo "4. 查看实时日志"
    echo "0. 退出"
    echo -e "${GREEN}=====================================${RESET}"
    read -p "请输入选项: " choice
}

require_root
while true; do
    show_main_menu
    case "$choice" in
        1) install_shoes; read -p "按回车继续..." ;;
        2) service_menu ;;
        3) [[ -f "${SHOES_LINK_FILE}" ]] && cat "${SHOES_LINK_FILE}" || echo "配置文件不存在"; read -p "按回车继续..." ;;
        4) journalctl -u shoes -f ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done

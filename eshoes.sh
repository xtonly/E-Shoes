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
SYSTEMD_FILE="/etc/systemd/system/shoes.service"
TMP_DIR="/tmp/shoesdl"

# ================== Root 检查 ==================
require_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}错误：请使用 root 用户运行此脚本${RESET}"; exit 1; }
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

    echo -e "${YELLOW}--> 正在准备 Shoes 核心文件...${RESET}"
    
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

    echo -e "${YELLOW}--> 尝试下载 GNU 版本 (v${LATEST_VER})...${RESET}"
    wget -qO shoes.tar.gz "https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${GNU_FILE}"
    tar -xzf shoes.tar.gz
    mv shoes "${SHOES_BIN}"
    chmod +x "${SHOES_BIN}"

    if ${SHOES_BIN} generate-reality-keypair >/dev/null 2>&1; then
        echo -e "${GREEN}GNU 版本运行正常！${RESET}"
        return
    fi

    echo -e "${RED}GNU 版本无法运行，自动切换 MUSL 版本...${RESET}"
    rm -f "${SHOES_BIN}"
    wget -qO shoes.tar.gz "https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${MUSL_FILE}"
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
    clear
    echo -e "${CYAN}============= 开始部署 Shoes 代理节点 =============${RESET}"
    
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

    echo -e "${YELLOW}--> 正在生成安全密钥...${RESET}"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$(${SHOES_BIN} generate-reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "private key" | awk '{print $4}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "public key" | awk '{print $4}')
    SHID=$(openssl rand -hex 8)

    SS_METHOD="2022-blake3-aes-128-gcm"
    SS_PASSWORD=$(openssl rand -base64 16)

    echo -e "${YELLOW}--> 正在生成自签 TLS 证书...${RESET}"
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

    echo -e "${YELLOW}--> 正在注册并启动系统服务...${RESET}"
    systemctl daemon-reload
    systemctl enable shoes >/dev/null 2>&1
    systemctl restart shoes
    sleep 3

    if check_running; then
        echo -e "${YELLOW}--> 正在获取公网 IP (已启用校验机制)...${RESET}"
        
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
anytls://${PUBLIC_KEY}@${HOST_IP}:${ANYTLS_PORT}?security=tls&sni=${SNI}&allowInsecure=1&type=tcp#${HOST_NAME}-Anytls
# Shadowsocks-2022 (IPv4)
ss://${SS_BASE}@${HOST_IP}:${SS_PORT}#${HOST_NAME}-SS
EOF
        if [[ -n "$HOST_IPV6" ]]; then
            echo -e "\n# Reality (IPv6)\nvless://${UUID}@[${HOST_IPV6}]:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=random&pbk=${PUBLIC_KEY}&sid=${SHID}&type=tcp#${HOST_NAME}-v6" >> "${SHOES_LINK_FILE}"
            echo -e "${GREEN}成功获取 IPv6: ${HOST_IPV6}${RESET}"
        fi
        
        echo -e "\n${GREEN}Shoes 节点服务安装成功！${RESET}"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        cat "${SHOES_LINK_FILE}"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
    else
        echo -e "${RED}服务启动失败！以下为调试信息：${RESET}"
        ${SHOES_BIN} ${SHOES_CONF_FILE}
    fi
}

# ================== 证书管理 ==================
update_certificate() {
    echo -e "\n${YELLOW}--> 正在重新生成 TLS 证书...${RESET}"
    if [[ ! -d "${SHOES_CONF_DIR}" ]]; then
        echo -e "${RED}错误：配置目录不存在，请先安装 Shoes！${RESET}"
        return
    fi
    
    local SNI="icloud.com"
    
    # 备份旧证书
    [[ -f "${SHOES_CONF_DIR}/key.pem" ]] && mv "${SHOES_CONF_DIR}/key.pem" "${SHOES_CONF_DIR}/key.pem.bak"
    [[ -f "${SHOES_CONF_DIR}/cert.pem" ]] && mv "${SHOES_CONF_DIR}/cert.pem" "${SHOES_CONF_DIR}/cert.pem.bak"

    # 生成新证书
    openssl ecparam -genkey -name prime256v1 -out "${SHOES_CONF_DIR}/key.pem"
    openssl req -new -x509 -days 3650 -key "${SHOES_CONF_DIR}/key.pem" -out "${SHOES_CONF_DIR}/cert.pem" -subj "/CN=${SNI}" >/dev/null 2>&1

    echo -e "${YELLOW}--> 正在重启服务以应用新证书...${RESET}"
    systemctl restart shoes
    
    if check_running; then
        echo -e "${GREEN}服务已重启，新自签证书已生效。${RESET}"
    else
        echo -e "${RED}服务重启失败，请检查系统日志！${RESET}"
    fi
}

# ================== 服务管理子菜单 ==================
update_core() {
    echo -e "\n${YELLOW}--> 正在更新 Shoes 核心文件...${RESET}"
    systemctl stop shoes
    download_shoes_smart "force"
    systemctl restart shoes
    echo -e "${GREEN}核心更新完成并已重启服务！${RESET}"
}

uninstall_shoes() {
    echo -e "\n${YELLOW}--> 正在停止并卸载 Shoes 服务...${RESET}"
    systemctl stop shoes >/dev/null 2>&1
    systemctl disable shoes >/dev/null 2>&1
    rm -f "${SYSTEMD_FILE}"
    rm -rf "${SHOES_CONF_DIR}"
    rm -f "${SHOES_BIN}"
    systemctl daemon-reload
    echo -e "${GREEN}Shoes 及其相关配置已完全卸载。${RESET}"
}

service_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e "${CYAN}                 Shoes 节点服务管理子菜单                ${RESET}"
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e " ${BLUE}运行状态:${RESET} $(check_running && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}")"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        echo "  1. 更新 Shoes 核心 (保留配置)"
        echo "  2. 卸载服务"
        echo "  3. 启动服务"
        echo "  4. 停止服务"
        echo "  5. 重启服务"
        echo "  6. 更新 TLS 证书 (自签证书)"
        echo "  0. 返回主菜单"
        echo -e "${MAGENTA}=========================================================${RESET}"
        read -p "  请输入对应的数字选项: " sub_choice

        case "$sub_choice" in
            1) update_core; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2) uninstall_shoes; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3) systemctl start shoes; echo -e "\n${GREEN}服务已启动${RESET}"; sleep 1 ;;
            4) systemctl stop shoes; echo -e "\n${RED}服务已停止${RESET}"; sleep 1 ;;
            5) systemctl restart shoes; echo -e "\n${GREEN}服务已重启${RESET}"; sleep 1 ;;
            6) update_certificate; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
            *) echo -e "${RED}无效选项，请重新输入！${RESET}"; sleep 1 ;;
        esac
    done
}

# ================== 主菜单 ==================
show_main_menu() {
    clear
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e "${CYAN}            E-Shoes 代理节点一键管理脚本 1.8                  ${RESET}"
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e " ${BLUE}服务状态:${RESET} $(check_installed && echo -e "${GREEN}已安装${RESET}" || echo -e "${YELLOW}未安装${RESET}")"
    echo -e " ${BLUE}运行状态:${RESET} $(check_running && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}")"
    echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
    echo "  1. 安装/重置服务 (全新安装)"
    echo "  2. 服务管理 (更新/卸载/启停)"
    echo "  3. 查看节点链接配置"
    echo "  4. 查看系统实时日志"
    echo "  0. 退出脚本"
    echo -e "${MAGENTA}=========================================================${RESET}"
    read -p "  请输入对应的数字选项: " choice
}

require_root

# 主循环补全
while true; do
    show_main_menu
    case "$choice" in
        1) 
            install_shoes
            echo "" && read -n 1 -s -r -p "按任意键继续..." 
            ;;
        2) 
            service_menu 
            ;;
        3) 
            echo -e "\n${CYAN}--- 当前节点配置链接 ---${RESET}"
            if [[ -f "${SHOES_LINK_FILE}" ]]; then
                cat "${SHOES_LINK_FILE}"
            else
                echo -e "${YELLOW}配置文件不存在，请先执行安装步骤。${RESET}"
            fi
            echo "" && read -n 1 -s -r -p "按任意键继续..." 
            ;;
        4) 
            echo -e "\n${YELLOW}--> 按 Ctrl+C 退出日志查看${RESET}"
            journalctl -u shoes -f 
            ;;
        0) 
            echo -e "已退出脚本。"
            exit 0 
            ;;
        *) 
            echo -e "${RED}无效选项，请重新输入！${RESET}"
            sleep 1 
            ;;
    esac
done

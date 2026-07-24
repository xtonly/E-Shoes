#!/bin/bash

# ================== 颜色代码 ==================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：修改内核参数需要 root 权限，请使用 root 用户运行此脚本。${RESET}"
   exit 1
fi

# ================== IP 详情检测 ==================
check_ipv6_info() {
    echo -e "${CYAN}---------------------------------------------------------${RESET}"
    echo -e "正在检测公网 IPv6 详情..."
    
    local ipv6
    ipv6=$(curl -s -6 --max-time 4 icanhazip.com)
    
    if [[ -z "$ipv6" ]]; then
        echo -e "${YELLOW}未检测到公网 IPv6 地址，或者 IPv6 路由尚未通畅。${RESET}"
        echo -e "提示：若系统已启用 IPv6，可能需手动执行 DHCPv6 或修改网卡配置以获取公网 IP。"
        return
    fi

    echo -e "公网 IPv6 地址 : ${GREEN}${ipv6}${RESET}"
    
    # 强制走 IPv4 接口请求 API，防止 VPS 的 IPv6 刚开启还未彻底连通时导致查询卡死
    local api_url="http://ip-api.com/json/${ipv6}?fields=country,regionName,city,isp,org,as,hosting"
    local ip_info
    ip_info=$(curl -s -4 --max-time 5 "$api_url")
    
    if [[ -n "$ip_info" ]]; then
        # 解析 JSON 字段
        local country=$(echo "$ip_info" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        local city=$(echo "$ip_info" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
        local isp=$(echo "$ip_info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
        local as_info=$(echo "$ip_info" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)
        local hosting=$(echo "$ip_info" | grep -o '"hosting":true\|"hosting":false' | cut -d':' -f2)
        
        echo -e "注册/使用地区  : ${CYAN}${country} - ${city}${RESET}"
        echo -e "运营商 (ISP)   : ${CYAN}${isp}${RESET}"
        echo -e "ASN 归属       : ${CYAN}${as_info}${RESET}"
        
        if [[ "$hosting" == "false" ]]; then
            echo -e "IP 纯净度评估  : ${GREEN}原生 IP (住宅宽带/商业ISP直连)${RESET}"
        else
            echo -e "IP 纯净度评估  : ${YELLOW}非原生 (数据中心/机房/广播 IP)${RESET}"
        fi
    else
        echo -e "${RED}无法获取详细归属地信息。${RESET}"
    fi
}

# ================== 状态检测 ==================
check_status() {
    local status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    local has_inet6=$(ip a | grep -w inet6)

    if [[ "$status" == "1" ]]; then
        echo -e "内核 sysctl 状态: ${RED}已禁用 IPv6${RESET}"
    elif [[ "$status" == "0" ]]; then
        echo -e "内核 sysctl 状态: ${GREEN}已启用 IPv6${RESET}"
    else
        echo -e "内核 sysctl 状态: ${YELLOW}未知状态${RESET}"
    fi

    if [[ -z "$has_inet6" ]]; then
        echo -e "网卡接口层状态  : ${RED}未挂载 IPv6 协议栈${RESET}"
    else
        echo -e "网卡接口层状态  : ${GREEN}已分配 IPv6 (至少具备本地链路地址)${RESET}"
    fi
    
    check_ipv6_info
}

# ================== 核心功能 ==================
enable_ipv6() {
    echo -e "\n${YELLOW}--> 正在清理旧的 IPv6 禁用规则...${RESET}"
    sed -i '/net.ipv6.conf.*.disable_ipv6/d' /etc/sysctl.conf

    echo -e "${YELLOW}--> 正在应用启用规则...${RESET}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}系统级 IPv6 已成功启用！${RESET}\n"
}

disable_ipv6() {
    echo -e "\n${YELLOW}--> 正在清理旧的 IPv6 规则以防冲突...${RESET}"
    sed -i '/net.ipv6.conf.*.disable_ipv6/d' /etc/sysctl.conf

    echo -e "${YELLOW}--> 正在写入永久禁用规则...${RESET}"
    cat >> /etc/sysctl.conf <<EOF
# Script: Disable IPv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

    echo -e "${YELLOW}--> 正在应用禁用规则...${RESET}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}系统级 IPv6 已成功禁用！所有网卡已关闭 IPv6 协议栈。${RESET}\n"
}

# ================== 交互菜单 ==================
while true; do
    clear
    echo -e "${CYAN}=========================================================${RESET}"
    echo -e "${CYAN}                 系统级 IPv6 管理工具                    ${RESET}"
    echo -e "${CYAN}=========================================================${RESET}"
    check_status
    echo -e "${CYAN}=========================================================${RESET}"
    echo "  1. 启用 IPv6 (Enable)"
    echo "  2. 禁用 IPv6 (Disable)"
    echo "  0. 退出脚本"
    echo -e "${CYAN}=========================================================${RESET}"
    read -p "请输入对应的数字选项: " choice

    case "$choice" in
        1) enable_ipv6; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
        2) disable_ipv6; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
        0) echo -e "已退出脚本。"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}"; sleep 1 ;;
    esac
done

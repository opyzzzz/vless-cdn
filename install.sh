#!/bin/bash

# 基础颜色与变量定义
red='\e[31m'
green='\e[92m'
yellow='\e[33m'
none='\e[0m'
is_core_dir="/etc/xray"
is_conf_dir="/etc/xray/conf"
is_log_dir="/var/log/xray"
is_sh_bin="/usr/local/bin/xray"
is_config_json="/etc/xray/config.json"
is_cert_file="/etc/xray/cert.crt"
is_key_file="/etc/xray/cert.key"

# 检查 Root 权限
[[ $EUID != 0 ]] && echo -e "${red}错误: 必须使用 ROOT 用户运行!${none}" && exit 1

# --- 核心功能模块 ---

# 启用 BBR 加速
enable_bbr() {
    echo -e "${yellow}正在启用 BBR 加速...${none}"
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
}

# 证书粘贴处理
input_cert_content() {
    echo -e "${yellow}请粘贴证书内容 (CRT)，完成后输入 EOF 回车:${none}"
    sed '/EOF/q' > $is_cert_file
    echo -e "${yellow}请粘贴私钥内容 (KEY)，完成后输入 EOF 回车:${none}"
    sed '/EOF/q' > $is_key_file
    sed -i '/EOF/d' $is_cert_file
    sed -i '/EOF/d' $is_key_file
    chmod 600 $is_key_file
}

# 生成 VLESS 链接
get_link() {
    if [[ ! -f $is_config_json ]]; then
        echo -e "${red}未检测到配置文件，请先安装代理。${none}"
        return
    fi
    local uuid=$(grep '"id"' $is_config_json | awk -F '"' '{print $4}')
    local port=$(grep '"port"' $is_config_json | awk -F ' ' '{print $2}' | tr -d ',')
    local path=$(grep '"path"' $is_config_json | awk -F '"' '{print $4}')
    local host=$(grep -m 1 '"domain"' /etc/xray/domain.txt 2>/dev/null | awk '{print $1}') # 从存证获取
    
    # 构建 VLESS 链接
    local link="vless://${uuid}@${domain}:${port}?encryption=none&security=tls&type=ws&host=${domain}&path=${path}#Xray_CDN_$(hostname)"
    
    echo -e "\n${green}--- 配置信息 ---${none}"
    echo -e "${blue}域名:${none} ${domain}"
    echo -e "${blue}端口:${none} ${port}"
    echo -e "${blue}UUID:${none} ${uuid}"
    echo -e "${blue}路径:${none} ${path}"
    echo -e "${green}--- 节点链接 ---${none}"
    echo -e "${yellow}${link}${none}\n"
}

# 安装代理
install_proxy() {
    clear
    echo -e "${green}开始安装 Xray (CDN + 根源证书 + DoH)${none}"
    
    read -p "请输入域名: " domain
    echo $domain > /etc/xray/domain.txt # 持久化域名供链接生成使用
    read -p "请输入端口 (默认 443): " port
    port=${port:-443}
    
    mkdir -p $is_core_dir $is_log_dir
    input_cert_content

    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local ws_path="/xray-ws"

    cat > $is_config_json <<EOF
{
    "dns": { "servers": ["https://1.1.1.1/dns-query", "localhost"] },
    "inbounds": [{
        "port": $port, "protocol": "vless",
        "settings": { "clients": [{"id": "$uuid"}], "decryption": "none" },
        "streamSettings": {
            "network": "ws", "security": "tls",
            "tlsSettings": { "certificates": [{ "certificateFile": "$is_cert_file", "keyFile": "$is_key_file" }] },
            "wsSettings": { "path": "$ws_path" }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    enable_bbr
    echo -e "${green}安装成功！${none}"
    get_link
}

# --- 交互界面菜单 ---

main_menu() {
    domain=$(cat /etc/xray/domain.txt 2>/dev/null)
    clear
    echo -e "${green}Xray 管理脚本 v1.32${none}"
    echo "--------------------------------"
    echo -e "1) 安装代理 (CDN+证书内容输入)"
    echo -e "2) 查看代理连接 (URL/链接)"
    echo -e "3) 更换域名"
    echo -e "4) 更换证书内容"
    echo -e "5) 更换端口"
    echo -e "6) 查看日志 / 清理日志"
    echo -e "7) 完全卸载"
    echo -e "q) 退出"
    echo "--------------------------------"
    read -p "请选择: " choice

    case $choice in
        1) install_proxy ;;
        2) get_link ;;
        3) read -p "新域名: " domain && echo $domain > /etc/xray/domain.txt && echo "已更新" ;;
        4) input_cert_content && echo "证书已更新" ;;
        5) read -p "新端口: " port ;;
        6) 
           echo "1. 查看日志  2. 清理日志"
           read -p "选择: " log_c
           [[ $log_c == 1 ]] && tail -n 50 $is_log_dir/access.log
           [[ $log_c == 2 ]] && echo "" > $is_log_dir/access.log && echo "已清理"
           ;;
        7) 
           systemctl stop xray &>/dev/null
           rm -rf $is_core_dir $is_log_dir $is_sh_bin
           echo "已卸载" ;;
        q) exit 0 ;;
        *) main_menu ;;
    esac
}

# 设置快捷命令
if [[ ! -f $is_sh_bin ]]; then
    ln -sf "$(realpath $0)" $is_sh_bin
    chmod +x $is_sh_bin
fi

main_menu

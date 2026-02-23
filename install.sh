#!/bin/bash

# ====================================================
# 设计理念：高效率，高伪装，彻底清理
# 包含功能：CF CDN + 根源证书 + DoH + BBR + 代理链接生成
# ====================================================

# 颜色定义
red='\e[31m'
green='\e[92m'
yellow='\e[33m'
none='\e[0m'

# 路径定义 (参考原脚本逻辑)
is_core_dir="/etc/xray"
is_log_dir="/var/log/xray"
is_sh_bin="/usr/local/bin/xray"
is_config_json="/etc/xray/config.json"
is_cert_file="/etc/xray/cert.crt"
is_key_file="/etc/xray/cert.key"
is_domain_file="/etc/xray/domain.txt"

# 检查 Root
[[ $EUID != 0 ]] && echo -e "${red}错误: 必须使用 ROOT 用户运行!${none}" && exit 1

# --- 核心功能 ---

# 1. BBR 开启
enable_bbr() {
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
}

# 2. 生成代理连接
get_link() {
    if [[ ! -f $is_config_json ]]; then
        echo -e "${red}未检测到安装。${none}"
        return
    fi
    local uuid=$(grep '"id"' $is_config_json | awk -F '"' '{print $4}')
    local port=$(grep '"port"' $is_config_json | awk -F ' ' '{print $2}' | tr -d ',')
    local domain=$(cat $is_domain_file 2>/dev/null)
    local link="vless://${uuid}@${domain}:${port}?encryption=none&security=tls&type=ws&host=${domain}&path=/xray-ws#Xray_CDN"
    echo -e "\n${green}--- VLESS 节点链接 ---${none}"
    echo -e "${yellow}${link}${none}\n"
}

# 3. 安装与配置 (CF CDN + DoH)
install_proxy() {
    clear
    read -p "请输入域名 (Domain): " domain
    [[ -z "$domain" ]] && echo "域名不能为空" && return
    echo $domain > $is_domain_file
    
    read -p "请输入端口 (默认 443): " port
    port=${port:-443}

    # 输入证书内容
    echo -e "${yellow}请粘贴证书内容 (CRT)，完成后换行输入 EOF 并回车:${none}"
    sed '/EOF/q' > $is_cert_file
    echo -e "${yellow}请粘贴私钥内容 (KEY)，完成后换行输入 EOF 并回车:${none}"
    sed '/EOF/q' > $is_key_file
    sed -i '/EOF/d' $is_cert_file
    sed -i '/EOF/d' $is_key_file

    mkdir -p $is_log_dir
    local uuid=$(cat /proc/sys/kernel/random/uuid)

    # 创建 Xray 配置文件 (使用 DoH: 1.1.1.1)
    cat > $is_config_json <<EOF
{
    "dns": { "servers": ["https://1.1.1.1/dns-query", "localhost"] },
    "inbounds": [{
        "port": $port, "protocol": "vless",
        "settings": { "clients": [{"id": "$uuid"}], "decryption": "none" },
        "streamSettings": {
            "network": "ws", "security": "tls",
            "tlsSettings": { "certificates": [{ "certificateFile": "$is_cert_file", "keyFile": "$is_key_file" }] },
            "wsSettings": { "path": "/xray-ws" }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    
    # 创建 Systemd 服务
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
User=root
ExecStart=$is_sh_bin bin run -c $is_config_json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    
    enable_bbr
    echo -e "${green}安装成功！${none}"
    get_link
}

# 4. 彻底清理逻辑 (包含历史修改)
uninstall_and_cleanup() {
    echo -e "${yellow}正在执行深度清理...${none}"
    
    # 停止进程并删除服务
    systemctl stop xray &>/dev/null
    systemctl disable xray &>/dev/null
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload

    # 删除所有相关文件目录
    rm -rf "$is_core_dir"
    rm -rf "$is_log_dir"
    rm -f "$is_sh_bin"
    
    # 清理 .bashrc 中的 alias (上一次会话可能留下的)
    sed -i '/alias xray=/d' /root/.bashrc
    
    # 清理 BBR 修改 (可选)
    sed -i '/net.core.default_qdisc=fq/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control=bbr/d' /etc/sysctl.conf
    sysctl -p &>/dev/null

    echo -e "${green}清理完成：所有服务、配置、证书、日志、快捷命令及系统修改已移除。${none}"
}

# --- 交互界面菜单 ---

main_menu() {
    clear
    echo -e "${green}Xray 交互管理界面${none}"
    echo "--------------------------------"
    echo -e "1) 安装代理 (CF CDN + DoH + 粘贴证书)"
    echo -e "2) 查看/生成代理链接"
    echo -e "3) 更换域名"
    echo -p "4) 更换证书 (重新粘贴)"
    echo -p "5) 更换端口"
    echo -p "6) 更换 DNS (DoH)"
    echo -e "7) 查看运行日志"
    echo -e "8) 清理运行日志"
    echo -e "9) 完全卸载并一键清理所有修改"
    echo -e "q) 退出"
    echo "--------------------------------"
    read -p "选择操作 [1-9]: " choice

    case $choice in
        1) install_proxy ;;
        2) get_link ;;
        3|5|6) echo -e "${yellow}请重新执行安装 (选项1) 以覆盖新配置。${none}" ;;
        4) input_cert_content && echo "证书内容已更新。" ;;
        7) [ -f $is_log_dir/access.log ] && tail -n 50 $is_log_dir/access.log || echo "暂无日志。" ;;
        8) echo "" > $is_log_dir/access.log 2>/dev/null && echo "日志已清空。" ;;
        9) uninstall_and_cleanup ;;
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

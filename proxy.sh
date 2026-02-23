#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 核心定义：只允许 xray 名字存在
EXEC_NAME="xray"
BIN_PATH="/usr/local/bin/$EXEC_NAME"
CONF_DIR="/etc/$EXEC_NAME"
CONF_FILE="$CONF_DIR/config.json"
LOG_DIR="/var/log/$EXEC_NAME"
ERROR_LOG="$LOG_DIR/error.log"
CERT_PATH="$CONF_DIR/server.crt"
KEY_PATH="$CONF_DIR/server.key"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 权限运行！${NC}" && exit 1

# 快捷命令设置
install_shortcut() {
    [[ -L "/usr/local/bin/proxy" ]] && rm -f /usr/local/bin/proxy
    ln -sf "$(readlink -f "$0")" /usr/local/bin/proxy
    chmod +x /usr/local/bin/proxy
}

# 自动拼接 VLESS 链接
get_link() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo -e "${RED}未检测到配置。${NC}"
        return
    fi
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $CONF_FILE)
    DOMAIN=$(cat $CONF_DIR/domain_record.txt 2>/dev/null)
    
    LINK="vless://${UUID}@${DOMAIN}:2083?security=tls&encryption=none&type=grpc&serviceName=grpc-proxy&sni=${DOMAIN}#CF_VLESS_gRPC"
    
    echo -e "${GREEN}=== VLESS 节点链接 ===${NC}"
    echo -e "${RED}${LINK}${NC}"
    echo -e "${YELLOW}重要：请前往 CF 控制台 -> 网络 -> 开启 gRPC 开关！${NC}"
    echo -e "${YELLOW}重要：SSL/TLS 必须设为 Full (Strict)！${NC}"
}

# 安装功能
install_proxy() {
    echo -e "${GREEN}正在清理旧环境并安装依赖...${NC}"
    apt update && apt install -y curl jq openssl wget
    
    # 交互输入
    read -p "请输入域名: " DOMAIN
    echo -e "${YELLOW}请粘贴 CF 根源证书，按 Ctrl+D 保存:${NC}"
    CERT_CONTENT=$(cat)
    echo -e "${YELLOW}请粘贴 CF 私钥，按 Ctrl+D 保存:${NC}"
    KEY_CONTENT=$(cat)
    
    # 创建纯净目录
    mkdir -p $CONF_DIR $LOG_DIR
    echo "$CERT_CONTENT" > $CERT_PATH
    echo "$KEY_CONTENT" > $KEY_PATH
    echo "$DOMAIN" > $CONF_DIR/domain_record.txt
    touch $ERROR_LOG

    # 下载 Xray 核心并重命名（不使用官方脚本以保证纯净度）
    PLATFORM="64"
    [[ $(uname -m) == "aarch64" ]] && PLATFORM="arm64-v8a"
    TAG=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
    wget -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${TAG}/Xray-linux-${PLATFORM}.zip"
    apt install -y unzip && unzip -o /tmp/xray.zip -d /tmp/xray_bin
    cp /tmp/xray_bin/xray $BIN_PATH
    chmod +x $BIN_PATH
    rm -rf /tmp/xray.zip /tmp/xray_bin

    # 生成 UUID
    UUID=$(cat /proc/sys/kernel/random/uuid)
    
    # 写入配置 (仅保留错误日志，loglevel=warning)
    cat <<EOF > $CONF_FILE
{
    "log": { "error": "$ERROR_LOG", "loglevel": "warning" },
    "dns": { "servers": ["https://1.1.1.1/dns-query"] },
    "inbounds": [{
        "port": 2083,
        "protocol": "vless",
        "settings": { "clients": [{"id": "$UUID"}], "decryption": "none" },
        "streamSettings": {
            "network": "grpc",
            "security": "tls",
            "tlsSettings": {
                "certificates": [{ "certificateFile": "$CERT_PATH", "keyFile": "$KEY_PATH" }],
                "alpn": ["h2"]
            },
            "grpcSettings": { "serviceName": "grpc-proxy" }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF

    # 创建自定义 Systemd 服务，服务名只叫 xray
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=xray
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$BIN_PATH run -c $CONF_FILE
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl restart xray
    systemctl enable xray
    
    echo -e "${GREEN}安装完成！进程名与服务名均为: xray${NC}"
    get_link
}

# 菜单
show_menu() {
    install_shortcut
    clear
    echo -e "${GREEN}=== Debian 12 VLESS ($EXEC_NAME) 管理 ===${NC}"
    echo -e "1. 安装代理"
    echo -e "2. 查看连接链接"
    echo -e "3. 更改域名"
    echo -e "4. 更改 CF 证书"
    echo -e "5. 更改 DoH DNS"
    echo -e "6. 查看错误日志"
    echo -e "7. 清空日志"
    echo -e "8. ${RED}彻底卸载${NC}"
    echo -e "0. 退出"
    read -p "请选择: " OPT
    case $OPT in
        1) install_proxy ;;
        2) get_link ;;
        3) read -p "新域名: " D; echo "$D" > $CONF_DIR/domain_record.txt; echo "已更新";;
        4) 
            echo "请粘贴新证书(Ctrl+D):"; C=$(cat); echo "$C" > $CERT_PATH
            echo "请粘贴新私钥(Ctrl+D):"; K=$(cat); echo "$K" > $KEY_PATH
            systemctl restart xray && echo "已重启";;
        5) 
            read -p "新 DoH: " DNS
            jq ".dns.servers[0] = \"$DNS\"" $CONF_FILE > /tmp/x.json && mv /tmp/x.json $CONF_FILE
            systemctl restart xray && echo "已更新";;
        6) tail -f $ERROR_LOG ;;
        7) > $ERROR_LOG && echo "已清空";;
        8) 
            systemctl stop xray && systemctl disable xray
            rm -f /etc/systemd/system/xray.service /usr/local/bin/xray /usr/local/bin/proxy
            rm -rf $CONF_DIR $LOG_DIR
            echo "已彻底清除所有痕迹"; exit 0;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

show_menu

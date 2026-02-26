#!/bin/bash
set -e
set -o pipefail

VERSION="2.5-双协议可切换增强版"

BASE_DIR="/opt/suoha"
BIN_DIR="$BASE_DIR/bin"
CONF_DIR="$BASE_DIR/config"
SYSTEMD_DIR="/etc/systemd/system"
CF_PREFERRED_DOMAIN="cloudflare.182682.xyz"
ARCH=$(uname -m)

检测系统() {
    source /etc/os-release
    OS=$ID

    case "$OS" in
        debian|ubuntu)
            PM_INSTALL="apt install -y"
            PM_UPDATE="apt update -y"
            SERVICE_TYPE="systemd"
        ;;
        centos|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                PM_INSTALL="dnf install -y"
                PM_UPDATE="dnf makecache"
            else
                PM_INSTALL="yum install -y"
                PM_UPDATE="yum makecache"
            fi
            SERVICE_TYPE="systemd"
        ;;
        alpine)
            PM_INSTALL="apk add --no-cache"
            PM_UPDATE="apk update"
            SERVICE_TYPE="openrc"
        ;;
        *)
            echo "不支持的系统: $OS"
            exit 1
        ;;
    esac

    echo "检测到系统: $OS"
}

检测架构() {
    case "$ARCH" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) echo "不支持的CPU架构"; exit 1 ;;
    esac
}

检测IP协议() {
    echo "检测 IPv4..."
    curl -4 -s --max-time 3 https://speed.cloudflare.com/meta >/dev/null && IPV4=1 || IPV4=0

    echo "检测 IPv6..."
    curl -6 -s --max-time 3 https://speed.cloudflare.com/meta >/dev/null && IPV6=1 || IPV6=0

    if [ "$IPV4" = "0" ] && [ "$IPV6" = "0" ]; then
        echo "IPv4 与 IPv6 均不可用"
        exit 1
    fi

    echo "请选择网络协议："
    [ "$IPV4" = "1" ] && echo "1. IPv4"
    [ "$IPV6" = "1" ] && echo "2. IPv6"
    read -p "选择: " IP_CHOICE

    if [ "$IP_CHOICE" = "1" ]; then
        EDGE_IP_VERSION=4
    elif [ "$IP_CHOICE" = "2" ]; then
        EDGE_IP_VERSION=6
    else
        echo "选择错误"
        exit 1
    fi
}

安装依赖() {
    $PM_UPDATE
    $PM_INSTALL curl unzip uuidgen 2>/dev/null || $PM_INSTALL uuid-runtime || true
}

安装Xray() {
    mkdir -p $BIN_DIR
    ARCH_SUFFIX=$(检测架构)
    curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH_SUFFIX.zip
    unzip -o /tmp/xray.zip -d /tmp/xray
    mv /tmp/xray/xray $BIN_DIR/
    chmod +x $BIN_DIR/xray
}

安装Cloudflared() {
    mkdir -p $BIN_DIR
    curl -L -o $BIN_DIR/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x $BIN_DIR/cloudflared
}

生成UUID() { uuidgen; }

生成端口() {
    while :; do
        PORT=$(shuf -i20000-50000 -n1)
        ss -lnt | grep -q ":$PORT " || break
    done
}

生成Xray配置() {
    mkdir -p $CONF_DIR
    生成端口
    UUID=$(生成UUID)

cat > $CONF_DIR/xray.json <<EOF
{
  "inbounds": [{
    "port": $PORT,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "grpc",
      "grpcSettings": { "serviceName": "grpc" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
}

创建systemd() {

MODE=$1

if [ "$MODE" = "http2" ] || [ "$MODE" = "both" ]; then
cat > $SYSTEMD_DIR/suoha-http2.service <<EOF
[Unit]
Description=Suoha Tunnel HTTP2
After=network.target

[Service]
ExecStart=$BIN_DIR/cloudflared tunnel --protocol http2 --edge-ip-version $EDGE_IP_VERSION run --token $TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable suoha-http2
systemctl start suoha-http2
fi

if [ "$MODE" = "quic" ] || [ "$MODE" = "both" ]; then
cat > $SYSTEMD_DIR/suoha-quic.service <<EOF
[Unit]
Description=Suoha Tunnel QUIC
After=network.target

[Service]
ExecStart=$BIN_DIR/cloudflared tunnel --protocol quic --edge-ip-version $EDGE_IP_VERSION run --token $TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable suoha-quic
systemctl start suoha-quic
fi

cat > $SYSTEMD_DIR/suoha-xray.service <<EOF
[Unit]
Description=Suoha Xray
After=network.target

[Service]
ExecStart=$BIN_DIR/xray run -config $CONF_DIR/xray.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable suoha-xray
systemctl start suoha-xray
}

显示信息() {
echo ""
echo "========== 节点信息 =========="
echo "优选域名: $CF_PREFERRED_DOMAIN"
echo "vless://$UUID@$CF_PREFERRED_DOMAIN:443?encryption=none&security=tls&type=grpc&serviceName=grpc#$CF_PREFERRED_DOMAIN"
echo "================================"
}

安装流程() {
read -p "请输入 Tunnel Token: " TOKEN
检测系统
检测IP协议
安装依赖
安装Xray
安装Cloudflared
生成Xray配置

echo "选择隧道模式："
echo "1. 仅 HTTP/2"
echo "2. 仅 QUIC"
echo "3. HTTP/2 + QUIC 同时运行"
read -p "选择: " MODE_CHOICE

case $MODE_CHOICE in
1) 创建systemd http2 ;;
2) 创建systemd quic ;;
3) 创建systemd both ;;
*) echo "选择错误"; exit 1 ;;
esac

显示信息
}

菜单() {
while true; do
echo ""
echo "========= SUOHA $VERSION ========="
echo "1. 安装/切换隧道模式"
echo "0. 退出"
read -p "选择: " NUM

case $NUM in
1) 安装流程 ;;
0) exit ;;
esac
done
}

菜单
#!/bin/bash
set -e
set -o pipefail

VERSION="2.4-自动系统+IPv4/IPv6+Token固定隧道版"

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

echo "正在检测 IPv4 连通性..."
if curl -4 -s --max-time 3 https://speed.cloudflare.com/meta >/dev/null 2>&1; then
    IPV4_AVAILABLE=1
    echo "IPv4 可用"
else
    IPV4_AVAILABLE=0
    echo "IPv4 不可用"
fi

echo "正在检测 IPv6 连通性..."
if curl -6 -s --max-time 3 https://speed.cloudflare.com/meta >/dev/null 2>&1; then
    IPV6_AVAILABLE=1
    echo "IPv6 可用"
else
    IPV6_AVAILABLE=0
    echo "IPv6 不可用"
fi

echo "--------------------------------"

if [ "$IPV4_AVAILABLE" = "0" ] && [ "$IPV6_AVAILABLE" = "0" ]; then
    echo "错误：IPv4 和 IPv6 均不可用，无法继续。"
    exit 1
fi

echo "请选择 Cloudflare Tunnel 使用的网络协议："
[ "$IPV4_AVAILABLE" = "1" ] && echo "1. 使用 IPv4"
[ "$IPV6_AVAILABLE" = "1" ] && echo "2. 使用 IPv6"

read -p "请输入选项编号: " IP_CHOICE

if [ "$IP_CHOICE" = "1" ] && [ "$IPV4_AVAILABLE" = "1" ]; then
    EDGE_IP_VERSION=4
elif [ "$IP_CHOICE" = "2" ] && [ "$IPV6_AVAILABLE" = "1" ]; then
    EDGE_IP_VERSION=6
else
    echo "选择无效或协议不可用"
    exit 1
fi

echo "已选择 IPv$EDGE_IP_VERSION"
}

安装依赖() {
    echo "正在安装基础依赖..."
    $PM_UPDATE
    $PM_INSTALL curl unzip uuidgen 2>/dev/null || $PM_INSTALL uuid-runtime || true
}

安装Xray() {
    echo "正在安装 Xray..."
    mkdir -p $BIN_DIR
    ARCH_SUFFIX=$(检测架构)
    curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH_SUFFIX.zip
    unzip -o /tmp/xray.zip -d /tmp/xray
    mv /tmp/xray/xray $BIN_DIR/
    chmod +x $BIN_DIR/xray
}

安装Cloudflared() {
    echo "正在安装 Cloudflare Tunnel..."
    mkdir -p $BIN_DIR
    curl -L -o $BIN_DIR/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x $BIN_DIR/cloudflared
}

生成端口() {
    while :; do
        PORT=$(shuf -i20000-50000 -n1)
        ss -lnt | grep -q ":$PORT " || break
    done
}

生成UUID() {
    uuidgen
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
      "clients": [{
        "id": "$UUID"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "grpc",
      "grpcSettings": {
        "serviceName": "grpc"
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

echo "--------------------------------"
echo "UUID: $UUID"
echo "本地端口: $PORT"
echo "--------------------------------"
}

创建systemd服务() {

cat > $SYSTEMD_DIR/suoha-xray.service <<EOF
[Unit]
Description=Suoha Xray
After=network.target

[Service]
ExecStart=$BIN_DIR/xray run -config $CONF_DIR/xray.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > $SYSTEMD_DIR/suoha-tunnel.service <<EOF
[Unit]
Description=Suoha Cloudflare Tunnel (Token模式)
After=network.target

[Service]
ExecStart=$BIN_DIR/cloudflared tunnel --protocol quic --edge-ip-version $EDGE_IP_VERSION run --token $TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable suoha-xray
systemctl enable suoha-tunnel
systemctl start suoha-xray
systemctl start suoha-tunnel
}

创建openrc服务() {

cat > /etc/init.d/suoha-xray <<EOF
#!/sbin/openrc-run
command="$BIN_DIR/xray"
command_args="run -config $CONF_DIR/xray.json"
command_background=true
EOF

chmod +x /etc/init.d/suoha-xray
rc-update add suoha-xray default
/etc/init.d/suoha-xray start

cat > /etc/init.d/suoha-tunnel <<EOF
#!/sbin/openrc-run
command="$BIN_DIR/cloudflared"
command_args="tunnel --protocol quic --edge-ip-version $EDGE_IP_VERSION run --token $TOKEN"
command_background=true
EOF

chmod +x /etc/init.d/suoha-tunnel
rc-update add suoha-tunnel default
/etc/init.d/suoha-tunnel start
}

显示节点信息() {
echo ""
echo "========== 节点信息 =========="
echo "协议: gRPC"
echo "优选域名: $CF_PREFERRED_DOMAIN"
echo "vless://$UUID@$CF_PREFERRED_DOMAIN:443?encryption=none&security=tls&type=grpc&serviceName=grpc#$CF_PREFERRED_DOMAIN"
echo "================================"
}

菜单() {
while true; do
echo ""
echo "========= SUOHA $VERSION ========="
echo "1. 安装固定隧道(Token模式)"
echo "2. 重启服务"
echo "0. 退出"
read -p "请选择操作: " 选项

case $选项 in
1)
    read -p "请输入 Cloudflare Tunnel Token: " TOKEN
    检测系统
    检测IP协议
    安装依赖
    安装Xray
    安装Cloudflared
    生成Xray配置

    if [ "$SERVICE_TYPE" = "systemd" ]; then
        创建systemd服务
    else
        创建openrc服务
    fi

    显示节点信息
;;
2)
    if [ "$SERVICE_TYPE" = "systemd" ]; then
        systemctl restart suoha-xray suoha-tunnel
    else
        rc-service suoha-xray restart
        rc-service suoha-tunnel restart
    fi
;;
0) exit ;;
esac
done
}

菜单
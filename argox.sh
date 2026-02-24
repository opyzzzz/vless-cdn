#!/usr/bin/env bash

# =====================================================
# ArgoX Integrated Edition (Final Stability Fix)
# 修复 QUIC 协议导致的 NAT 环境超时问题
# =====================================================

WORK_DIR='/etc/argox'
BIN_PATH='/usr/local/bin/argox'
NGINX_PORT='80'
XRAY_PORT='8080'
METRICS_PORT='3333'
DEFAULT_XRAY_VERSION='26.2.6'
CDN_DOMAIN=("skk.moe" "ip.sb" "time.is" "cf.090227.xyz")

info(){ echo -e "\033[32m\033[01m$*\033[0m"; }
reading(){ read -rp "$(echo -e "\033[32m\033[01m$1\033[0m")" "$2"; }

# 清理并安装依赖
check_env(){
    systemctl stop argo xray nginx 2>/dev/null
    apt update -y && apt install -y wget curl unzip nginx 2>/dev/null || apk add wget curl unzip nginx 2>/dev/null
    mkdir -p "$WORK_DIR"
}

# 组件下载
download_all(){
    case $(uname -m) in
        x86_64|amd64) ARGO_ARCH=amd64; XRAY_ARCH=64 ;;
        aarch64|arm64) ARGO_ARCH=arm64; XRAY_ARCH=arm64-v8a ;;
    esac
    wget -qO "$WORK_DIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH"
    wget -qO "$WORK_DIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/v$DEFAULT_XRAY_VERSION/Xray-linux-$XRAY_ARCH.zip"
    unzip -oj "$WORK_DIR/xray.zip" "xray" -d "$WORK_DIR" && chmod +x "$WORK_DIR/cloudflared" "$WORK_DIR/xray"
}

install_argox(){
    check_env
    reading "请输入 Argo 域名: " ARGO_DOMAIN
    reading "请输入 Argo Token 或 Json: " ARGO_AUTH
    reading "请输入 UUID [默认随机]: " UUID
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")}
    reading "请输入 WS 路径 [默认 argox]: " WS_PATH
    WS_PATH=${WS_PATH:-"argox"}
    reading "请输入优选域名 [默认 ${CDN_DOMAIN[0]}]: " SERVER
    SERVER=${SERVER:-${CDN_DOMAIN[0]}}

    download_all

    # Nginx 伪装站配置
    cat > /etc/nginx/nginx.conf <<EOF
user root;
worker_processes auto;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    server {
        listen $NGINX_PORT;
        location / { proxy_pass https://www.bing.com; proxy_ssl_server_name on; }
        location /$WS_PATH {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:$XRAY_PORT;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
    }
}
EOF

    # Xray 配置
    cat > "$WORK_DIR/config.json" <<EOF
{
    "inbounds": [{
        "port": $XRAY_PORT, "listen": "127.0.0.1", "protocol": "vless",
        "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
        "streamSettings": { "network": "ws", "wsSettings": { "path": "/$WS_PATH" } }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF

    # === 关键点：强制指定 --protocol http2 解决 NAT 环境 QUIC 报错 ===
    if [[ "$ARGO_AUTH" =~ "eyJh" ]]; then
        ARGO_RUN="tunnel --protocol http2 --no-autoupdate run --token $ARGO_AUTH"
    else
        echo "$ARGO_AUTH" > "$WORK_DIR/argo.json"
        ARGO_RUN="tunnel --protocol http2 --no-autoupdate --cred-file $WORK_DIR/argo.json run $ARGO_DOMAIN"
    fi

    # 写入服务
    cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel
After=network.target
[Service]
ExecStart=$WORK_DIR/cloudflared $ARGO_RUN
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
[Service]
ExecStart=$WORK_DIR/xray -config $WORK_DIR/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl restart nginx xray
    systemctl enable --now argo
    
    info "========= 安装完成 ========="
    echo "链接: vless://$UUID@$SERVER:443?encryption=none&security=tls&sni=$ARGO_DOMAIN&type=ws&host=$ARGO_DOMAIN&path=%2F$WS_PATH#ArgoX"
}

install_argox

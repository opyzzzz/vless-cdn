#!/usr/bin/env bash

# =====================================================
# ArgoX Integrated Edition (Auto-Clean & Fix)
# Version: 1.6.18 (2025.12.16)
# =====================================================

VERSION='1.6.18'
WORK_DIR='/etc/argox'
BIN_PATH='/usr/local/bin/argox'
NGINX_PORT='80'
XRAY_PORT='8080'
METRICS_PORT='3333'
DEFAULT_XRAY_VERSION='26.2.6'
CDN_DOMAIN=("skk.moe" "ip.sb" "time.is" "bestcf.top" "cf.090227.xyz")

# 彩色输出
info(){ echo -e "\033[32m\033[01m$*\033[0m"; }
warning(){ echo -e "\033[31m\033[01m$*\033[0m"; }
reading(){ read -rp "$(echo -e "\033[32m\033[01m$1\033[0m")" "$2"; }

# 1. 自动删除已有隧道和残留
clean_old_install(){
    info "正在清理旧的安装环境，防止冲突..."
    systemctl stop argo xray nginx 2>/dev/null
    systemctl disable argo xray nginx 2>/dev/null
    rm -f /etc/systemd/system/argo.service
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload
    # 彻底清除旧文件，确保重新下载
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
}

# 2. 系统检测与环境准备
check_env(){
    [ "$(id -u)" != 0 ] && { warning "请使用 root 运行"; exit 1; }
    case $(uname -m) in
        x86_64|amd64) ARGO_ARCH=amd64; XRAY_ARCH=64 ;;
        aarch64|arm64) ARGO_ARCH=arm64; XRAY_ARCH=arm64-v8a ;;
        *) warning "不支持的架构"; exit 1 ;;
    esac
    apt update -y && apt install -y wget curl unzip nginx 2>/dev/null || apk add wget curl unzip nginx 2>/dev/null
}

# 3. 组件下载
download_components(){
    info "正在拉取核心组件 (Cloudflared & Xray)..."
    wget -qO "$WORK_DIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH"
    chmod +x "$WORK_DIR/cloudflared"
    
    wget -qO "$WORK_DIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/v$DEFAULT_XRAY_VERSION/Xray-linux-$XRAY_ARCH.zip"
    unzip -oj "$WORK_DIR/xray.zip" "xray" -d "$WORK_DIR"
    chmod +x "$WORK_DIR/xray"
    rm -f "$WORK_DIR/xray.zip"
}

# 4. 核心安装逻辑
install_argox(){
    clean_old_install
    check_env
    
    # --- 交互提示部分 (解决你提到的提示缺失问题) ---
    info "--- 基础配置 ---"
    reading "请输入 Argo 域名 (留空则使用临时隧道): " ARGO_DOMAIN
    if [ -n "$ARGO_DOMAIN" ]; then
        reading "请输入 Argo Token 或 Json 内容: " ARGO_AUTH
    fi
    
    reading "请输入优选域名 [默认: ${CDN_DOMAIN[0]}]: " SERVER
    SERVER=${SERVER:-${CDN_DOMAIN[0]}}
    
    UUID_DEFAULT=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")
    reading "请输入 UUID [默认: $UUID_DEFAULT]: " UUID
    UUID=${UUID:-$UUID_DEFAULT}
    
    reading "请输入 WS 路径 [默认: argox]: " WS_PATH
    WS_PATH=${WS_PATH:-"argox"}

    download_components

    # 生成 Nginx 配置 (伪装站 + WS 转发)
    cat > "$WORK_DIR/nginx.conf" <<EOF
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

    # 生成 Xray 配置
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

    # --- 确定 Argo 启动参数 (修复临时隧道失败和固定隧道冲突) ---
    if [ -z "$ARGO_DOMAIN" ]; then
        # 临时隧道专用
        ARGO_ARGS="tunnel --url http://localhost:$NGINX_PORT --no-autoupdate --metrics localhost:$METRICS_PORT"
    elif [[ "$ARGO_AUTH" =~ "eyJh" ]]; then
        # Token 模式
        ARGO_ARGS="tunnel --no-autoupdate run --token $ARGO_AUTH"
    else
        # Json 证书模式
        echo "$ARGO_AUTH" > "$WORK_DIR/argo.json"
        ARGO_ARGS="tunnel --no-autoupdate --cred-file $WORK_DIR/argo.json run $ARGO_DOMAIN"
    fi

    # 写入并启动 Systemd 服务
    cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel
After=network.target
[Service]
ExecStart=$WORK_DIR/cloudflared $ARGO_ARGS
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=$WORK_DIR/xray -config $WORK_DIR/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    cp "$WORK_DIR/nginx.conf" /etc/nginx/nginx.conf
    systemctl daemon-reload
    systemctl restart nginx xray
    systemctl enable --now argo
    
    # 建立快捷命令
    ln -sf "$(realpath "$0")" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    
    show_node_info "$ARGO_DOMAIN" "$UUID" "$WS_PATH" "$SERVER"
}

show_node_info(){
    local domain=$1; local uuid=$2; local path=$3; local server=$4
    if [ -z "$domain" ]; then
        info "正在获取临时隧道域名 (约10秒)..."
        sleep 10
        domain=$(curl -s http://localhost:$METRICS_PORT/metrics | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | head -n 1)
    fi
    clear
    info "=========================================="
    info "         ArgoX 安装部署成功"
    info "=========================================="
    echo "域名: $domain"
    echo "UUID: $uuid"
    echo "路径: /$path"
    echo "优选: $server"
    echo "------------------------------------------"
    info "VLESS 链接:"
    echo "vless://$uuid@$server:443?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=%2F$path#ArgoX_$(hostname)"
    info "=========================================="
}

# 运行
install_argox

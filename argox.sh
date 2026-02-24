#!/usr/bin/env bash

# =====================================================
# ArgoX Integrated & Fixed Edition
# Version: 1.6.16 (2025.12.16)
# =====================================================

VERSION='1.6.16'
WORK_DIR='/etc/argox'
TEMP_DIR='/tmp/argox'
WS_PATH_DEFAULT='argox'
NGINX_PORT='80'
XRAY_PORT='8080'
METRICS_PORT='3333'
DEFAULT_XRAY_VERSION='26.2.6'
CDN_DOMAIN=("skk.moe" "ip.sb" "time.is" "cfip.xxxxxxxx.tk" "bestcf.top" "cdn.2020111.xyz" "xn--b6gac.eu.org" "cf.090227.xyz")

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$TEMP_DIR" "$WORK_DIR"

# ==========================
# 多语言提示词字典
# ==========================
E[10]="(3/8) Please enter Argo Domain (Leave blank for temporary tunnel):"
C[10]="(3/8) 请输入 Argo 域名 (留空则使用临时隧道):"
E[11]="Please enter Argo Token/Json/API content:"
C[11]="请输入 Argo Token/Json/API 认证内容:"
E[42]="(5/8) Preferred CDN Domain [Default: ${CDN_DOMAIN[0]}]:"
C[42]="(5/8) 优选域名 [默认: ${CDN_DOMAIN[0]}]:"
E[68]="(1/8) Install Nginx for FakeSite? [y/n, Default: y]:"
C[68]="(1/8) 是否安装 Nginx 伪装站? [y/n, 默认: y]:"

warning(){ echo -e "\033[31m\033[01m$*\033[0m"; }
error(){ echo -e "\033[31m\033[01m$*\033[0m"; exit 1; }
info(){ echo -e "\033[32m\033[01m$*\033[0m"; }
hint(){ echo -e "\033[33m\033[01m$*\033[0m"; }
reading(){ read -rp "$(info "$1")" "$2"; }
[[ "$LANG" =~ "zh" ]] && L="C" || L="E"
text() { eval echo "\${$L[$1]}"; }

# ==========================
# 系统环境检测
# ==========================
check_env(){
  [ "$(id -u)" != 0 ] && error "必须使用 root 运行"
  [ -f /etc/os-release ] && . /etc/os-release
  [[ "$NAME" =~ "Alpine" ]] && SYSTEM="Alpine" || SYSTEM="Linux"
  
  case $(uname -m) in
    x86_64|amd64) ARGO_ARCH=amd64; XRAY_ARCH=64 ;;
    aarch64|arm64) ARGO_ARCH=arm64; XRAY_ARCH=arm64-v8a ;;
    *) error "架构不支持" ;;
  esac
  
  if [ "$SYSTEM" = "Alpine" ]; then
    ARGO_SVC='/etc/init.d/argo'; XRAY_SVC='/etc/init.d/xray'
  else
    ARGO_SVC='/etc/systemd/system/argo.service'; XRAY_SVC='/etc/systemd/system/xray.service'
  fi
}

# ==========================
# 组件下载与配置
# ==========================
download_components(){
  info "正在下载核心组件..."
  # Cloudflared
  wget -qO "$WORK_DIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH"
  chmod +x "$WORK_DIR/cloudflared"
  
  # Xray
  wget -qO "$TEMP_DIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/v$DEFAULT_XRAY_VERSION/Xray-linux-$XRAY_ARCH.zip"
  apt install unzip -y || apk add unzip
  unzip -oj "$TEMP_DIR/xray.zip" "xray" -d "$WORK_DIR"
  chmod +x "$WORK_DIR/xray"
}

setup_nginx() {
  info "配置 Nginx..."
  [ "$SYSTEM" = "Alpine" ] && apk add nginx || apt install nginx -y
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
}

# ==========================
# 安装主逻辑
# ==========================
install_argox(){
  check_env
  
  # 交互输入
  reading "$(text 68) " IS_NGINX
  reading "$(text 10) " ARGO_DOMAIN
  [ -n "$ARGO_DOMAIN" ] && reading "$(text 11) " ARGO_AUTH
  reading "$(text 42) " SERVER
  SERVER=${SERVER:-${CDN_DOMAIN[0]}}
  
  UUID_DEFAULT=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")
  reading "请输入 UUID [$UUID_DEFAULT]: " UUID
  UUID=${UUID:-$UUID_DEFAULT}
  reading "请输入 WS 路径 [$WS_PATH_DEFAULT]: " WS_PATH
  WS_PATH=${WS_PATH:-$WS_PATH_DEFAULT}

  download_components
  [ "${IS_NGINX,,}" != "n" ] && setup_nginx

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

  # 写入服务并启动
  if [ -z "$ARGO_DOMAIN" ]; then
    ARGO_RUN="$WORK_DIR/cloudflared tunnel --url http://localhost:$NGINX_PORT --no-autoupdate --metrics localhost:$METRICS_PORT"
  else
    if [[ "$ARGO_AUTH" =~ "token" ]]; then
      ARGO_RUN="$WORK_DIR/cloudflared tunnel --no-autoupdate run --token $ARGO_AUTH"
    else
      echo "$ARGO_AUTH" > "$WORK_DIR/argo.json"
      ARGO_RUN="$WORK_DIR/cloudflared tunnel --no-autoupdate --origincert $WORK_DIR/argo.json run $ARGO_DOMAIN"
    fi
  fi

  if [ "$SYSTEM" != "Alpine" ]; then
    cat > "$ARGO_SVC" <<EOF
[Unit]
Description=Argo Tunnel
After=network.target
[Service]
ExecStart=$ARGO_RUN
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    cat > "$XRAY_SVC" <<EOF
[Unit]
Description=Xray
After=network.target
[Service]
ExecStart=$WORK_DIR/xray -config $WORK_DIR/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now argo xray
    [ "${IS_NGINX,,}" != "n" ] && { cp "$WORK_DIR/nginx.conf" /etc/nginx/nginx.conf; systemctl restart nginx; }
  fi

  # 建立快捷命令
  ln -sf "$(realpath "$0")" /usr/local/bin/argox
  chmod +x /usr/local/bin/argox

  # 获取并展示信息
  show_node_info
}

show_node_info(){
  if [ -z "$ARGO_DOMAIN" ]; then
    info "正在等待临时域名生成..."
    sleep 10
    ARGO_DOMAIN=$(curl -s http://localhost:$METRICS_PORT/metrics | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | head -n 1)
  fi
  
  clear
  info "========= ArgoX 安装完成 ========="
  echo "域名: $ARGO_DOMAIN"
  echo "UUID: $UUID"
  echo "路径: /$WS_PATH"
  echo "优选域名: $SERVER"
  echo "--------------------------------"
  hint "VLESS 链接:"
  echo "vless://$UUID@$SERVER:443?encryption=none&security=tls&sni=$ARGO_DOMAIN&type=ws&host=$ARGO_DOMAIN&path=%2F$WS_PATH#ArgoX_$(hostname)"
  info "================================"
}

# 简单菜单
clear
echo "1. 安装/修复 ArgoX"
echo "2. 查看节点信息"
echo "0. 退出"
read -p "请选择: " opt
case $opt in
  1) install_argox ;;
  2) show_node_info ;;
  *) exit ;;
esac

#!/bin/bash

# ==========================================
# ArgoX + Suoha 融合版
# 安装路径统一: /opt/suoha
# ==========================================

clear

echo "  _____       __     __          "
echo " |  __ \      \ \   / /          "
echo " | |__) |_ _ __\ \_/ /   _ _ __  "
echo " |  ___/ _\` / __\   / | | | '_ \ "
echo " | |  | (_| \__ \| || |_| | | | |"
echo " |_|   \__,_|___/|_| \__,_|_| |_|"
echo
echo "ArgoX + Suoha 融合安装脚本"
echo

if [ "$(id -u)" != 0 ]; then
  echo "请使用 root 运行"
  exit 1
fi

mkdir -p /opt/suoha
cd /opt/suoha || exit

# ==========================
# 架构检测
# ==========================
case $(uname -m) in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=arm ;;
  *) echo "架构不支持"; exit ;;
esac

# ==========================
# 下载 Xray
# ==========================
echo "下载 Xray..."
wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH.zip -O xray.zip
unzip -qo xray.zip
mv xray /opt/suoha/
chmod +x /opt/suoha/xray
rm -rf xray.zip geo*

# ==========================
# 下载 Cloudflared
# ==========================
echo "下载 Cloudflared..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH -O cloudflared-linux
chmod +x cloudflared-linux
mv cloudflared-linux /opt/suoha/

# ==========================
# 选择协议
# ==========================
read -p "请选择协议 1.vmess 2.vless (默认2): " protocol
[ -z "$protocol" ] && protocol=2

UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=$((RANDOM%10000+10000))
WSPATH=$(echo $UUID | cut -d '-' -f1)

# ==========================
# 生成 Xray 配置
# ==========================
if [ "$protocol" == "1" ]; then
cat >/opt/suoha/config.json<<EOF
{
  "inbounds":[
    {
      "port":$PORT,
      "listen":"127.0.0.1",
      "protocol":"vmess",
      "settings":{
        "clients":[{"id":"$UUID"}]
      },
      "streamSettings":{
        "network":"ws",
        "wsSettings":{"path":"/$WSPATH"}
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF
else
cat >/opt/suoha/config.json<<EOF
{
  "inbounds":[
    {
      "port":$PORT,
      "listen":"127.0.0.1",
      "protocol":"vless",
      "settings":{
        "decryption":"none",
        "clients":[{"id":"$UUID"}]
      },
      "streamSettings":{
        "network":"ws",
        "wsSettings":{"path":"/$WSPATH"}
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF
fi

# ==========================
# 选择 Argo 模式
# ==========================
echo
echo "1. Quick Tunnel (临时隧道)"
echo "2. Token 固定隧道"
read -p "请选择 (默认1): " argo_mode
[ -z "$argo_mode" ] && argo_mode=1

if [ "$argo_mode" == "1" ]; then

  echo "启动 Quick Tunnel..."
  nohup /opt/suoha/cloudflared-linux tunnel --url http://localhost:$PORT >argo.log 2>&1 &
  sleep 5
  DOMAIN=$(grep trycloudflare argo.log | sed -n 's/.*https:\/\///p' | head -1)

else

  read -p "请输入 Argo Token: " TOKEN
  mkdir -p /root/.cloudflared

cat >/opt/suoha/config.yaml<<EOF
tunnel: auto
credentials-file: /root/.cloudflared/token.json
ingress:
  - hostname: example.com
    service: http://localhost:$PORT
  - service: http_status:404
EOF

echo "$TOKEN" >/root/.cloudflared/token.json

  nohup /opt/suoha/cloudflared-linux tunnel --config /opt/suoha/config.yaml run >argo.log 2>&1 &
  sleep 5
  DOMAIN="请在CF后台绑定域名"

fi

# ==========================
# 生成节点
# ==========================
if [ "$protocol" == "1" ]; then
LINK="vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"argo\",\"add\":\"$DOMAIN\",\"port\":\"443\",\"id\":\"$UUID\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"/$WSPATH\",\"tls\":\"tls\"}" | base64 -w 0)"
else
LINK="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=/$WSPATH#argo"
fi

echo "$LINK" >/opt/suoha/v2ray.txt

# ==========================
# 创建 systemd 服务
# ==========================
cat >/lib/systemd/system/xray.service<<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/opt/suoha/xray run -config /opt/suoha/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat >/lib/systemd/system/cloudflared.service<<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/opt/suoha/cloudflared-linux tunnel --url http://localhost:$PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl enable cloudflared
systemctl restart xray
systemctl restart cloudflared

# ==========================
# 创建管理命令 suoha
# ==========================
cat >/usr/bin/suoha<<EOF
#!/bin/bash
echo "1. 启动服务"
echo "2. 停止服务"
echo "3. 重启服务"
echo "4. 查看节点"
echo "5. 卸载"
read -p "请选择: " m
case \$m in
1) systemctl start xray cloudflared ;;
2) systemctl stop xray cloudflared ;;
3) systemctl restart xray cloudflared ;;
4) cat /opt/suoha/v2ray.txt ;;
5)
 systemctl stop xray cloudflared
 systemctl disable xray cloudflared
 rm -rf /opt/suoha
 rm -f /lib/systemd/system/xray.service
 rm -f /lib/systemd/system/cloudflared.service
 rm -f /usr/bin/suoha
 systemctl daemon-reload
 echo "卸载完成"
 ;;
esac
EOF

chmod +x /usr/bin/suoha

echo
echo "======================================"
echo "安装完成"
echo "节点信息："
cat /opt/suoha/v2ray.txt
echo "管理命令: suoha"
echo "======================================"

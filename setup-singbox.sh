#!/bin/bash
set -e

echo "=========================================="
echo "🔧 Sing-Box + Nginx + acme.sh 自动部署脚本"
echo "=========================================="

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行: sudo bash setup-singbox.sh"
  exit 1
fi

# 输入信息
read -rp "请输入你的域名 (例如: www.google.com): " DOMAIN
read -rp "请输入你的邮箱 (例如: xx@xx.xx): " EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN
read -rp "请输入 Cloudflare Account ID: " CF_ACCOUNT_ID

# 写入环境变量
echo "🔧 写入 Cloudflare API 环境变量..."
echo "export CF_Token=\"$CF_TOKEN\"" >> ~/.bashrc
echo "export CF_Account_ID=\"$CF_ACCOUNT_ID\"" >> ~/.bashrc
source ~/.bashrc

# 安装依赖
echo "🚀 安装依赖..."
apt update -y
apt install -y curl socat nginx ufw jq

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
  echo "📦 安装 sing-box..."
  bash <(curl -fsSL https://sing-box.app/install.sh)
fi

# 启用并配置 UFW
echo "🧱 配置防火墙..."
ufw --force enable
ufw default allow outgoing
ufw default deny incoming
ufw allow 8443 comment 'nginx HTTPS (TCP+UDP)'
ufw allow 443 comment 'sing-box HTTPS (TCP+UDP)'
ufw allow 22 comment 'SSH port'
ufw delete allow 80 >/dev/null 2>&1 || true

# 安装 acme.sh
echo "🔑 安装 acme.sh..."
curl https://get.acme.sh | sh
source ~/.bashrc

# 申请证书
echo "📜 使用 Cloudflare DNS API 签发证书..."
/root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --accountemail "$EMAIL" --server letsencrypt

# 安装证书到系统路径
CERT_PATH="/root/.acme.sh/${DOMAIN}_ecc"
SSL_CERT="$CERT_PATH/fullchain.cer"
SSL_KEY="$CERT_PATH/${DOMAIN}.key"

# Reality 密钥生成
echo "🔐 生成 Reality Keypair..."
REALITY_INFO=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$REALITY_INFO" | grep PrivateKey | awk '{print $2}')
PUBLIC_KEY=$(echo "$REALITY_INFO" | grep PublicKey | awk '{print $2}')

SHORT_ID=$(sing-box generate rand 8 --hex)

# 创建 sing-box.conf
echo "⚙️ 生成 sing-box 配置文件..."
cat >/root/sing-box.conf <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "all.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "sniff": true,
      "users": [
        {
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "min_version": "1.3",
        "max_version": "1.3",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "127.0.0.1",
            "server_port": 8443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
EOF

# Nginx 配置
echo "🕸️ 配置 Nginx..."
cat >/etc/nginx/nginx.conf <<EOF
user root;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        return 444;
    }

    server {
        listen 80;
        listen [::]:80;
        server_name $DOMAIN;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 8443 ssl http2;
        listen [::]:8443 ssl http2;
        server_name $DOMAIN;
        ssl_certificate      $SSL_CERT;
        ssl_certificate_key  $SSL_KEY;
        ssl_protocols TLSv1.3;
        ssl_ecdh_curve X25519:prime256v1:secp384r1;
        ssl_prefer_server_ciphers off;

        location / {
            add_header Content-Type 'text/html; charset=utf-8';
            return 200 'OK';
        }
    }
}
EOF

nginx -t && systemctl restart nginx

# 输出信息
echo "=========================================="
echo "✅ Sing-box 服务端配置完成！"
echo "=========================================="
echo "📍 域名: $DOMAIN"
echo "📜 证书路径: $SSL_CERT"
echo "🔑 PrivateKey: $PRIVATE_KEY"
echo "🔓 PublicKey:  $PUBLIC_KEY"
echo "🧩 short_id:   $SHORT_ID"
echo "⚙️ 配置文件: /root/sing-box.conf"
echo "运行命令:"
echo "   ./sing-box run -c /root/sing-box.conf -C /root/.sing-box/"
echo "=========================================="

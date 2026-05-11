#!/bin/bash
set -e
exec > >(tee -i /root/setup-singbox.log)
exec 2>&1

echo "=========================================="
echo "🔧 Sing-Box + Nginx + acme.sh 自动部署脚本"
echo "=========================================="

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行: sudo bash setup-singbox.sh"
  exit 1
fi

# 检查 /root/.sing-box/ 是否存在
if [ ! -d "/root/.sing-box" ]; then
  echo "📁 创建目录 /root/.sing-box/"
  mkdir -p /root/.sing-box
fi

# 输入信息并校验
while true; do
  read -rp "请输入你的域名 (例如: www.google.com): " DOMAIN
  [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] && break
  echo "❌ 域名格式不正确，请重新输入"
done

while true; do
  read -rp "请输入你的邮箱 (例如: your@email.com): " EMAIL
  [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
  echo "❌ 邮箱格式不正确，请重新输入"
done

read -rp "请输入 Cloudflare API Token: " CF_TOKEN
read -rp "请输入 Cloudflare Account ID: " CF_ACCOUNT_ID

# 写入环境变量
echo "🔧 写入 Cloudflare API 环境变量..."
grep -q CF_Token ~/.bashrc || echo "export CF_Token=\"$CF_TOKEN\"" >> ~/.bashrc
grep -q CF_Account_ID ~/.bashrc || echo "export CF_Account_ID=\"$CF_ACCOUNT_ID\"" >> ~/.bashrc
source ~/.bashrc

# 安装依赖
echo "🚀 安装依赖..."
for pkg in curl socat nginx ufw jq; do
  if ! command -v $pkg &>/dev/null; then
    apt update -y
    apt install -y $pkg
  fi
done

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
  echo "📦 安装 sing-box..."

  ARCH=$(dpkg --print-architecture)

  case "$ARCH" in
    amd64)
      SB_ARCH="amd64"
      ;;
    arm64)
      SB_ARCH="arm64"
      ;;
    *)
      echo "❌ 不支持架构: $ARCH"
      exit 1
      ;;
  esac

  VERSION="1.12.0"

  URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_linux_${SB_ARCH}.deb"

  echo "⬇️ 下载: $URL"

  curl -Lo /tmp/sing-box.deb "$URL"

  dpkg -i /tmp/sing-box.deb
fi

# 配置 UFW 防火墙
echo "🧱 配置防火墙..."
ufw --force enable
ufw default allow outgoing
ufw default deny incoming
ufw allow 8443/tcp comment 'nginx HTTPS'
ufw allow 443/tcp comment 'sing-box HTTPS'
ufw allow 22/tcp comment 'SSH port'
ufw status | grep -q "80" && ufw delete allow 80

# 安装 acme.sh
if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
  echo "🔑 安装 acme.sh..."
  curl https://get.acme.sh | sh
  source ~/.bashrc
fi

# 注册 acme 账户
~/.acme.sh/acme.sh --register-account -m "$EMAIL"

# 申请证书
echo "📜 使用 Cloudflare DNS API 签发证书..."

if ! ~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$DOMAIN" \
  --keylength ec-256; then

  echo "❌ 证书签发失败"
  exit 1
fi

CERT_PATH="$HOME/.acme.sh/${DOMAIN}_ecc"

SSL_CERT="$CERT_PATH/fullchain.cer"
SSL_KEY="$CERT_PATH/$DOMAIN.key"

# Reality 密钥生成
echo "🔐 生成 Reality Keypair..."
REALITY_INFO=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$REALITY_INFO" | grep PrivateKey | awk '{print $2}')
PUBLIC_KEY=$(echo "$REALITY_INFO" | grep PublicKey | awk '{print $2}')
SHORT_ID=$(sing-box generate rand 8 --hex)

# 保存 Reality Key
echo "$PRIVATE_KEY" > /root/singbox-reality-private.key
echo "$PUBLIC_KEY" > /root/singbox-reality-public.key
echo "$SHORT_ID" > /root/singbox-reality-shortid.txt

# 创建 sing-box.conf
CONF_FILE="/root/sing-box.conf"
if [ -f "$CONF_FILE" ]; then
  echo "📦 备份旧配置 $CONF_FILE -> ${CONF_FILE}.bak"
  mv "$CONF_FILE" "${CONF_FILE}.bak"
fi

cat > "$CONF_FILE" <<EOF
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

# 配置 nginx
NGINX_FILE="/etc/nginx/sites-available/$DOMAIN.conf"
if [ -f "$NGINX_FILE" ]; then
  mv "$NGINX_FILE" "${NGINX_FILE}.bak"
fi

cat > "$NGINX_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host:8443\$request_uri;
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
EOF

ln -sf "$NGINX_FILE" /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# 创建 systemd 服务
SERVICE_FILE="/etc/systemd/system/sing-box.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $CONF_FILE -C /root/.sing-box/
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

# 输出信息
echo "=========================================="
echo "✅ Sing-box 服务端配置完成！"
echo "=========================================="
echo "📍 域名: $DOMAIN"
echo "📜 证书路径: $SSL_CERT"
echo "🔑 PrivateKey: $PRIVATE_KEY"
echo "🔓 PublicKey:  $PUBLIC_KEY"
echo "🧩 short_id:   $SHORT_ID"
echo "⚙️ 配置文件: $CONF_FILE"
echo "🛠️ systemd 服务已启用: sing-box.service"
echo "运行命令:"
echo "   systemctl status sing-box"
echo "=========================================="

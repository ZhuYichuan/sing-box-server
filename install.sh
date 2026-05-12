cat > install.sh <<'EOF'
#!/usr/bin/env bash

set -e

# =========================================================
# 基础
# =========================================================

if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 运行"
    exit 1
fi

LOG_FILE="/var/log/singbox-install.log"

mkdir -p /var/log

exec > >(tee -a "$LOG_FILE") 2>&1

# =========================================================
# 输入
# =========================================================

read -rp "域名: " DOMAIN
read -rp "邮箱: " EMAIL
read -rp "Cloudflare Token: " CF_TOKEN

# =========================================================
# 目录
# =========================================================

mkdir -p /etc/sing-box
mkdir -p /etc/sing-box/cert
mkdir -p /etc/sing-box/reality
mkdir -p /var/log/sing-box

# =========================================================
# 安装依赖
# =========================================================

echo
echo "安装依赖..."

apt update

DEBIAN_FRONTEND=noninteractive apt install -y \
    curl \
    wget \
    jq \
    socat \
    nginx \
    ufw \
    uuid-runtime

# =========================================================
# 安装 sing-box
# =========================================================

if ! command -v sing-box >/dev/null 2>&1; then

    echo
    echo "安装 sing-box..."

    ARCH=$(dpkg --print-architecture)

    case "$ARCH" in
        amd64)
            SB_ARCH="amd64"
            ;;
        arm64)
            SB_ARCH="arm64"
            ;;
        *)
            echo "不支持架构"
            exit 1
            ;;
    esac

    VERSION="1.12.0"

    wget -O /tmp/sing-box.deb \
    "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_linux_${SB_ARCH}.deb"

    dpkg -i /tmp/sing-box.deb

fi

SB_BIN=$(command -v sing-box)

# =========================================================
# acme.sh
# =========================================================

if [ ! -f ~/.acme.sh/acme.sh ]; then

    curl https://get.acme.sh | sh

fi

export CF_Token="$CF_TOKEN"

cat > ~/.acme.sh/account.conf <<EOCF
SAVED_CF_Token='$CF_TOKEN'
EOCF

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# =========================================================
# Reality Key
# =========================================================

PRIVATE_FILE="/etc/sing-box/reality/private.key"
PUBLIC_FILE="/etc/sing-box/reality/public.key"

if [ -f "$PRIVATE_FILE" ] && [ -f "$PUBLIC_FILE" ]; then

    PRIVATE_KEY=$(cat "$PRIVATE_FILE")
    PUBLIC_KEY=$(cat "$PUBLIC_FILE")

else

    REALITY_OUTPUT=$($SB_BIN generate reality-keypair)

    PRIVATE_KEY=$(echo "$REALITY_OUTPUT" | grep PrivateKey | awk '{print $2}')
    PUBLIC_KEY=$(echo "$REALITY_OUTPUT" | grep PublicKey | awk '{print $2}')

    echo "$PRIVATE_KEY" > "$PRIVATE_FILE"
    echo "$PUBLIC_KEY" > "$PUBLIC_FILE"

fi

# =========================================================
# Short ID
# =========================================================

SHORTID_FILE="/etc/sing-box/reality/shortid"

if [ -f "$SHORTID_FILE" ]; then

    SHORT_ID=$(cat "$SHORTID_FILE")

else

    SHORT_ID=$($SB_BIN generate rand 8 --hex)

    echo "$SHORT_ID" > "$SHORTID_FILE"

fi

# =========================================================
# 申请证书
# =========================================================

echo
echo "申请 SSL 证书..."

~/.acme.sh/acme.sh \
    --register-account \
    -m "$EMAIL" || true

~/.acme.sh/acme.sh \
    --issue \
    --dns dns_cf \
    -d "$DOMAIN" \
    --keylength ec-256 \
    --force

CERT_DIR="/etc/sing-box/cert"

~/.acme.sh/acme.sh \
    --install-cert \
    -d "$DOMAIN" \
    --ecc \
    --fullchain-file "$CERT_DIR/fullchain.crt" \
    --key-file "$CERT_DIR/private.key" \
    --reloadcmd "systemctl restart nginx && systemctl restart sing-box"

# =========================================================
# nginx
# =========================================================

echo
echo "配置 nginx..."

NGINX_FILE="/etc/nginx/sites-available/$DOMAIN.conf"

cat > "$NGINX_FILE" <<EONGINX
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

    ssl_certificate     $CERT_DIR/fullchain.crt;
    ssl_certificate_key $CERT_DIR/private.key;
    ssl_session_tickets off;
    ssl_protocols TLSv1.3;
    ssl_ecdh_curve X25519:prime256v1:secp384r1;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=63072000" always;

    location / {
        try_files $uri $uri/ =404;
    }
}
EONGINX

ln -sf "$NGINX_FILE" /etc/nginx/sites-enabled/

rm -f /etc/nginx/sites-enabled/default

nginx -t

systemctl enable nginx

systemctl restart nginx

# =========================================================
# sing-box 配置
# =========================================================

echo
echo "配置 sing-box..."

CONFIG_FILE="/etc/sing-box/config.json"

cat > "$CONFIG_FILE" <<EOCONFIG
{
  "log": {
    "level": "info",
    "timestamp": true,
    "output": "/var/log/sing-box/sing-box.log"
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
        "reality": {
          "enabled": true,
          "min_version": "1.3",
          "max_version": "1.3",
          "handshake": {
            "server": "127.0.0.1",
            "server_port": 8443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "$SHORT_ID"
          ]
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
EOCONFIG

# =========================================================
# 检查配置
# =========================================================

$SB_BIN check -c "$CONFIG_FILE"

# =========================================================
# systemd
# =========================================================

SERVICE_FILE="/etc/systemd/system/sing-box.service"

cat > "$SERVICE_FILE" <<EOSERVICE
[Unit]
Description=sing-box
After=network.target nss-lookup.target

[Service]

Type=simple

ExecStart=$SB_BIN run -c $CONFIG_FILE

Restart=on-failure
RestartSec=5

LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOSERVICE

systemctl daemon-reload

systemctl enable sing-box

systemctl restart sing-box

# =========================================================
# 防火墙
# =========================================================

ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw allow 8443/tcp || true

ufw --force enable

# =========================================================
# 输出
# =========================================================

echo
echo "=================================================="
echo "安装完成"
echo "=================================================="

echo
echo "域名:"
echo "$DOMAIN"

echo
echo "Public Key:"
echo "$PUBLIC_KEY"

echo
echo "Short ID:"
echo "$SHORT_ID"

echo
echo "配置文件:"
echo "$CONFIG_FILE"

echo
echo "日志:"
echo "/var/log/sing-box/sing-box.log"

echo
echo "=================================================="

EOF

chmod +x install.sh

echo
echo "install.sh 已生成"

cat > install.sh <<'EOF'
#!/usr/bin/env bash

# =========================================================
# sing-box Reality + Nginx + acme.sh
# 幂等安装 / 可重复运行
# =========================================================

set -e

LOG_FILE="/var/log/singbox-install.log"

mkdir -p /var/log

exec > >(tee -a "$LOG_FILE") 2>&1

# =========================================================
# Root 检查
# =========================================================

if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 运行"
    exit 1
fi

# =========================================================
# 基础目录
# =========================================================

mkdir -p /etc/sing-box
mkdir -p /etc/sing-box/reality
mkdir -p /etc/sing-box/cert
mkdir -p /var/log/sing-box

# =========================================================
# 输入
# =========================================================

read -rp "请输入域名: " DOMAIN
read -rp "请输入邮箱: " EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

# =========================================================
# Cloudflare API
# =========================================================

export CF_Token="$CF_TOKEN"

mkdir -p ~/.acme.sh

cat > ~/.acme.sh/account.conf <<EOCF
SAVED_CF_Token='$CF_TOKEN'
EOCF

# =========================================================
# 安装依赖
# =========================================================

echo
echo "=================================================="
echo "安装依赖"
echo "=================================================="

apt update

DEBIAN_FRONTEND=noninteractive apt install -y \
    curl \
    wget \
    socat \
    jq \
    nginx \
    ufw \
    uuid-runtime

# =========================================================
# 安装 sing-box
# =========================================================

if ! command -v sing-box >/dev/null 2>&1; then

    echo
    echo "=================================================="
    echo "安装 sing-box"
    echo "=================================================="

    ARCH=$(dpkg --print-architecture)

    case "$ARCH" in
        amd64)
            SB_ARCH="amd64"
            ;;
        arm64)
            SB_ARCH="arm64"
            ;;
        *)
            echo "不支持架构: $ARCH"
            exit 1
            ;;
    esac

    VERSION="1.12.0"

    URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_linux_${SB_ARCH}.deb"

    wget -O /tmp/sing-box.deb "$URL"

    dpkg -i /tmp/sing-box.deb

fi

SB_BIN=$(command -v sing-box)

# =========================================================
# 安装 acme.sh
# =========================================================

if [ ! -f ~/.acme.sh/acme.sh ]; then

    echo
    echo "=================================================="
    echo "安装 acme.sh"
    echo "=================================================="

    curl https://get.acme.sh | sh

fi

# =========================================================
# 切换 Let's Encrypt
# =========================================================

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# =========================================================
# Reality 参数
# =========================================================

UUID_FILE="/etc/sing-box/reality/uuid"
PRIVATE_FILE="/etc/sing-box/reality/private.key"
PUBLIC_FILE="/etc/sing-box/reality/public.key"
SHORTID_FILE="/etc/sing-box/reality/shortid"

# UUID

if [ -f "$UUID_FILE" ]; then

    UUID=$(cat "$UUID_FILE")

else

    UUID=$(uuidgen)

    echo "$UUID" > "$UUID_FILE"

fi

# Reality Key

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

# Short ID

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
echo "=================================================="
echo "申请 SSL 证书"
echo "=================================================="

~/.acme.sh/acme.sh \
    --register-account \
    -m "$EMAIL" || true

~/.acme.sh/acme.sh \
    --issue \
    --dns dns_cf \
    -d "$DOMAIN" \
    --keylength ec-256 \
    --force \
    --debug

CERT_DIR="/etc/sing-box/cert"

~/.acme.sh/acme.sh \
    --install-cert \
    -d "$DOMAIN" \
    --ecc \
    --fullchain-file "$CERT_DIR/fullchain.crt" \
    --key-file "$CERT_DIR/private.key" \
    --reloadcmd "systemctl restart nginx sing-box"

# =========================================================
# nginx
# =========================================================

echo
echo "=================================================="
echo "配置 nginx"
echo "=================================================="

NGINX_FILE="/etc/nginx/sites-available/$DOMAIN.conf"

cat > "$NGINX_FILE" <<EONGINX
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

    ssl_certificate     $CERT_DIR/fullchain.crt;
    ssl_certificate_key $CERT_DIR/private.key;

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;

    location / {

        proxy_pass https://www.cloudflare.com;

        proxy_ssl_server_name on;

        proxy_set_header Host www.cloudflare.com;

        proxy_set_header User-Agent \$http_user_agent;

    }
}
EONGINX

ln -sf "$NGINX_FILE" /etc/nginx/sites-enabled/

rm -f /etc/nginx/sites-enabled/default

nginx -t

systemctl restart nginx

# =========================================================
# sing-box 配置
# =========================================================

echo
echo "=================================================="
echo "配置 sing-box"
echo "=================================================="

CONFIG_FILE="/etc/sing-box/config.json"

cat > "$NGINX_FILE" <<EONGINX
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

    ssl_certificate     $CERT_DIR/fullchain.crt;
    ssl_certificate_key $CERT_DIR/private.key;

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;

    location / {

        proxy_pass https://www.cloudflare.com;

        proxy_ssl_server_name on;

        proxy_set_header Host www.cloudflare.com;

        proxy_set_header User-Agent \$http_user_agent;

    }
}
EONGINX

# =========================================================
# 配置检查
# =========================================================

echo
echo "=================================================="
echo "检查配置"
echo "=================================================="

$SB_BIN check -c "$CONFIG_FILE"

# =========================================================
# systemd
# =========================================================

echo
echo "=================================================="
echo "配置 systemd"
echo "=================================================="

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
# UFW
# =========================================================

echo
echo "=================================================="
echo "配置防火墙"
echo "=================================================="

ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw allow 8443/tcp || true

ufw --force enable

# =========================================================
# 完成
# =========================================================

echo
echo "=================================================="
echo "安装完成"
echo "=================================================="

echo
echo "域名:"
echo "$DOMAIN"

echo
echo "UUID:"
echo "$UUID"

echo
echo "Reality Public Key:"
echo "$PUBLIC_KEY"

echo
echo "Reality Short ID:"
echo "$SHORT_ID"

echo
echo "配置文件:"
echo "$CONFIG_FILE"

echo
echo "日志:"
echo "/var/log/sing-box/sing-box.log"

echo
echo "systemctl:"
echo "systemctl status sing-box"

echo
echo "=================================================="
echo "客户端配置"
echo "=================================================="

cat <<EOCLIENT

{
  "server": "$DOMAIN",
  "server_port": 443,

  "uuid": "$UUID",

  "flow": "xtls-rprx-vision",

  "tls": {
    "enabled": true,

    "server_name": "$DOMAIN",

    "reality": {
      "enabled": true,

      "public_key": "$PUBLIC_KEY",

      "short_id": "$SHORT_ID"
    }
  }
}

EOCLIENT

echo
echo "=================================================="

EOF

chmod +x install.sh

echo "install.sh 已生成"

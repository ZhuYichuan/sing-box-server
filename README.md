# sing-box-server
## ufw
```
sudo ufw enable
sudo ufw default allow outgoing
sudo ufw default deny incoming
sudo ufw allow 8443 comment 'nginx HTTPS (TCP+UDP)'
sudo ufw allow 443 comment 'sing-box HTTPS (TCP+UDP)'
sudo ufw allow 22 comment 'SSH port'
sudo ufw delete allow 80
```

## sing-box 服务端搭建
> sing-box.conf 下面配置文件中 // 需要删除后运行
> ./sing-box run -c /root/sing-box.conf -C /root/.sing-box/  
```conf
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
        "server_name": "", // 支持 h2 域名 ,这里我们使用通过 acme 签发证书的域名
        "min_version": "1.3",
        "max_version": "1.3",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "127.0.0.1",
            "server_port": 8443
          },
          "private_key": "", // sing-box generate reality-keypair 生成PrivateKey PublicKey
          "short_id": [
            "" // sing-box generate rand 8 --hex
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
```
---

## acme
导入 cf token 和 id
```
echo 'export CF_Token="xxx"' >> ~/.bashrc
echo 'export CF_Account_ID="xx"' >> ~/.bashrc
source ~/.bashrc
```
安装 acme
```
curl https://get.acme.sh | sh
# 安装完成后，重载 shell 环境
source ~/.bashrc
```

用 DNS API 签发证书
```
acme.sh --issue --dns dns_cf \
-d [your_domain] \
--accountemail [your@email.com]
```

自动更新证书
```
acme.sh --install-cronjob
```


---

## nginx.conf 
> `//`根据自己需求配置
```
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

    # 这里放 server 块
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        return 444;
    }

    server {
        listen 80;
        listen [::]:80;
        server_name //自己域名;
        return 301 https://$host$request_uri;
    }

    server {
        listen 8443 ssl default_server;
        listen [::]:8443 ssl default_server;
        server_name _;
        ssl_certificate      //自己申请的证书;
        ssl_certificate_key  //自己申请的证书;
        ssl_protocols        TLSv1.2 TLSv1.3;
        ssl_ciphers          HIGH:!aNULL:!MD5;
        #ssl_reject_handshake on;
    }

    server {
        listen 8443 ssl http2;
        listen [::]:8443 ssl http2;
        server_name //自己域名;
        ssl_certificate      //自己申请的证书;
        ssl_certificate_key  //自己申请的证书;
        ssl_session_tickets off;
        ssl_protocols TLSv1.3;
        ssl_ecdh_curve X25519:prime256v1:secp384r1;
        ssl_prefer_server_ciphers off;

        add_header Strict-Transport-Security "max-age=63072000" always;

        location / {
            add_header Content-Type 'text/html; charset=utf-8';
            add_header X-Frame-Options "DENY" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header Referrer-Policy "no-referrer-when-downgrade" always;
            return 200 'OK';
        }
    }
}
```

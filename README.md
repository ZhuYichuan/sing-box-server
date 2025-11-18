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
## html
`sudo mkdir -p /var/www/movies`
`sudo vi /var/www/movies/index.html`
```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>电影展示</title>
    <style>
        body {
            margin: 0;
            font-family: "Helvetica Neue", Helvetica, Arial, sans-serif;
            background: linear-gradient(135deg, #1b2735, #090a0f);
            color: #ffffff;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            height: 100vh;
            text-align: center;
        }

        h1 {
            font-size: 4em;
            margin-bottom: 0.2em;
        }

        p {
            font-size: 1.5em;
            margin-top: 0;
            opacity: 0.8;
        }

        .movie-list {
            margin-top: 2em;
            display: flex;
            flex-wrap: wrap;
            justify-content: center;
            gap: 2em;
        }

        .movie {
            background: rgba(255,255,255,0.05);
            padding: 1.5em;
            border-radius: 15px;
            width: 200px;
            box-shadow: 0 0 15px rgba(0,0,0,0.3);
            transition: transform 0.3s, box-shadow 0.3s;
        }

        .movie:hover {
            transform: translateY(-10px);
            box-shadow: 0 10px 25px rgba(0,0,0,0.5);
        }

        .movie-title {
            font-size: 1.2em;
            margin-bottom: 0.5em;
        }

        .movie-year {
            font-size: 0.9em;
            opacity: 0.7;
        }
    </style>
</head>
<body>
    <h1>电影展示</h1>
    <p>精选经典影片</p>
    <div class="movie-list">
        <div class="movie">
            <div class="movie-title">星际穿越</div>
            <div class="movie-year">2014</div>
        </div>
        <div class="movie">
            <div class="movie-title">盗梦空间</div>
            <div class="movie-year">2010</div>
        </div>
        <div class="movie">
            <div class="movie-title">复仇者联盟</div>
            <div class="movie-year">2012</div>
        </div>
        <div class="movie">
            <div class="movie-title">泰坦尼克号</div>
            <div class="movie-year">1997</div>
        </div>
    </div>
</body>
</html>
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

    server {
        listen 80;
        listen [::]:80;
        server_name dmit1.openlts.com;
        return 301 https://$host:8443$request_uri;
    }


    server {
        listen 8443 ssl http2;
        listen [::]:8443 ssl http2;
        server_name dmit1.openlts.com;
	root /var/www/movies;
        index index.html;
	ssl_certificate      /root/.acme.sh/dmit1.openlts.com_ecc/fullchain.cer;
        ssl_certificate_key  /root/.acme.sh/dmit1.openlts.com_ecc/dmit1.openlts.com.key;
        ssl_session_tickets off;
        ssl_protocols TLSv1.3;
        ssl_ecdh_curve X25519:prime256v1:secp384r1;
        ssl_prefer_server_ciphers off;

        add_header Strict-Transport-Security "max-age=63072000" always;

    }
}
```

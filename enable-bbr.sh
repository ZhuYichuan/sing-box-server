cat > enable-bbr.sh <<'EOF'
#!/usr/bin/env bash

set -e

echo "=== 加载 tcp_bbr 模块 ==="
modprobe tcp_bbr || true

echo
echo "=== 可用拥塞控制算法 ==="
sysctl net.ipv4.tcp_available_congestion_control

echo
echo "=== 写入配置 ==="

cat > /etc/sysctl.d/99-bbr.conf <<EOT
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOT

sysctl --system > /dev/null

echo
echo "=== 当前算法 ==="
sysctl net.ipv4.tcp_congestion_control

echo
echo "=== BBR 模块 ==="
lsmod | grep bbr || true

echo
echo "=== 完成 ==="
EOF

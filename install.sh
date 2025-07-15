#!/usr/bin/env bash
set -euo pipefail

echo ">>> [1/8] Cập nhật hệ thống & cài gói cơ bản..."
apt update && apt upgrade -y
apt install -y ca-certificates curl gnupg lsb-release apt-transport-https \
  software-properties-common git make iptables-persistent

echo ">>> [2/8] Cài Docker & Compose plugin..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io \
               docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo ">>> [3/8] Cài đặt Portainer (Docker UI)..."
docker volume create portainer_data >/dev/null
docker compose -p portainer -f - up -d <<'EOF'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9000:9000"
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
volumes:
  portainer_data:
EOF

echo ">>> [4/8] Cài đặt WireGuard..."
apt install -y wireguard wireguard-tools

# Bật IP forwarding
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Tạo cấu hình wg0.conf mẫu nếu chưa có
WG_CFG=/etc/wireguard/wg0.conf
if [ ! -f "$WG_CFG" ]; then
  echo ">>> Tạo file wg0.conf mẫu..."
  mkdir -p /etc/wireguard
  umask 077
  wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
  PRIV_KEY=$(cat /etc/wireguard/privatekey)
  cat > "$WG_CFG" <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = ${PRIV_KEY}
EOF
fi

systemctl enable --now wg-quick@wg0

# Cấu hình NAT
WAN_IF=$(ip route get 1 | awk '{print $5; exit}')
iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$WAN_IF" -j MASQUERADE
netfilter-persistent save

# Fix DNS mẫu
cat > /etc/wireguard/client-dns-fix.txt <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

echo ">>> [5/8] Cài đặt Nginx..."
apt install -y nginx
systemctl enable --now nginx

echo ">>> [6/8] Clone WireGuard-UI và build từ source..."
cd /opt
git clone https://github.com/ngoduykhanh/wireguard-ui.git
cd wireguard-ui

# Ghi đè docker-compose.yml theo hướng dẫn
cat > docker-compose.yml <<'EOF'
services:
  wireguard-ui:
    build: .
    container_name: wireguard-ui
    cap_add:
      - NET_ADMIN
    ports:
      - "5000:5000"
    volumes:
      - ./db:/app/db
      - /etc/wireguard:/etc/wireguard
    environment:
      - WGUI_USERNAME=admin
      - WGUI_PASSWORD=admin
      - WGUI_MANAGE_START=true
      - WGUI_MANAGE_RESTART=true
    restart: unless-stopped
EOF

echo ">>> [7/8] Build và chạy WireGuard-UI (mất 2-3 phút)..."
docker compose build
docker compose up -d

echo ">>> [8/8] Tạo alias tiện ích..."
cat > /etc/profile.d/aliases-wireguard.sh <<'EOF'
# Update services
alias update_docker='apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'
alias update_portainer='docker pull portainer/portainer-ce:latest && docker restart portainer'
alias update_wireguard='apt update && apt install -y wireguard wireguard-tools'
alias update_nginx='apt update && apt install -y nginx'
alias update_wgui='cd /opt/wireguard-ui && git pull && docker compose build && docker compose up -d'

# Quick commands
alias wg_status='wg show'
alias wg_restart='systemctl restart wg-quick@wg0'
alias portainer_logs='docker logs -f portainer'
alias wgui_logs='docker logs -f wireguard-ui'
EOF

chmod +x /etc/profile.d/aliases-wireguard.sh

echo ""
echo "✅ Cài đặt hoàn tất!"
echo "-----------------------------------------"
echo "🌐 WireGuard-UI  : http://<IP>:5000 (admin / admin)"
echo "🌐 Portainer     : http://<IP>:9000  hoặc https://<IP>:9443"
echo "🌐 Nginx         : http://<IP>:80"
echo "🔐 WireGuard     : cấu hình tại /etc/wireguard/wg0.conf"
echo ""
echo "❗ Đổi mật khẩu WireGuard-UI sau lần đầu tiên!"
echo "💡 Mở terminal mới để sử dụng alias (wg_status, update_wgui...)"

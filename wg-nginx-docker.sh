#!/usr/bin/env bash
set -euo pipefail
################################################################################
# INSTALL: Docker + Docker Compose plugin + Portainer
#          WireGuard + WireGuard‑UI
#          Nginx
#          NAT, IP‑forward, aliases
# Tested on Ubuntu 20.04/22.04 & Debian 12
################################################################################

# ---------- 1. System update & prerequisites ----------
echo ">>> Updating system and installing prerequisites…"
apt update && apt upgrade -y
apt install -y ca-certificates curl gnupg lsb-release apt-transport-https \
               software-properties-common iptables-persistent

# ---------- 2. Docker & Compose plugin ----------
echo ">>> Installing Docker Engine & Compose plugin…"
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

# ---------- 2.1 Portainer (container) ----------
echo ">>> Deploying Portainer…"
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

# ---------- 3. Install WireGuard ----------
echo ">>> Installing WireGuard kernel modules & tools…"
apt install -y wireguard wireguard-tools

# Enable IPv4 forwarding
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Generate minimal /etc/wireguard/wg0.conf if absent
WG_CFG=/etc/wireguard/wg0.conf
if [ ! -f "$WG_CFG" ]; then
  echo ">>> Creating a minimal wg0.conf (edit later)…"
  umask 077
  wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
  PRIV_KEY=$(cat /etc/wireguard/privatekey)
  cat > "$WG_CFG" <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = ${PRIV_KEY}
# SaveConfig = true

# Add [Peer] sections below for each client
EOF
fi

systemctl enable --now wg-quick@wg0

# ---------- 3.1 iptables NAT ----------
echo ">>> Setting up iptables masquerading for 10.0.0.0/24 …"
WAN_IF=$(ip route get 1 | awk '{print $5; exit}')
iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$WAN_IF" -j MASQUERADE
netfilter-persistent save

# ---------- 4. WireGuard‑UI (container) ----------
echo ">>> Deploying WireGuard‑UI…"
mkdir -p /opt/wireguard-ui/config
docker compose -p wg-ui -f - up -d <<'EOF'
services:
  wg-ui:
    image: ghcr.io/ngoduykhanh/wireguard-ui:latest
    container_name: wireguard-ui
    restart: unless-stopped
    environment:
      - WG_CONF_DIR=/etc/wireguard
      - WG_INTERFACE_NAME=wg0
      - WG_UI_USERNAME=admin       # Thay đổi sau!
      - WG_UI_PASSWORD=changeme    # Thay đổi sau!
    network_mode: "host"
    volumes:
      - /etc/wireguard:/etc/wireguard
      - /opt/wireguard-ui/config:/app/db
EOF
echo ">>> WireGuard‑UI listening on http://<server-ip>:5000 (default creds: admin / changeme)"

# ---------- 5. Nginx ----------
echo ">>> Installing Nginx…"
apt install -y nginx
systemctl enable --now nginx

# ---------- 6. DNS fix template ----------
cat > /etc/wireguard/client-dns-fix.txt <<'EOF'
# Nếu client/host gặp lỗi DNS, thêm vào /etc/resolv.conf:
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# ---------- 7. Helpful aliases ----------
echo ">>> Creating aliases in /etc/profile.d/aliases-wireguard.sh …"
cat > /etc/profile.d/aliases-wireguard.sh <<'EOF'
# --- Update/upgrade helpers ---
alias update_docker='apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'
alias update_portainer='docker pull portainer/portainer-ce:latest && docker restart portainer'
alias update_wireguard='apt update && apt install -y wireguard wireguard-tools'
alias update_wgui='docker pull ghcr.io/ngoduykhanh/wireguard-ui:latest && docker restart wireguard-ui'
alias update_nginx='apt update && apt install -y nginx'

# --- Quick status commands ---
alias wg_status='wg show'
alias wg_restart='systemctl restart wg-quick@wg0'
alias portainer_logs='docker logs -f portainer'
alias wgui_logs='docker logs -f wireguard-ui'
EOF
chmod +x /etc/profile.d/aliases-wireguard.sh

# ---------- 8. Completion ----------
cat <<'EOM'

✅ Hoàn tất cài đặt!

• Portainer        : https://<SERVER-IP>:9443  (hoặc http://<SERVER-IP>:9000)
• WireGuard‑UI     : http://<SERVER-IP>:5000   (đổi mật khẩu mặc định ngay!)
• Nginx            : Đang chạy trên cổng 80

Các lệnh hữu ích (mở terminal mới để nạp alias):
  wg_status        – Xem trạng thái WireGuard
  update_portainer – Cập nhật Portainer
  update_wgui      – Cập nhật WireGuard‑UI
  update_docker    – Cập nhật Docker & Compose plugin

Hãy chỉnh `/etc/wireguard/wg0.conf` và khởi động lại với:
  sudo wg_restart

Chúc bạn triển khai thành công!
EOM

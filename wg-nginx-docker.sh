#!/usr/bin/env bash
set -euo pipefail

# ---------- 1. Prerequisites ----------
echo ">>> Updating system & installing prerequisites…"
apt update && apt upgrade -y
apt install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common

# ---------- 2. Install Docker & Docker Compose ----------
echo ">>> Installing Docker Engine & Compose plugin…"
DOCKER_GPG=/etc/apt/keyrings/docker.gpg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | \
  gpg --dearmor -o "$DOCKER_GPG"
chmod a+r "$DOCKER_GPG"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=$DOCKER_GPG] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# ---------- 3. Install WireGuard ----------
echo ">>> Installing WireGuard…"
apt install -y wireguard wireguard-tools iptables-persistent

# Enable IPv4 forwarding
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p

# Generate basic /etc/wireguard/wg0.conf if none exists
WG_CFG=/etc/wireguard/wg0.conf
if [ ! -f "$WG_CFG" ]; then
  echo ">>> Creating a minimal wg0.conf (adjust later)…"
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

# Start & enable interface
systemctl enable --now wg-quick@wg0

# ---------- 3.1 NAT & firewall ----------
echo ">>> Setting up iptables masquerading for 10.0.0.0/24 …"
eth_if=$(ip route get 1 | awk '{print $5; exit}')
iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -o "$eth_if" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$eth_if" -j MASQUERADE

# Save rules
netfilter-persistent save

# ---------- 3.2 DNS fix template ----------
RESOLV_FIX=/etc/wireguard/client-dns-fix.txt
cat > "$RESOLV_FIX" <<'EOF'
# Trên CLIENT hoặc HOST nếu gặp sự cố DNS, thêm dòng sau vào /etc/resolv.conf:
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# ---------- 4. Install Nginx ----------
echo ">>> Installing Nginx…"
apt install -y nginx
systemctl enable --now nginx

# ---------- 5. Aliases for quick updates ----------
echo ">>> Adding handy aliases to /etc/profile.d/aliases-wireguard.sh …"
cat > /etc/profile.d/aliases-wireguard.sh <<'EOF'
alias update_docker='apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'
alias update_wireguard='apt update && apt install -y wireguard wireguard-tools'
alias update_nginx='apt update && apt install -y nginx'
EOF
chmod +x /etc/profile.d/aliases-wireguard.sh

echo -e "\n✅ Hoàn tất! Hãy kiểm tra /etc/wireguard/wg0.conf và thêm peer cho client."
echo "✦ Kiểm tra trạng thái:  wg show"
echo "✦ Xem log dịch vụ:     journalctl -u wg-quick@wg0 -f"
echo "✦ Sau khi chỉnh sửa cấu hình, khởi động lại:  systemctl restart wg-quick@wg0"

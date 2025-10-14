#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🔧 Chuẩn bị hệ thống...${NC}"
sudo apt update && sudo apt install -y curl ca-certificates jq dnsutils ufw

echo -e "${GREEN}🌍 Nhập domain dành cho NetBird (ví dụ: vpn.example.com):${NC}"
read -rp "👉 Domain: " NB_DOMAIN
if [[ -z "${NB_DOMAIN}" ]]; then
  echo -e "${RED}❌ Domain không được để trống.${NC}"; exit 1
fi

echo -e "${GREEN}🔎 Kiểm tra DNS của domain...${NC}"
PUBLIC_IP=$(curl -s https://api.ipify.org || true)
DOMAIN_IP=$(dig +short A "$NB_DOMAIN" | tail -n1)

if [[ -z "$PUBLIC_IP" ]]; then
  echo -e "${RED}❌ Không lấy được IP public của máy. Kiểm tra kết nối mạng.${NC}"
  exit 1
fi

if [[ -z "$DOMAIN_IP" ]]; then
  echo -e "${RED}❌ Domain chưa có bản ghi A (IPv4). Hãy trỏ ${NB_DOMAIN} về IP ${PUBLIC_IP}.${NC}"
  read -rp "⏸ Bạn vẫn muốn tiếp tục? (y/N): " confirm
  [[ "${confirm:-N}" =~ ^[Yy]$ ]] || exit 1
else
  echo -e "${GREEN}ℹ️ Server IP: ${PUBLIC_IP}${NC}"
  echo -e "${GREEN}ℹ️ Domain IP: ${DOMAIN_IP}${NC}"
  if [[ "$PUBLIC_IP" != "$DOMAIN_IP" ]]; then
    echo -e "${YELLOW}⚠️ Domain ${NB_DOMAIN} CHƯA trỏ đúng IP server.${NC}"
    read -rp "⏸ Vẫn tiếp tục cài? (y/N): " confirm
    [[ "${confirm:-N}" =~ ^[Yy]$ ]] || exit 1
  else
    echo -e "${GREEN}✅ Domain đã trỏ đúng IP.${NC}"
  fi
fi

echo -e "${GREEN}🧱 Cấu hình UFW mở các cổng bắt buộc (HTTP/HTTPS & TURN)...${NC}"
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 3478/udp
sudo ufw allow 49152:65535/udp
sudo ufw --force enable || true
echo -e "${GREEN}✅ UFW đã bật và mở cổng cần thiết.${NC}"

echo -e "${GREEN}🐳 Kiểm tra/cài Docker & Compose...${NC}"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sudo bash
  sudo usermod -aG docker "$USER" || true
  echo -e "${YELLOW}ℹ️ Docker vừa được cài. Bạn có thể cần đăng xuất/đăng nhập lại để dùng docker không cần sudo.${NC}"
fi
if ! docker compose version &>/dev/null; then
  mkdir -p ~/.docker/cli-plugins
  curl -sSL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 \
    -o ~/.docker/cli-plugins/docker-compose
  chmod +x ~/.docker/cli-plugins/docker-compose
fi
echo -e "${GREEN}✅ Docker & Compose sẵn sàng.${NC}"

echo -e "${GREEN}🚀 Chạy quickstart self-host NetBird (Zitadel IdP)...${NC}"
export NETBIRD_DOMAIN="${NB_DOMAIN}"
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started-with-zitadel.sh | bash

echo -e "${GREEN}🔎 Kiểm tra container NetBird...${NC}"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# === Alias cập nhật NetBird ===
echo -e "${GREEN}⚙️ Thêm alias cập nhật NetBird...${NC}"
cat <<'EOF' >> ~/.bashrc

# Alias cập nhật NetBird (self-host)
alias update-netbird='bash -c "
echo \"📥 Kéo bản cập nhật NetBird mới nhất...\"
curl -fsSL https://get.netbird.io | bash
echo \"🔄 Khởi động lại toàn bộ container NetBird...\"
cd ~/netbird || cd /opt/netbird || true
docker compose pull
docker compose down
docker compose up -d
echo \"✅ NetBird self-host đã được cập nhật thành công!\"
"'

alias netbird-update='update-netbird'
EOF

[ "$EUID" -eq 0 ] && source ~/.bashrc || true

echo -e "${GREEN}🎉 Hoàn tất cài đặt self-host NetBird.${NC}"
echo -e "${GREEN}🔗 Truy cập Dashboard tại: https://${NB_DOMAIN}${NC}"
echo -e "${GREEN}💡 Để cập nhật sau này: gõ 'update-netbird' hoặc 'netbird-update'${NC}"
echo -e "${GREEN}📌 Yêu cầu: mở TCP 80/443, UDP 3478 & 49152–65535 ngoài Internet.${NC}"

#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🔄 Cập nhật hệ thống...${NC}"
sudo apt update && sudo apt upgrade -y

echo -e "${GREEN}🐳 Kiểm tra Docker...${NC}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sudo bash
    sudo usermod -aG docker $USER
    echo -e "${YELLOW}⚠️ Hãy logout/login lại sau khi script hoàn tất để dùng Docker không cần sudo.${NC}"
else
    echo -e "${GREEN}✅ Docker đã được cài.${NC}"
fi

echo -e "${GREEN}🔧 Kiểm tra Docker Compose...${NC}"
if ! docker compose version &> /dev/null; then
    mkdir -p ~/.docker/cli-plugins/
    curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 \
        -o ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose
else
    echo -e "${GREEN}✅ Docker Compose đã có.${NC}"
fi

echo -e "${GREEN}🛡️ Cài đặt firewall và công cụ cần thiết...${NC}"
sudo apt install -y ufw curl dnsutils

echo -e "${GREEN}✅ Bật IP Forward...${NC}"
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wg.conf > /dev/null
sudo sysctl --system

echo -e "${GREEN}📁 Tạo thư mục WireGuard...${NC}"
sudo mkdir -p /etc/wireguard

echo -e "${GREEN}🌍 Nhập domain VPN (ví dụ: vpn.example.com)${NC}"
read -rp "👉 Domain: " WG_DOMAIN

echo -e "${GREEN}🔑 Nhập password cho wg-easy${NC}"
read -rsp "👉 Password: " WG_PASSWORD
echo ""

echo -e "${GREEN}🔍 Kiểm tra domain DNS...${NC}"

PUBLIC_IP=$(curl -s https://api.ipify.org)
DOMAIN_IP=$(dig +short "$WG_DOMAIN" | tail -n1)

if [[ "$PUBLIC_IP" != "$DOMAIN_IP" ]]; then
    echo -e "${RED}⚠️ Domain chưa trỏ đúng IP VPS.${NC}"
    echo -e "${RED}Domain IP: $DOMAIN_IP${NC}"
    echo -e "${RED}Server IP: $PUBLIC_IP${NC}"

    read -rp "❓ Vẫn tiếp tục? (y/N): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        exit 1
    fi
else
    echo -e "${GREEN}✅ Domain OK.${NC}"
fi

echo -e "${GREEN}📦 Tạo docker-compose.yml...${NC}"

mkdir -p ~/wg-easy
cd ~/wg-easy

cat > docker-compose.yml <<EOF
version: "3.8"

services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - proxy

  wg-easy:
    image: ghcr.io/wg-easy/wg-easy
    container_name: wg-easy

    environment:
      - WG_HOST=$WG_DOMAIN
      - PASSWORD=$WG_PASSWORD

      # VPN subnet
      - WG_DEFAULT_ADDRESS=10.0.0.x

      # Split tunnel (chỉ LAN nội bộ)
      - WG_ALLOWED_IPS=10.0.0.0/24

      # DNS cho client
      - WG_DEFAULT_DNS=1.1.1.1

      # Giữ kết nối ổn định
      - WG_PERSISTENT_KEEPALIVE=25

      # Giảm lỗi MTU
      - WG_MTU=1380

    volumes:
      - /etc/wireguard:/etc/wireguard

    ports:
      - "51820:51820/udp"
      - "127.0.0.1:51821:51821/tcp"

    cap_add:
      - NET_ADMIN
      - SYS_MODULE

    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1

    networks:
      - proxy

    restart: unless-stopped

networks:
  proxy:
    external: true
EOF

echo -e "${GREEN}🚀 Khởi động dịch vụ...${NC}"

# Tạo network proxy nếu chưa tồn tại
docker network create proxy 2>/dev/null || true

docker compose up -d

echo -e "${GREEN}⏳ Chờ các dịch vụ khởi động...${NC}"
sleep 5

echo -e "${GREEN}🔥 Cấu hình UFW...${NC}"

sudo ufw allow OpenSSH
sudo ufw allow 51820/udp
sudo ufw allow 80/tcp
sudo ufw allow 81/tcp
sudo ufw allow 443/tcp

sudo ufw --force enable

echo -e "${GREEN}⚡ Reload firewall...${NC}"
sudo ufw reload

echo -e "${GREEN}🧪 Kiểm tra dịch vụ...${NC}"

sleep 3

docker ps | grep wg-easy || {
    echo -e "${RED}❌ wg-easy không chạy.${NC}"
    exit 1
}

docker ps | grep nginx-proxy-manager || {
    echo -e "${RED}❌ Nginx Proxy Manager không chạy.${NC}"
    exit 1
}

echo -e "${GREEN}✅ Tất cả dịch vụ đang hoạt động.${NC}"

echo ""
echo -e "${GREEN}🎉 CÀI ĐẶT HOÀN TẤT${NC}"
echo ""
echo -e "${GREEN}🌐 WireGuard Web UI:${NC} https://$WG_DOMAIN"
echo -e "${GREEN}🔐 User:${NC} admin"
echo -e "${GREEN}🔑 Password:${NC} password bạn vừa nhập"
echo ""
echo -e "${GREEN}🌐 Nginx Proxy Manager:${NC} http://$(hostname -I | awk '{print $1}'):81"
echo -e "${GREEN}📊 Email mặc định:${NC} admin@example.com"
echo -e "${GREEN}🔑 Password mặc định:${NC} changeme"
echo ""
echo -e "${YELLOW}📌 Cách cấu hình NPM cho WireGuard:${NC}"
echo "1. Đăng nhập NPM tại port 81"
echo "2. Proxy Hosts → Add Proxy Host"
echo "3. Domain: $WG_DOMAIN"
echo "4. Scheme: http, IP: wg-easy, Port: 51821"
echo "5. SSL: Request a new SSL Certificate"
echo ""
echo -e "${YELLOW}📌 Lưu ý:${NC}"
echo "- VPN này chỉ tạo LAN nội bộ giữa các thiết bị"
echo "- Internet của thiết bị vẫn dùng mạng riêng"
echo "- Các peer sẽ ping nhau qua IP 10.0.0.x"
echo ""
echo -e "${GREEN}📊 Kiểm tra peer:${NC}"
echo "sudo wg show"
echo ""
echo -e "${GREEN}📄 Xem log:${NC}"
echo "docker logs -f wg-easy"
echo "docker logs -f nginx-proxy-manager"

echo ""
echo -e "${GREEN}⚙️ Thêm alias command...${NC}"

# Tạo bash_aliases nếu chưa tồn tại
touch ~/.bash_aliases

# Thêm alias wireguard-update
if ! grep -q "wireguard-update" ~/.bash_aliases; then
    cat >> ~/.bash_aliases <<'ALIAS_EOF'

# WireGuard update command
wireguard-update() {
  echo -e "\033[0;32m🔄 Cập nhật WireGuard...\033[0m"
  cd ~/wg-easy
  docker compose pull
  docker compose up -d
  echo -e "\033[0;32m✅ WireGuard cập nhật thành công\033[0m"
  echo -e "\033[0;32m📊 Trạng thái container:\033[0m"
  docker ps | grep -E "wg-easy|nginx-proxy-manager"
}

ALIAS_EOF
    source ~/.bash_aliases
    echo -e "${GREEN}✅ Alias 'wireguard-update' đã thêm.${NC}"
else
    echo -e "${GREEN}✅ Alias 'wireguard-update' đã tồn tại.${NC}"
fi

echo ""
echo -e "${GREEN}💡 Sử dụng lệnh:${NC}"
echo "wireguard-update    # Cập nhật WireGuard lên phiên bản mới nhất"

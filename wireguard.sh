```bash
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
sudo apt install -y ufw curl nginx certbot python3-certbot-nginx

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
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy
    container_name: wg-easy

    environment:
      - WG_HOST=$WG_DOMAIN
      - PASSWORD=$WG_PASSWORD

      # VPN subnet
      - WG_DEFAULT_ADDRESS=10.8.0.x

      # Split tunnel (chỉ LAN nội bộ)
      - WG_ALLOWED_IPS=10.8.0.0/24

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

    restart: unless-stopped
EOF

echo -e "${GREEN}🚀 Khởi động wg-easy...${NC}"
docker compose up -d

echo -e "${GREEN}🌐 Tạo cấu hình Nginx...${NC}"

NGINX_CONF="/etc/nginx/sites-available/wg-easy"

sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $WG_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:51821;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/wg-easy

sudo nginx -t
sudo systemctl restart nginx

echo -e "${GREEN}🔐 Tạo SSL Let's Encrypt...${NC}"

sudo certbot --nginx -d "$WG_DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m admin@$WG_DOMAIN || true

echo -e "${GREEN}🔥 Cấu hình UFW...${NC}"

sudo ufw allow OpenSSH
sudo ufw allow 51820/udp
sudo ufw allow 'Nginx Full'

sudo ufw --force enable

echo -e "${GREEN}⚡ Reload firewall...${NC}"
sudo ufw reload

echo -e "${GREEN}🧪 Kiểm tra WireGuard...${NC}"

sleep 3

docker ps | grep wg-easy || {
    echo -e "${RED}❌ wg-easy không chạy.${NC}"
    exit 1
}

echo -e "${GREEN}✅ wg-easy đang hoạt động.${NC}"

echo ""
echo -e "${GREEN}🎉 CÀI ĐẶT HOÀN TẤT${NC}"
echo ""
echo -e "${GREEN}🌐 Web UI:${NC} https://$WG_DOMAIN"
echo -e "${GREEN}🔐 User:${NC} admin"
echo -e "${GREEN}🔑 Password:${NC} password bạn vừa nhập"
echo ""
echo -e "${YELLOW}📌 Lưu ý:${NC}"
echo "- VPN này chỉ tạo LAN nội bộ giữa các thiết bị"
echo "- Internet của thiết bị vẫn dùng mạng riêng"
echo "- Các peer sẽ ping nhau qua IP 10.8.0.x"
echo ""
echo -e "${GREEN}📊 Kiểm tra peer:${NC}"
echo "sudo wg show"
echo ""
echo -e "${GREEN}📄 Xem log:${NC}"
echo "docker logs -f wg-easy"
```

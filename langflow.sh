#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🔧 Nhập domain để cấu hình cho Langflow:${NC}"
read -rp "Domain: " DOMAIN

# Lấy IP Public của VPS
SERVER_IP=$(curl -s https://api.ipify.org)

echo -e "${GREEN}🌐 Kiểm tra domain có trỏ đúng IP ($SERVER_IP) không...${NC}"
DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)

if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
  echo -e "${RED}❌ Domain chưa trỏ đúng IP. IP domain: $DOMAIN_IP${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Domain đã trỏ đúng IP!${NC}"
fi

echo -e "${GREEN}📦 Cài Docker, Docker Compose nếu chưa có...${NC}"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | bash
fi

if ! command -v docker-compose &>/dev/null; then
  sudo apt install docker-compose -y
fi

echo -e "${GREEN}📁 Tạo thư mục & file cấu hình Langflow...${NC}"
mkdir -p ~/langflow
cd ~/langflow

cat <<EOF > docker-compose.yml
version: "3.8"

services:
  langflow:
    image: langflowai/langflow:latest
    container_name: langflow
    ports:
      - "7860:7860"
    environment:
      - LANGFLOW_ENV=production
    command: langflow run --host 0.0.0.0
    restart: unless-stopped
EOF

docker compose up -d

echo -e "${GREEN}🧩 Cài đặt Nginx + Certbot...${NC}"
apt update
apt install nginx certbot python3-certbot-nginx -y

echo -e "${GREEN}🌐 Cấu hình Nginx cho $DOMAIN...${NC}"
cat <<EOF > /etc/nginx/sites-available/langflow
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:7860;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/langflow /etc/nginx/sites-enabled/langflow
nginx -t && systemctl reload nginx

echo -e "${GREEN}🔐 Cấp SSL với Certbot...${NC}"
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN"

echo -e "${GREEN}✅ Langflow đã được triển khai tại: https://$DOMAIN${NC}"

echo -e "${GREEN}🔁 Thêm alias update-langflow...${NC}"
echo "alias update-langflow='cd ~/langflow && docker compose pull && docker compose up -d'" >> ~/.bashrc

echo -e "${GREEN}🔁 Thêm alias langflow-update (cập nhật Langflow an toàn)...${NC}"
echo "alias langflow-update='cd ~/langflow && docker compose pull && docker compose up -d'" >> ~/.bashrc
source ~/.bashrc



echo -e "${GREEN}🚀 Hoàn tất! Dùng lệnh sau để cập nhật Langflow khi cần:${NC}"
echo -e "   ${GREEN}update-langflow${NC}"

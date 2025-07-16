#!/bin/bash

# ====================== KIỂM TRA QUYỀN ROOT =========================
if [[ $EUID -ne 0 ]]; then
   echo "❌ Vui lòng chạy script bằng quyền root: sudo ./install-n8n.sh"
   exit 1
fi

# ====================== NHẬP DOMAIN =========================
read -p "🌐 Nhập domain/subdomain cho n8n (ví dụ: n8n.example.com): " N8N_DOMAIN

# ====================== KIỂM TRA DOMAIN ĐÃ TRỎ IP CHƯA =========================
check_domain() {
    local domain=$1
    local server_ip=$(curl -s https://api.ipify.org)
    local domain_ip=$(dig +short "$domain")

    if [[ "$domain_ip" == "$server_ip" ]]; then
        return 0
    else
        return 1
    fi
}

if check_domain "$N8N_DOMAIN"; then
    echo "✅ Domain đã trỏ đúng IP. Tiếp tục cài đặt..."
else
    echo "❌ Domain chưa trỏ đúng IP!"
    echo "Vui lòng cập nhật DNS trỏ về: $(curl -s https://api.ipify.org)"
    exit 1
fi

# ====================== BIẾN THƯ MỤC =========================
N8N_DIR="/home/n8n"

# ====================== CÀI ĐẶT GÓI CẦN THIẾT =========================
apt update
apt install -y curl ca-certificates gnupg software-properties-common \
               docker.io docker-compose nginx ufw certbot python3-certbot-nginx

# ====================== CẤU HÌNH TƯỜNG LỬA =========================
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw allow 5678
ufw --force enable

# ====================== CẤU HÌNH n8n (DOCKER-COMPOSE) =========================
mkdir -p "$N8N_DIR"
cat << EOF > "$N8N_DIR/docker-compose.yml"
version: "3.8"
services:
  n8n:
    image: n8nio/n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${N8N_DOMAIN}
      - NODE_ENV=production
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
    volumes:
      - $N8N_DIR:/home/node/.n8n
EOF

# ====================== CẤU HÌNH NGINX =========================
cat << EOF > /etc/nginx/sites-available/n8n
server {
    listen 80;
    server_name ${N8N_DOMAIN};

    location / {
        proxy_pass http://localhost:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/

nginx -t && systemctl restart nginx

# ====================== SSL CERTBOT =========================
certbot --nginx --non-interactive --agree-tos -m admin@$N8N_DOMAIN -d $N8N_DOMAIN

# ====================== QUYỀN THƯ MỤC =========================
chown -R 1000:1000 "$N8N_DIR"
chmod -R 755 "$N8N_DIR"

# ====================== CHẠY n8n =========================
cd "$N8N_DIR"
docker-compose up -d

# ====================== TẠO ALIAS =========================
echo "alias n8n-update='cd $N8N_DIR && docker-compose down && docker-compose pull && docker-compose up -d'" >> ~/.bashrc
source ~/.bashrc

# ====================== THÔNG BÁO HOÀN TẤT =========================
echo ""
echo "✅ CÀI ĐẶT HOÀN TẤT!"
echo "🌐 Truy cập n8n tại: https://${N8N_DOMAIN}"
echo "💡 Sử dụng 'n8n-update' để cập nhật n8n nhanh chóng."

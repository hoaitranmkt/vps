#!/bin/bash

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Script cần được chạy với quyền root."
   exit 1
fi

# Hàm kiểm tra domain đã trỏ đúng chưa
check_domain() {
    local domain=$1
    local server_ip=$(curl -s https://api.ipify.org)
    local domain_ip=$(dig +short $domain)

    if [ "$domain_ip" = "$server_ip" ]; then
        return 0
    else
        return 1
    fi
}

# Nhập domain
read -p "📨 Nhập domain/subdomain bạn muốn dùng cho n8n: " DOMAIN

if ! check_domain $DOMAIN; then
    echo "❌ Domain $DOMAIN chưa trỏ đúng về IP $(curl -s https://api.ipify.org)"
    echo "⚠️ Vui lòng cập nhật bản ghi DNS, sau đó chạy lại script"
    exit 1
fi

echo "✅ Domain $DOMAIN đã trỏ đúng, bắt đầu cài đặt..."

# Thư mục chứa docker-compose
N8N_DIR="/home/n8n"
mkdir -p $N8N_DIR

# Cài Docker nếu chưa có
if ! command -v docker &> /dev/null; then
    echo "🐳 Cài đặt Docker & Docker Compose..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose
fi

# Tạo file docker-compose.yml cho n8n
cat << EOF > $N8N_DIR/docker-compose.yml
version: "3"
services:
  n8n:
    image: n8nio/n8n
    restart: always
    environment:
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${DOMAIN}
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - $N8N_DIR:/home/node/.n8n
EOF

# Khởi động n8n container
cd $N8N_DIR
docker-compose up -d

# Cấu hình nginx reverse proxy
NGINX_CONF="/etc/nginx/sites-available/n8n"
cat << EOF > $NGINX_CONF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -s $NGINX_CONF /etc/nginx/sites-enabled/n8n
nginx -t && systemctl reload nginx

# Cài đặt SSL với Certbot
echo "🔐 Cài SSL với Let's Encrypt..."
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

# Cấu hình tự gia hạn SSL
echo "0 3 * * * /usr/bin/certbot renew --quiet" | crontab -

# Thêm alias update
TARGET_USER=${SUDO_USER:-root}
BASHRC_PATH=$(eval echo "~$TARGET_USER/.bashrc")

if ! grep -q "alias update-n8n=" "$BASHRC_PATH"; then
  echo "alias update-n8n='cd $N8N_DIR && docker-compose down && docker-compose pull && docker-compose up -d'" >> "$BASHRC_PATH"
fi

echo ""
echo "✅ n8n đã được cài đặt!"
echo "🌐 Truy cập: https://$DOMAIN"
echo "📁 Dữ liệu lưu tại: $N8N_DIR"
echo "🔁 Dùng 'update-n8n' để cập nhật nhanh."

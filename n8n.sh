#!/bin/bash
set -e

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

# ====================== HÀM KIỂM TRA & CÀI GÓI =========================
install_if_missing() {
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      echo "📦 Đang cài đặt: $pkg"
      apt install -y "$pkg"
    else
      echo "✅ Gói đã có: $pkg"
    fi
  done
}

# ====================== CẬP NHẬT & CÀI GÓI CƠ BẢN =========================
apt update
install_if_missing curl ca-certificates gnupg software-properties-common \
                   docker-compose-plugin nginx ufw certbot \
                   python3-certbot-nginx dnsutils

# ====================== CÀI ĐẶT DOCKER CHÍNH THỨC (Docker CE) =========================
if ! command -v docker &> /dev/null; then
  echo "🐳 Cài Docker từ Docker CE chính thức..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt update
  install_if_missing docker-ce docker-ce-cli containerd.io
fi

# ====================== BẬT & KHỞI ĐỘNG Docker =========================
systemctl enable docker
systemctl start docker

# ====================== CẤU HÌNH TƯỜNG LỬA =========================
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw allow 5678
ufw --force enable

# ====================== TẠO docker-compose.yml =========================
mkdir -p "$N8N_DIR"
cat << EOF > "$N8N_DIR/docker-compose.yml"
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

ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# ====================== SSL CERTBOT =========================
certbot --nginx --non-interactive --agree-tos -m admin@$N8N_DOMAIN -d $N8N_DOMAIN

# ====================== PHÂN QUYỀN =========================
chown -R 1000:1000 "$N8N_DIR"
chmod -R 755 "$N8N_DIR"

# ====================== KHỞI ĐỘNG n8n =========================
cd "$N8N_DIR"
docker compose up -d

# ====================== ALIAS CẬP NHẬT n8n =========================
for alias_name in n8n-update update-n8n; do
  if ! grep -q "alias $alias_name=" ~/.bashrc; then
    echo "alias $alias_name='cd $N8N_DIR && docker compose down && docker compose pull && docker compose up -d'" >> ~/.bashrc
    echo "✅ Alias '$alias_name' đã được thêm vào ~/.bashrc"
  else
    echo "ℹ️ Alias '$alias_name' đã tồn tại, bỏ qua."
  fi
done

source ~/.bashrc || true

# ====================== THÔNG BÁO =========================
echo ""
echo "✅ CÀI ĐẶT HOÀN TẤT!"
echo "🌐 Truy cập n8n tại: https://${N8N_DOMAIN}"
echo "💡 Sử dụng 'n8n-update' để cập nhật n8n nhanh chóng."

#!/bin/bash
set -e

echo "🔧 Cập nhật hệ thống..."
apt update && apt upgrade -y

echo "🌐 Cài đặt Nginx và công cụ hỗ trợ..."
apt install -y nginx curl wget unzip ufw certbot python3-certbot-nginx dnsutils

echo "✅ Khởi động và bật Nginx..."
systemctl enable nginx
systemctl start nginx

echo "📦 Cài đặt Nginx UI (phiên bản stable)..."
bash -c "$(curl -L https://cloud.nginxui.com/install.sh)"

# ✅ Cấu hình cổng mặc định
HTTP_PORT=9000
CHALLENGE_PORT=9180

CONFIG_FILE="/usr/local/etc/nginx-ui/app.ini"
mkdir -p $(dirname "$CONFIG_FILE")
touch "$CONFIG_FILE"

echo "🔧 Gán cổng mặc định cho Nginx UI..."
sed -i "s/^HTTPPort = .*/HTTPPort = $HTTP_PORT/" "$CONFIG_FILE" 2>/dev/null || echo "HTTPPort = $HTTP_PORT" >> "$CONFIG_FILE"
sed -i "s/^ChallengeHTTPPort = .*/ChallengeHTTPPort = $CHALLENGE_PORT/" "$CONFIG_FILE" 2>/dev/null || echo "ChallengeHTTPPort = $CHALLENGE_PORT" >> "$CONFIG_FILE"

echo "🔄 Khởi động lại dịch vụ nginx-ui..."
systemctl restart nginx-ui

# ========================== NHẬP DOMAIN ==========================
read -p "🌐 Nhập domain/subdomain cho Nginx UI (ví dụ: nginx.example.com): " NGINX_UI_DOMAIN

# ========================== KIỂM TRA DOMAIN ==========================
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

if check_domain "$NGINX_UI_DOMAIN"; then
    echo "✅ Domain đã trỏ đúng IP."
else
    echo "❌ Domain chưa trỏ đúng IP!"
    echo "👉 Vui lòng cập nhật DNS trỏ về: $(curl -s https://api.ipify.org)"
    exit 1
fi

# ========================== CẤU HÌNH NGINX ==========================
NGINX_CONF="/etc/nginx/sites-available/nginx-ui"

cat << EOF > "$NGINX_CONF"
server {
    listen 80;
    server_name $NGINX_UI_DOMAIN;

    location / {
        proxy_pass http://localhost:$HTTP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# ========================== SSL CERTBOT ==========================
certbot --nginx --non-interactive --agree-tos -m admin@$NGINX_UI_DOMAIN -d $NGINX_UI_DOMAIN

# ========================== TƯỜNG LỬA ==========================
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw allow $HTTP_PORT
ufw allow $CHALLENGE_PORT

ufw --force enable

# ========================== ALIAS ==========================
TARGET_USER=${SUDO_USER:-root}
BASHRC_PATH=$(eval echo "~$TARGET_USER/.bashrc")

function add_alias() {
  local alias_cmd="$1"
  local alias_name=$(echo "$alias_cmd" | awk '{print $2}' | cut -d= -f1)
  if ! grep -q "^alias $alias_name=" "$BASHRC_PATH"; then
    echo "$alias_cmd" >> "$BASHRC_PATH"
    echo "✅ Alias '$alias_name' đã thêm vào $BASHRC_PATH"
  else
    echo "ℹ️ Alias '$alias_name' đã tồn tại trong $BASHRC_PATH"
  fi
}

add_alias "alias restart-nginx-ui='sudo systemctl restart nginx-ui'"
add_alias "alias update-nginx-ui='bash -c \"\$(curl -L https://cloud.nginxui.com/install.sh)\" && sudo systemctl restart nginx-ui'"

[ "$EUID" -eq 0 ] && source /root/.bashrc || true

# ========================== THÔNG BÁO ==========================
echo ""
echo "✅ Cài đặt hoàn tất!"
echo "🔐 Truy cập Nginx UI tại: https://$NGINX_UI_DOMAIN"
echo "📌 Tài khoản mặc định: admin / admin"
echo "👉 Đã cấu hình HTTPS và Reverse Proxy."

#!/bin/bash
set -e

echo "✅ Bắt đầu cài đặt Docker, Docker Compose và Portainer..."

# ---------- 1. CÀI ĐẶT DOCKER ----------
if ! command -v docker &> /dev/null; then
  echo "📦 Docker chưa cài, tiến hành cài đặt..."
  apt update && apt upgrade -y
  apt install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io \
                 docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  echo "✅ Docker đã được cài đặt."
else
  echo "⚠️ Docker đã được cài đặt. Bỏ qua."
fi

# ---------- 2. THÊM USER VÀO NHÓM DOCKER ----------
if [[ $EUID -ne 0 ]]; then
  usermod -aG docker "$USER"
fi

# ---------- 3. CÀI PORTAINER ----------
if docker ps -a --format '{{.Names}}' | grep -qw portainer; then
  echo "⚠️ Container Portainer đã tồn tại. Bỏ qua cài đặt."
else
  echo "📦 Đang cài đặt Portainer..."
  docker volume create portainer_data >/dev/null
  docker run -d --name portainer --restart=always \
    -p 8000:8000 -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
  echo "✅ Portainer đã được cài đặt."
fi

# ---------- 4. THÊM ALIAS ----------
add_aliases() {
  local TARGET_BASHRC="$1"
  grep -qxF 'alias docker-update=' "$TARGET_BASHRC" || cat >> "$TARGET_BASHRC" <<'EOF'
alias docker-update="sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
alias update-docker="sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
alias portainer-update="docker pull portainer/portainer-ce:latest && docker stop portainer && docker rm portainer && docker run -d --name portainer --restart=always -p 8000:8000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"
alias update-portainer="docker pull portainer/portainer-ce:latest && docker stop portainer && docker rm portainer && docker run -d --name portainer --restart=always -p 8000:8000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"
EOF
}

# Thêm alias cho user hiện tại
USER_BASHRC="$HOME/.bashrc"
[ -f "$USER_BASHRC" ] && add_aliases "$USER_BASHRC"

# Thêm alias cho root
add_aliases /root/.bashrc

# Nạp alias cho root nếu đang là root
[ "$EUID" -eq 0 ] && source /root/.bashrc || true

# ---------- 5. CẤU HÌNH DOMAIN + HTTPS ----------
apt install -y nginx certbot python3-certbot-nginx dnsutils

read -p "🌐 Nhập domain/subdomain bạn muốn dùng cho Portainer (ví dụ: portainer.example.com): " PORTAINER_DOMAIN

# ---------- KIỂM TRA DOMAIN CÓ TRỎ VỀ VPS ----------
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

if check_domain "$PORTAINER_DOMAIN"; then
  echo "✅ Domain đã trỏ đúng IP VPS."
else
  echo "❌ Domain chưa trỏ đúng IP!"
  echo "👉 Hãy trỏ domain về IP: $(curl -s https://api.ipify.org)"
  exit 1
fi

# ---------- TẠO FILE NGINX CONFIG ----------
NGINX_CONF="/etc/nginx/sites-available/portainer"
cat <<EOF > "$NGINX_CONF"
server {
    listen 80;
    server_name $PORTAINER_DOMAIN;

    location / {
        proxy_pass https://localhost:9443;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# ---------- CẤP SSL ----------
certbot --nginx --non-interactive --agree-tos -m admin@$PORTAINER_DOMAIN -d $PORTAINER_DOMAIN

# ---------- MỞ TƯỜNG LỬA ----------
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw allow 9443
ufw allow 8000
ufw --force enable

# ---------- HOÀN TẤT ----------
echo ""
echo "✅ Hoàn tất cài đặt Portainer!"
echo "🔐 Truy cập tại: https://$PORTAINER_DOMAIN"
echo "🌐 Nếu gặp lỗi SSL, vui lòng kiểm tra lại cấu hình domain và DNS."

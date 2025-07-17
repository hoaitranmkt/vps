#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🔍 Cập nhật hệ thống...${NC}"
sudo apt update && sudo apt upgrade -y

echo -e "${GREEN}🐳 Kiểm tra & cài đặt Docker...${NC}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sudo bash
    sudo usermod -aG docker $USER
    echo -e "${GREEN}⚠️ Bạn cần đăng xuất và đăng nhập lại để áp dụng quyền Docker.${NC}"
else
    echo -e "${GREEN}✅ Docker đã được cài.${NC}"
fi

echo -e "${GREEN}🔧 Cài đặt Docker Compose plugin nếu cần...${NC}"
if ! docker compose version &> /dev/null; then
    mkdir -p ~/.docker/cli-plugins/
    curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose
else
    echo -e "${GREEN}✅ Docker Compose đã được cài.${NC}"
fi

echo -e "${GREEN}🛡️ Cài đặt iptables & ufw...${NC}"
sudo apt install -y iptables ufw

echo -e "${GREEN}✅ Bật IP Forward cho WireGuard...${NC}"
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-wg-easy-forward.conf
sudo sysctl -p /etc/sysctl.d/99-wg-easy-forward.conf

echo -e "${GREEN}🌐 Cấu hình DNS cố định (vô hiệu hóa systemd-resolved)...${NC}"
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
sudo rm -f /etc/resolv.conf
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null

echo -e "${GREEN}📁 Chuẩn bị thư mục WireGuard config...${NC}"
sudo mkdir -p /etc/wireguard

echo -e "${GREEN}🌍 Nhập domain bạn muốn sử dụng cho wg-easy (ví dụ: vpn.example.com):${NC}"
read -rp "👉 Domain: " WG_DOMAIN

echo -e "${GREEN}🔍 Kiểm tra domain đã trỏ đúng IP chưa...${NC}"
PUBLIC_IP=$(curl -s https://api.ipify.org)
DOMAIN_IP=$(dig +short "$WG_DOMAIN" | tail -n1)

if [[ "$PUBLIC_IP" != "$DOMAIN_IP" ]]; then
    echo -e "${RED}⚠️ Domain chưa trỏ đúng IP!${NC}"
    echo -e "${RED}👉 Domain IP: $DOMAIN_IP | Server IP: $PUBLIC_IP${NC}"
    read -rp "❓ Bạn vẫn muốn tiếp tục? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 1
else
    echo -e "${GREEN}✅ Domain đã trỏ đúng IP.${NC}"
fi

echo -e "${GREEN}🧱 Tạo docker-compose cho wg-easy...${NC}"
mkdir -p ~/wg-easy && cd ~/wg-easy

cat <<EOF | tee docker-compose.yml
version: "3.8"
services:
  wg-easy:
    image: weejewel/wg-easy
    container_name: wg-easy
    environment:
      - WG_HOST=$WG_DOMAIN
      - PASSWORD=admin
    ports:
      - "51820:51820/udp"
      - "127.0.0.1:51821:51821/tcp"
    volumes:
      - /etc/wireguard:/etc/wireguard
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

echo -e "${GREEN}🌐 Cài đặt Nginx + Certbot...${NC}"
sudo apt install -y nginx certbot python3-certbot-nginx

echo -e "${GREEN}🛠️ Tạo file cấu hình Nginx...${NC}"
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
sudo nginx -t && sudo systemctl reload nginx

echo -e "${GREEN}🔐 Cấp SSL Let's Encrypt với Certbot...${NC}"
sudo certbot --nginx -d "$WG_DOMAIN" --non-interactive --agree-tos -m admin@$WG_DOMAIN || {
    echo -e "${RED}❌ Không thể tạo chứng chỉ SSL. Kiểm tra lại domain!${NC}"
}

echo -e "${GREEN}📎 Cấu hình tường lửa UFW...${NC}"
sudo ufw allow 51820/udp
sudo ufw allow 'Nginx Full'
sudo ufw allow OpenSSH
sudo ufw --force enable

echo -e "${GREEN}⚙️ Thêm alias quản lý nhanh...${NC}"
cat <<'EOF' >> ~/.bashrc

# Alias cập nhật WireGuard
alias update-wireguard='sudo apt update && sudo apt install --only-upgrade wireguard -y'
alias wireguard-update='update-wireguard'

# Alias cập nhật wg-easy
alias update-wg-easy='bash -c "
echo \"📥 Kéo image mới nhất của wg-easy...\"
docker pull weejewel/wg-easy
echo \"🔄 Khởi động lại container wg-easy...\"
docker stop wg-easy && docker rm wg-easy
cd ~/wg-easy && docker compose up -d
echo \"✅ wg-easy đã được cập nhật!\"
"'

alias wg-easy-update='update-wg-easy'
EOF

[ "$EUID" -eq 0 ] && source ~/.bashrc || true

echo -e "${GREEN}🎉 Hoàn tất!${NC}"
echo -e "${GREEN}🔗 Truy cập wg-easy tại: https://$WG_DOMAIN${NC}"
echo -e "${GREEN}👤 Tài khoản: admin (chỉ cần mật khẩu)${NC}"

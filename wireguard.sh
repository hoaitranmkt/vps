#!/bin/bash

set -e

GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}🔍 Kiểm tra Docker...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${GREEN}🚀 Cài đặt Docker...${NC}"
    curl -fsSL https://get.docker.com | bash
    sudo usermod -aG docker $USER
else
    echo -e "${GREEN}✅ Docker đã có.${NC}"
fi

echo -e "${GREEN}🔍 Kiểm tra Docker Compose...${NC}"
if ! docker compose version &> /dev/null; then
    echo -e "${GREEN}🚀 Cài đặt Docker Compose plugin...${NC}"
    mkdir -p ~/.docker/cli-plugins/
    curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose
else
    echo -e "${GREEN}✅ Docker Compose đã có.${NC}"
fi

echo -e "${GREEN}🔍 Kiểm tra iptables và ufw...${NC}"
sudo apt update
sudo apt install -y ufw iptables iptables-persistent

echo -e "${GREEN}✅ Bật IP Forward cho WireGuard...${NC}"
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-wireguard-forward.conf
sudo sysctl -p /etc/sysctl.d/99-wireguard-forward.conf

echo -e "${GREEN}🚀 Cài đặt WireGuard...${NC}"
sudo apt install -y wireguard

echo -e "${GREEN}📂 Tạo thư mục cấu hình WireGuard...${NC}"
sudo mkdir -p /etc/wireguard
cd /etc/wireguard

echo -e "${GREEN}🔐 Sinh private/public key cho server...${NC}"
sudo wg genkey | sudo tee server_private.key | wg pubkey | sudo tee server_public.key

SERVER_PRIVATE_KEY=$(sudo cat server_private.key)

echo -e "${GREEN}📝 Tạo file cấu hình wg0.conf...${NC}"
cat <<EOF | sudo tee /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIVATE_KEY
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

echo -e "${GREEN}🚦 Khởi động dịch vụ wg-quick@wg0...${NC}"
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

echo -e "${GREEN}🧱 Thêm rule iptables...${NC}"
sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE

echo -e "${GREEN}💾 Lưu iptables persistent...${NC}"
sudo netfilter-persistent save

echo -e "${GREEN}🌐 Cập nhật DNS trong /etc/resolv.conf...${NC}"
sudo bash -c 'echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf'

echo -e "${GREEN}🔓 Cấu hình firewall (UFW)...${NC}"
sudo ufw allow 51820/udp
sudo ufw allow OpenSSH
sudo ufw --force enable

echo -e "${GREEN}📦 Clone wireguard-ui...${NC}"
cd ~
git clone https://github.com/ngoduykhanh/wireguard-ui.git
cd wireguard-ui

echo -e "${GREEN}🛠️ Sửa docker-compose.yml nếu cần...${NC}"
cat <<EOF | tee docker-compose.yml
version: "3.3"
services:
  wireguard-ui:
    build: .
    container_name: wireguard-ui
    cap_add:
      - NET_ADMIN
    ports:
      - "5000:5000"
    volumes:
      - ./db:/app/db
      - /etc/wireguard:/etc/wireguard
    environment:
      - WGUI_USERNAME=admin
      - WGUI_PASSWORD=admin
      - WGUI_MANAGE_START=true
      - WGUI_MANAGE_RESTART=true
    restart: unless-stopped
EOF

echo -e "${GREEN}🧱 Build và khởi chạy wireguard-ui...${NC}"
docker compose build
docker compose up -d

echo -e "${GREEN}🎉 Đã hoàn tất cài đặt WireGuard + wireguard-ui.${NC}"
PUBLIC_IP=$(curl -s https://api.ipify.org)
echo -e "${GREEN}🔑 Giao diện quản lý: http://$PUBLIC_IP:5000 với tài khoản admin/admin${NC}"


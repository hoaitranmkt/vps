#!/bin/bash

set -e

GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}🔍 Cập nhật hệ thống...${NC}"
sudo apt update
sudo apt upgrade -y

echo -e "${GREEN}🔍 Kiểm tra Docker...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${GREEN}🚀 Cài đặt Docker...${NC}"
    curl -fsSL https://get.docker.com | bash
    sudo usermod -aG docker $USER
else
    echo -e "${GREEN}✅ Docker đã được cài.${NC}"
fi

echo -e "${GREEN}🔍 Kiểm tra Docker Compose...${NC}"
if ! docker compose version &> /dev/null; then
    echo -e "${GREEN}🚀 Cài Docker Compose plugin...${NC}"
    mkdir -p ~/.docker/cli-plugins/
    curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose
else
    echo -e "${GREEN}✅ Docker Compose đã được cài.${NC}"
fi

echo -e "${GREEN}🔍 Cài đặt UFW và iptables...${NC}"
sudo apt install -y ufw iptables

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

echo -e "${GREEN}📝 Viết cấu hình /etc/wireguard/wg0.conf...${NC}"
cat <<EOF | sudo tee /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIVATE_KEY
PostUp   = iptables -A FORW

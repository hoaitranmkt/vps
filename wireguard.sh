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
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

echo -e "${GREEN}🚦 Khởi động wg-quick@wg0...${NC}"
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

echo -e "${GREEN}🧱 Thêm rule iptables tạm thời (chỉ đến khi reboot)...${NC}"
sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE

echo -e "${GREEN}🌐 Cấu hình DNS trong /etc/resolv.conf...${NC}"
sudo bash -c 'echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf'

echo -e "${GREEN}🔐 Cấu hình UFW cho WireGuard và SSH...${NC}"
sudo ufw allow 51820/udp
sudo ufw allow OpenSSH

echo -e "${GREEN}🔄 Kích hoạt và reload UFW...${NC}"
sudo ufw --force enable
sudo ufw reload

echo -e "${GREEN}📦 Clone wireguard-ui từ GitHub...${NC}"
cd ~
if [ -d wireguard-ui ]; then
    echo "Thư mục wireguard-ui đã tồn tại, sẽ cập nhật lại."
    cd wireguard-ui && git pull
else
    git clone https://github.com/ngoduykhanh/wireguard-ui.git
    cd wireguard-ui
fi

echo -e "${GREEN}🛠️ Viết lại docker-compose.yml...${NC}"
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

echo -e "${GREEN}🧱 Build và khởi động wireguard-ui...${NC}"
docker compose build
docker compose up -d

echo -e "${GREEN}🔧 Tạo script giữ iptables sau reboot...${NC}"
sudo tee /usr/local/bin/iptables-wireguard.sh > /dev/null << 'EOF'
#!/bin/bash
iptables -A INPUT -p udp --dport 51820 -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
EOF
sudo chmod +x /usr/local/bin/iptables-wireguard.sh

echo -e "${GREEN}🔧 Tạo systemd service tự động chạy script iptables sau reboot...${NC}"
sudo tee /etc/systemd/system/iptables-wireguard.service > /dev/null << EOF
[Unit]
Description=Restore WireGuard IPTables Rules
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/iptables-wireguard.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable iptables-wireguard.service
sudo systemctl start iptables-wireguard.service

PUBLIC_IP=$(curl -s https://api.ipify.org)
echo -e "${GREEN}🎉 Hoàn tất cài đặt WireGuard + wireguard-ui.${NC}"
echo -e "${GREEN}🔑 Truy cập giao diện quản lý: http://$PUBLIC_IP:5000 với tài khoản admin/admin${NC}"

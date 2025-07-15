#!/bin/bash

set -e

echo "✅ Bắt đầu cài đặt Docker, Docker Compose và Portainer..."

# Cập nhật hệ thống
sudo apt update && sudo apt upgrade -y

# Cài đặt gói phụ thuộc
sudo apt install -y ca-certificates curl gnupg lsb-release

# Thêm Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Thêm Docker repo
echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Cài đặt Docker Engine và Docker Compose plugin
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Bật Docker và cho chạy khi khởi động
sudo systemctl enable docker
sudo systemctl start docker

# Thêm user hiện tại vào nhóm docker
sudo usermod -aG docker $USER

# Cài đặt Portainer
docker volume create portainer_data
docker run -d \
  --name portainer \
  --restart=always \
  -p 8000:8000 \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest

# Tạo alias update
echo 'alias docker-update="sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"' >> ~/.bashrc
echo 'alias portainer-update="docker pull portainer/portainer-ce:latest && docker stop portainer && docker rm portainer && docker run -d --name portainer --restart=always -p 8000:8000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"' >> ~/.bashrc

source ~/.bashrc

# Lấy IP public (dùng dịch vụ ifconfig.me, fallback nếu curl không có mạng)
IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

echo "✅ Cài đặt hoàn tất!"
echo "👉 Truy cập Portainer tại: https://$IP:9443"
echo "❗ Hãy đăng xuất và đăng nhập lại để group 'docker' có hiệu lực."

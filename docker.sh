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

# Cài đặt Docker và Docker Compose plugin
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Bật và khởi động Docker
sudo systemctl enable docker
sudo systemctl start docker

# Thêm user hiện tại vào group docker
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

# Thêm alias cập nhật Docker
echo 'alias docker-update="sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"' >> ~/.bashrc
echo 'alias update-docker="sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"' >> ~/.bashrc

# Thêm alias cập nhật Portainer
echo 'alias portainer-update="docker pull portainer/portainer-ce:latest && docker stop portainer && docker rm portainer && docker run -d --name portainer --restart=always -p 8000:8000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"' >> ~/.bashrc
echo 'alias update-portainer="docker pull portainer/portainer-ce:latest && docker stop portainer && docker rm portainer && docker run -d --name portainer --restart=always -p 8000:8000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"' >> ~/.bashrc

# Nạp lại bashrc
source ~/.bashrc

# Lấy IPv4 công khai
IP=$(curl -s -4 ifconfig.me || hostname -I | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}')

echo "✅ Cài đặt hoàn tất!"
echo "👉 Truy cập Portainer tại: https://$IP:9443"
echo "❗ Đăng xuất và đăng nhập lại để nhóm 'docker' có hiệu lực."

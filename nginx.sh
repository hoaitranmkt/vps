#!/bin/bash

set -e

echo "🔧 Updating system packages..."
sudo apt update && sudo apt upgrade -y

echo "🌐 Installing Nginx..."
sudo apt install nginx -y

echo "✅ Nginx installed. Status:"
sudo systemctl enable nginx
sudo systemctl start nginx
sudo systemctl status nginx --no-pager

echo "🐳 Installing Docker & Docker Compose..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | bash
    sudo usermod -aG docker $USER
fi

if ! command -v docker-compose &> /dev/null; then
    sudo apt install docker-compose -y
fi

echo "📁 Setting up Nginx UI with Docker..."

mkdir -p ~/nginx-ui
cd ~/nginx-ui

cat <<EOF > docker-compose.yml
version: "3"

services:
  nginx-ui:
    image: schx/nginx-ui:latest
    container_name: nginx-ui
    ports:
      - "8080:8080"
    volumes:
      - /etc/nginx:/etc/nginx
      - /var/log/nginx:/var/log/nginx
    environment:
      - LANG=en
    restart: always
EOF

echo "🚀 Starting Nginx UI..."
docker compose up -d

# Lấy địa chỉ IPv4 công khai
IPV4=$(curl -s http://ipv4.icanhazip.com)

echo "✅ Installation complete!"
echo "🌐 Access Nginx UI: http://${IPV4}:8080"

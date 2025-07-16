#!/bin/bash

set -e

echo "🔧 Updating system..."
sudo apt update && sudo apt upgrade -y

echo "🌐 Installing Nginx..."
sudo apt install -y nginx curl unzip wget

echo "✅ Starting Nginx..."
sudo systemctl enable nginx
sudo systemctl start nginx

echo "📦 Downloading Nginx UI..."

# Tạo thư mục cài đặt
INSTALL_DIR="/opt/nginx-ui"
sudo mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Tải file zip mới nhất
sudo wget https://github.com/schx/nginx-ui/releases/latest/download/nginx-ui-linux-amd64.zip -O nginx-ui.zip

# Giải nén
sudo unzip -o nginx-ui.zip
sudo chmod +x nginx-ui

# Tạo systemd service
echo "🛠️ Setting up systemd service..."

sudo tee /etc/systemd/system/nginx-ui.service > /dev/null <<EOF
[Unit]
Description=Nginx UI
After=network.target

[Service]
ExecStart=$INSTALL_DIR/nginx-ui
WorkingDirectory=$INSTALL_DIR
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# Reload, enable, and start service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable nginx-ui
sudo systemctl start nginx-ui

# Lấy IP công khai
IPV4=$(curl -s http://ipv4.icanhazip.com)

echo "✅ Installation complete!"
echo "🌐 Access Nginx UI: http://${IPV4}:8080"

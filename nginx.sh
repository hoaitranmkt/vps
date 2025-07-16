#!/bin/bash

set -e

echo "🔧 Updating system..."
sudo apt update && sudo apt upgrade -y

echo "🌐 Installing Nginx..."
sudo apt install -y nginx curl wget unzip

echo "✅ Starting Nginx..."
sudo systemctl enable nginx
sudo systemctl start nginx

echo "📦 Installing Nginx UI (Stable version)..."
bash -c "$(curl -L https://cloud.nginxui.com/install.sh)" @ install

# Hàm kiểm tra port có đang được sử dụng?
function check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port\b"; then
        return 0
    else
        return 1
    fi
}

CONFIG_FILE="/usr/local/etc/nginx-ui/app.ini"

DEFAULT_HTTP_PORT=9000
DEFAULT_CHALLENGE_PORT=9180

NEW_HTTP_PORT=$DEFAULT_HTTP_PORT
NEW_CHALLENGE_PORT=$DEFAULT_CHALLENGE_PORT

changed_ports=0

echo "⚙️ Checking if default ports $DEFAULT_HTTP_PORT and $DEFAULT_CHALLENGE_PORT are free..."

if check_port $DEFAULT_HTTP_PORT || check_port $DEFAULT_CHALLENGE_PORT; then
    echo "⚠️ One or both default ports are in use. Trying to change ports..."

    # Tìm port trống bắt đầu từ 9100 cho HTTP và 9280 cho Challenge
    for port in {9100..9199}; do
        challenge_port=$((port + 180))
        if ! check_port $port && ! check_port $challenge_port; then
            NEW_HTTP_PORT=$port
            NEW_CHALLENGE_PORT=$challenge_port
            changed_ports=1
            break
        fi
    done

    if [ $changed_ports -eq 1 ]; then
        echo "✅ Changing Nginx UI HTTPPort to $NEW_HTTP_PORT and ChallengeHTTPPort to $NEW_CHALLENGE_PORT"

        sudo sed -i "s/^HTTPPort = .*/HTTPPort = $NEW_HTTP_PORT/" $CONFIG_FILE
        sudo sed -i "s/^ChallengeHTTPPort = .*/ChallengeHTTPPort = $NEW_CHALLENGE_PORT/" $CONFIG_FILE

        echo "🔄 Restarting nginx-ui service..."
        sudo systemctl restart nginx-ui
    else
        echo "❌ Could not find free ports to assign. Please manually edit $CONFIG_FILE"
    fi
else
    echo "✅ Default ports are free, no changes needed."
fi

# Lấy IPv4 công khai
IPV4=$(curl -s http://ipv4.icanhazip.com)

echo ""
echo "✅ Installation complete!"
echo "🌐 Access Nginx UI: http://${IPV4}:${NEW_HTTP_PORT}"
echo "🔐 Default login: admin / admin"
echo ""

# Thêm alias vào .bashrc user gọi sudo
TARGET_USER=${SUDO_USER:-root}
BASHRC_PATH=$(eval echo "~$TARGET_USER/.bashrc")

function add_alias() {
    local alias_cmd="$1"
    local alias_name=$(echo "$alias_cmd" | awk '{print $2}' | cut -d= -f1)
    if ! grep -q "^alias $alias_name=" "$BASHRC_PATH"; then
        echo "$alias_cmd" >> "$BASHRC_PATH"
        echo "✅ Alias '$alias_name' added to $BASHRC_PATH"
    else
        echo "ℹ️ Alias '$alias_name' already exists in $BASHRC_PATH"
    fi
}

add_alias "alias restart-nginx-ui='sudo systemctl restart nginx-ui'"
add_alias "alias update-nginx-ui='bash -c \"\$(curl -L https://cloud.nginxui.com/install.sh)\" @ install && sudo systemctl restart nginx-ui'"

echo ""
echo "ℹ️ Aliases added for user '$TARGET_USER'."
echo "👉 Please run 'source $BASHRC_PATH' or open a new terminal to use them."

#!/bin/bash
set -e

echo "🔧 Cập nhật hệ thống..."
sudo apt update && sudo apt upgrade -y

echo "🌐 Cài đặt Nginx và công cụ hỗ trợ..."
sudo apt install -y nginx curl wget unzip ufw

echo "✅ Khởi động và bật Nginx..."
sudo systemctl enable nginx
sudo systemctl start nginx

echo "📦 Cài đặt Nginx UI (phiên bản stable)..."
bash -c "$(curl -L https://cloud.nginxui.com/install.sh)"

function check_port() {
  local port=$1
  if ss -tuln | grep -q ":$port\b"; then
    return 0
  else
    return 1
  fi
}

CONFIG_FILE="/usr/local/etc/nginx-ui/app.ini"
sudo mkdir -p $(dirname "$CONFIG_FILE")
sudo touch "$CONFIG_FILE"

DEFAULT_HTTP_PORT=9000
DEFAULT_CHALLENGE_PORT=9180

HTTP_PORT=$DEFAULT_HTTP_PORT
CHALLENGE_PORT=$DEFAULT_CHALLENGE_PORT

echo "⚙️ Kiểm tra port mặc định $DEFAULT_HTTP_PORT và $DEFAULT_CHALLENGE_PORT..."

if check_port $DEFAULT_HTTP_PORT || check_port $DEFAULT_CHALLENGE_PORT; then
  echo "⚠️ Port mặc định đang được sử dụng, tìm port trống..."
  for p in {9100..9199}; do
    cp=$((p + 180))
    if ! check_port $p && ! check_port $cp; then
      HTTP_PORT=$p
      CHALLENGE_PORT=$cp
      echo "✅ Tìm được cặp port trống: HTTPPort=$HTTP_PORT, ChallengeHTTPPort=$CHALLENGE_PORT"
      break
    fi
  done
else
  echo "✅ Port mặc định còn trống, sử dụng $DEFAULT_HTTP_PORT và $DEFAULT_CHALLENGE_PORT"
fi

echo "🔧 Cập nhật cấu hình Nginx UI..."
sudo sed -i "s/^HTTPPort = .*/HTTPPort = $HTTP_PORT/" "$CONFIG_FILE" 2>/dev/null || echo "HTTPPort = $HTTP_PORT" | sudo tee -a "$CONFIG_FILE"
sudo sed -i "s/^ChallengeHTTPPort = .*/ChallengeHTTPPort = $CHALLENGE_PORT/" "$CONFIG_FILE" 2>/dev/null || echo "ChallengeHTTPPort = $CHALLENGE_PORT" | sudo tee -a "$CONFIG_FILE"

echo "🔄 Khởi động lại dịch vụ nginx-ui..."
sudo systemctl restart nginx-ui

echo "🔐 Cấu hình tường lửa UFW..."

# Cho phép SSH để tránh khóa kết nối
sudo ufw allow OpenSSH

# Cho phép cổng HTTP/HTTPS
sudo ufw allow 80
sudo ufw allow 443

# Cho phép các port Nginx UI
sudo ufw allow $HTTP_PORT
sudo ufw allow $CHALLENGE_PORT

# Bật UFW nếu chưa bật
if sudo ufw status | grep -q "Status: inactive"; then
  echo "⚠️ UFW đang tắt. Bật tường lửa..."
  sudo ufw --force enable
else
  echo "✅ UFW đã bật."
fi

IPV4=$(curl -s http://ipv4.icanhazip.com)

echo ""
echo "✅ Cài đặt hoàn tất!"
echo "🌐 Truy cập Nginx UI: http://${IPV4}:${HTTP_PORT}"
echo "🔐 Mặc định tài khoản: admin / admin"
echo ""

# Thêm alias cho tiện sử dụng
TARGET_USER=${SUDO_USER:-root}
BASHRC_PATH=$(eval echo "~$TARGET_USER/.bashrc")

function add_alias() {
  local alias_cmd="$1"
  local alias_name=$(echo "$alias_cmd" | awk '{print $2}' | cut -d= -f1)
  if ! grep -q "^alias $alias_name=" "$BASHRC_PATH"; then
    echo "$alias_cmd" >> "$BASHRC_PATH"
    echo "✅ Alias '$alias_name' đã thêm vào $BASHRC_PATH"
  else
    echo "ℹ️ Alias '$alias_name' đã tồn tại trong $BASHRC_PATH"
  fi
}

add_alias "alias restart-nginx-ui='sudo systemctl restart nginx-ui'"
add_alias "alias update-nginx-ui='bash -c \"\$(curl -L https://cloud.nginxui.com/install.sh)\" && sudo systemctl restart nginx-ui'"

[ "$EUID" -eq 0 ] && source /root/.bashrc || true

echo ""
echo "ℹ️ Đã thêm alias cho user '$TARGET_USER'."
echo "👉 Vui lòng chạy 'source $BASHRC_PATH' hoặc mở terminal mới để sử dụng."

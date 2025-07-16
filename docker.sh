#!/bin/bash
set -e

echo "✅ Bắt đầu cài đặt Docker, Docker Compose và Portainer..."

# ---------- 1. CÀI ĐẶT DOCKER ----------
if ! command -v docker &> /dev/null; then
  echo "📦 Docker chưa cài, tiến hành cài đặt..."
  sudo apt update && sudo apt upgrade -y
  sudo apt install -y ca-certificates curl gnupg lsb-release

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
   | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
   | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io \
                      docker-buildx-plugin docker-compose-plugin

  sudo systemctl enable docker
  sudo systemctl start docker

  echo "✅ Docker đã được cài đặt."
else
  echo "⚠️  Docker đã được cài đặt. Bỏ qua."
fi

# ---------- 2. THÊM USER VÀO NHÓM DOCKER ----------
if [[ $EUID -ne 0 ]]; then
  sudo usermod -aG docker "$USER"
fi

# ---------- 3. CÀI PORTAINER (nếu chưa có) ----------
if docker ps -a --format '{{.Names}}' | grep -qw portainer; then
  echo "⚠️  Container Portainer đã tồn tại. Bỏ qua cài đặt."
else
  echo "📦 Đang cài đặt Portainer..."
  docker volume create portainer_data >/dev/null
  docker run -d --name portainer --restart=always \
    -p 8000:8000 -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
  echo "✅ Portainer đã được cài đặt."
fi

# ---------- 4. THÊM ALIAS ----------
add_aliases() {
  local TARGET_BASHRC="$1"
  grep -qxF 'alias docker-update=' "$TARGET_BASHRC" || cat >> "$TARGET_BASHRC" <<'EOF'
alias docker-update="sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
alias update-docker="sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
alias portainer-update="docker pull portainer/portainer-ce:latest && docker stop portainer && docker rm portainer && docker run -d --name portainer --restart=always -p 8000:8000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"
alias update-portainer="docker pull portainer/portainer-ce:latest && docker stop portainer && docker rm portainer && docker run -d --name portainer --restart=always -p 8000:8000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"
EOF
}

# Thêm alias cho user hiện tại (nếu không phải root)
USER_BASHRC="$HOME/.bashrc"
[ -f "$USER_BASHRC" ] && add_aliases "$USER_BASHRC"

# Thêm alias cho root
sudo bash -c "$(declare -f add_aliases); add_aliases /root/.bashrc"

# Nạp alias cho root ngay nếu đang là root
[ "$EUID" -eq 0 ] && source /root/.bashrc || true

# ---------- 5. LẤY IP PUBLIC IPv4 ----------
IP=$(curl -s -4 ifconfig.me || \
     hostname -I | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}')

echo -e "\n✅ Hoàn tất cài đặt!"
echo "🌐 Truy cập Portainer tại: https://$IP:9443"
echo "ℹ️ Nếu vừa thêm user vào group docker, hãy đăng xuất và đăng nhập lại để quyền có hiệu lực."

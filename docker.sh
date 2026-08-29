#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
  echo -e "${BLUE}$1${NC}"
}

success() {
  echo -e "${GREEN}$1${NC}"
}

warn() {
  echo -e "${YELLOW}$1${NC}"
}

error() {
  echo -e "${RED}$1${NC}"
}

success "✅ Bắt đầu cài đặt Docker và Docker Compose..."

if [[ $EUID -ne 0 ]]; then
  error "❌ Vui lòng chạy script với quyền root (sudo)."
  exit 1
fi

info "📦 Cài đặt gói phụ thuộc..."
apt update
apt install -y ca-certificates curl gnupg lsb-release

info "🐳 Cài đặt Docker Engine + Docker Compose Plugin..."
install -m 0755 -d /etc/apt/keyrings

if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
  OS_CODENAME="$VERSION_CODENAME"
else
  error "❌ Không thể xác định hệ điều hành."
  exit 1
fi

if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
  error "❌ Script chỉ hỗ trợ Ubuntu và Debian. Hệ hiện tại: $OS_ID"
  exit 1
fi

if [ -z "$OS_CODENAME" ]; then
  if command -v lsb_release >/dev/null 2>&1; then
    OS_CODENAME="$(lsb_release -cs)"
  elif [ -n "$UBUNTU_CODENAME" ]; then
    OS_CODENAME="$UBUNTU_CODENAME"
  fi
fi

if [ -z "$OS_CODENAME" ]; then
  error "❌ Không thể xác định codename của hệ điều hành."
  exit 1
fi

if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable
EOF

apt update

SKIP_DOCKER_INSTALL="no"

if command -v docker >/dev/null 2>&1; then
  warn "🔄 Docker đã tồn tại: $(docker --version)"
  warn "   Cập nhật package sẽ KHỞI ĐỘNG LẠI Docker daemon."
  warn "   Container đang chạy sẽ gián đoạn vài giây; container không có"
  warn "   restart policy (unless-stopped / always) sẽ TẮT hẳn."
  echo ""
  info "   Container đang chạy:"
  docker ps --format '   - {{.Names}} ({{.Status}})' 2>/dev/null || true
  echo ""
  read -rp "Tiếp tục cập nhật Docker Engine? (y/N): " CONFIRM_UPDATE

  if [[ "$CONFIRM_UPDATE" != "y" && "$CONFIRM_UPDATE" != "Y" ]]; then
    SKIP_DOCKER_INSTALL="yes"
    warn "ℹ️ Bỏ qua bước cập nhật Docker Engine."

    if ! docker compose version >/dev/null 2>&1; then
      info "📦 Thiếu Compose plugin, chỉ cài thêm docker-compose-plugin..."
      apt install -y docker-compose-plugin
    fi
  fi
else
  info "📦 Docker chưa được cài, tiến hành cài đặt..."
fi

if [ "$SKIP_DOCKER_INSTALL" != "yes" ]; then
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  # start (khong phai restart): apt da tu restart daemon khi upgrade package.
  systemctl start docker
fi

info "🔎 Kiểm tra Docker..."
if docker --version >/dev/null 2>&1; then
  docker --version
else
  error "❌ Docker không hoạt động sau khi cài đặt."
  exit 1
fi

info "🔎 Kiểm tra Docker Compose..."
if docker compose version >/dev/null 2>&1; then
  docker compose version
else
  error "❌ Docker Compose không hoạt động sau khi cài đặt."
  exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
if id -nG "$TARGET_USER" | grep -qw docker; then
  success "✅ User $TARGET_USER đã thuộc group docker."
else
  usermod -aG docker "$TARGET_USER"
  success "✅ Đã thêm $TARGET_USER vào group docker."
fi

if [ "$TARGET_USER" = "root" ]; then
  TARGET_BASHRC="/root/.bashrc"
else
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  TARGET_BASHRC="$TARGET_HOME/.bashrc"
fi

add_aliases() {
  local target_file="$1"
  touch "$target_file"

  grep -q '^alias docker-update=' "$target_file" || echo 'alias docker-update="/usr/local/bin/docker-update"' >> "$target_file"
  grep -q '^alias update-docker=' "$target_file" || echo 'alias update-docker="/usr/local/bin/update-docker"' >> "$target_file"
}

create_update_commands() {
  cat > /usr/local/bin/docker-update <<'EOF'
#!/bin/bash
set -e

if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "⚠️  Cập nhật Docker sẽ khởi động lại daemon, container đang chạy sẽ gián đoạn."
$SUDO docker ps --format '   - {{.Names}} ({{.Status}})' 2>/dev/null || true
read -rp "Tiếp tục? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Đã huỷ."
  exit 0
fi

$SUDO apt update
$SUDO apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
$SUDO docker ps
EOF

  cat > /usr/local/bin/update-docker <<'EOF'
#!/bin/bash
set -e
exec /usr/local/bin/docker-update "$@"
EOF

  chmod +x /usr/local/bin/docker-update /usr/local/bin/update-docker
}

info "⚙️ Thêm alias command..."
add_aliases "$TARGET_BASHRC"
add_aliases "/root/.bashrc"
create_update_commands
success "✅ Đã tạo command: docker-update, update-docker"

warn "ℹ️ Alias sẽ có hiệu lực ở phiên shell mới tiếp theo."

echo ""
success "✅ Hoàn tất cài đặt Docker và Docker Compose."
info "💡 Alias đã thêm: docker-update, update-docker"

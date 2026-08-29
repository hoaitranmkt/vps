#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

COMPOSE_DIR="/root/nginx-proxy-manager"

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

is_tcp_port_in_use() {
  local port="$1"
  ss -ltn 2>/dev/null | tail -n +2 | awk '{print $4}' | grep -Eq "[:.]$port$"
}

port_owner() {
  local port="$1"
  ss -ltnp 2>/dev/null | tail -n +2 | awk -v p="$port" '$4 ~ ("[:.]" p "$") {print $NF}' | head -n1
}

detect_ssh_ports() {
  local ports=""

  if command -v sshd >/dev/null 2>&1; then
    ports="$(sshd -T 2>/dev/null | awk '/^port /{print $2}')"
  fi

  if [ -z "$ports" ]; then
    ports="$(ss -ltnp 2>/dev/null | grep -i 'sshd' | awk '{print $4}' | sed 's/.*[:.]//' | sort -u)"
  fi

  if [ -z "$ports" ]; then
    ports="22"
  fi

  echo "$ports"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    success "✅ Docker + Compose plugin đã sẵn sàng, bỏ qua bước cài đặt."
    info "   $(docker --version)"
    info "   $(docker compose version)"
    return
  fi

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

  info "🐳 Thêm repository Docker..."
  install -m 0755 -d /etc/apt/keyrings

  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable
EOF

  apt update

  if command -v docker >/dev/null 2>&1; then
    warn "🔄 Docker đã có sẵn nhưng thiếu Compose plugin, chỉ cài thêm docker-compose-plugin."
    apt install -y docker-compose-plugin
  else
    info "📦 Docker chưa được cài, tiến hành cài đặt..."
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
  fi

  if ! docker --version >/dev/null 2>&1; then
    error "❌ Docker không hoạt động sau khi cài đặt."
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    error "❌ Docker Compose không hoạt động sau khi cài đặt."
    exit 1
  fi

  success "✅ $(docker --version)"
  success "✅ $(docker compose version)"
}

check_web_ports() {
  info "🔎 Kiểm tra port 80/443..."

  if docker ps --format '{{.Names}}' | grep -qw nginx-proxy-manager; then
    warn "ℹ️ Container nginx-proxy-manager đang chạy sẵn, bỏ qua kiểm tra port."
    return
  fi

  local conflict="no"
  local p

  for p in 80 443; do
    if is_tcp_port_in_use "$p"; then
      conflict="yes"
      error "❌ Port $p/tcp đang được sử dụng bởi: $(port_owner "$p")"
    fi
  done

  if [ "$conflict" = "yes" ]; then
    echo ""
    error "NPM cần chiếm 80/443. Hãy dừng service đang giữ port trước khi cài."
    warn "Gợi ý: nếu bạn đang dùng Cloudflare Tunnel thì KHÔNG cần NPM —"
    warn "tunnel đã làm reverse proxy và không cần mở 80/443 ra internet."
    exit 1
  fi

  success "✅ Port 80/tcp và 443/tcp đang trống."
}

add_aliases() {
  local target_file="$1"
  touch "$target_file"

  grep -q '^alias nginx-update=' "$target_file" || echo 'alias nginx-update="/usr/local/bin/nginx-update"' >> "$target_file"
  grep -q '^alias update-nginx=' "$target_file" || echo 'alias update-nginx="/usr/local/bin/update-nginx"' >> "$target_file"
}

create_update_commands() {
  cat > /usr/local/bin/nginx-update <<'EOF'
#!/bin/bash
set -e

COMPOSE_DIR="/root/nginx-proxy-manager"

if [[ $EUID -ne 0 ]]; then
  exec sudo /usr/local/bin/nginx-update "$@"
fi

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  echo "Missing $COMPOSE_DIR/docker-compose.yml. Run the install script again first."
  exit 1
fi

cd "$COMPOSE_DIR"

docker network inspect proxy >/dev/null 2>&1 || docker network create --driver bridge --attachable proxy

docker compose pull
docker compose up -d
docker compose ps
EOF

  cat > /usr/local/bin/update-nginx <<'EOF'
#!/bin/bash
set -e
exec /usr/local/bin/nginx-update "$@"
EOF

  chmod +x /usr/local/bin/nginx-update /usr/local/bin/update-nginx
}

configure_ufw() {
  local ssh_ports
  ssh_ports="$(detect_ssh_ports)"

  info "🔥 Cấu hình firewall (UFW)..."
  info "   Port SSH phát hiện được: $(echo $ssh_ports | tr '\n' ' ')"

  if ! command -v ufw >/dev/null 2>&1; then
    warn "⚠️ UFW chưa được cài, bỏ qua bước firewall."
    return
  fi

  local ufw_active="no"
  ufw status 2>/dev/null | head -n1 | grep -q 'Status: active' && ufw_active="yes"

  if [ "$ufw_active" = "no" ]; then
    warn "⚠️ UFW hiện đang TẮT."
    warn "   Bật UFW sẽ chặn mọi port inbound không nằm trong danh sách allow."
    warn "   Các service khác đang chạy trực tiếp trên host có thể bị chặn."
    echo ""
    read -rp "Bạn có muốn bật UFW không? (y/N): " ENABLE_UFW

    if [[ "$ENABLE_UFW" != "y" && "$ENABLE_UFW" != "Y" ]]; then
      warn "ℹ️ Bỏ qua UFW."
      return
    fi
  fi

  local p
  for p in $ssh_ports; do
    ufw allow "$p/tcp" >/dev/null
    success "   ✅ Allow SSH $p/tcp"
  done

  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  success "   ✅ Allow 80/tcp, 443/tcp"

  if [ "$EXPOSE_ADMIN_PORT" = "yes" ]; then
    ufw allow 81/tcp >/dev/null
    warn "   ⚠️ Đã mở 81/tcp — trang admin NPM lộ ra internet."
  fi

  if [ "$ufw_active" = "no" ]; then
    ufw --force enable
    success "   ✅ Đã bật UFW."
  else
    success "   ✅ UFW đang bật sẵn, chỉ thêm rule mới (không reset cấu hình cũ)."
  fi

  ufw reload >/dev/null
}

success "✅ Bắt đầu cài đặt Nginx Proxy Manager..."

if [[ $EUID -ne 0 ]]; then
  error "❌ Vui lòng chạy script với quyền root (sudo)."
  exit 1
fi

info "📦 Cài đặt gói phụ thuộc..."
apt update
apt install -y ca-certificates curl gnupg lsb-release ufw iproute2

ensure_docker

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

echo ""
info "🔐 Trang quản trị NPM (port 81) mặc định chỉ lắng nghe trên 127.0.0.1"
info "   và được truy cập qua SSH tunnel — an toàn hơn nhiều so với mở ra internet."
echo ""
read -rp "Mở port 81 ra internet? (y/N): " EXPOSE_ADMIN
if [[ "$EXPOSE_ADMIN" == "y" || "$EXPOSE_ADMIN" == "Y" ]]; then
  EXPOSE_ADMIN_PORT="yes"
  ADMIN_PORT_MAPPING='"81:81"'
  warn "⚠️ Trang admin NPM sẽ lộ ra internet. Hãy đổi mật khẩu mặc định ngay sau khi cài."
else
  EXPOSE_ADMIN_PORT="no"
  ADMIN_PORT_MAPPING='"127.0.0.1:81:81"'
fi

check_web_ports

info "📁 Tạo thư mục chứa docker-compose của Nginx Proxy Manager..."
mkdir -p "$COMPOSE_DIR"
cd "$COMPOSE_DIR"

info "🌐 Tạo Docker network proxy nếu chưa có..."
if docker network inspect proxy >/dev/null 2>&1; then
  success "✅ Network proxy đã tồn tại."
else
  docker network create --driver bridge --attachable proxy
  success "✅ Đã tạo network proxy."
fi

info "📝 Tạo file docker-compose.yml..."
cat > docker-compose.yml <<EOF
services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - $ADMIN_PORT_MAPPING
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - proxy

networks:
  proxy:
    external: true
    name: proxy
EOF

info "🚀 Khởi động Nginx Proxy Manager..."
docker compose pull
docker compose up -d

sleep 5

info "🔎 Kiểm tra container..."
docker compose ps

if docker ps --format '{{.Names}}' | grep -qw nginx-proxy-manager; then
  success "✅ Nginx Proxy Manager đang hoạt động."
else
  error "❌ Nginx Proxy Manager không chạy. Xem log: docker logs nginx-proxy-manager"
  exit 1
fi

configure_ufw

info "⚙️ Thêm alias và command update..."
add_aliases "$TARGET_BASHRC"
add_aliases "/root/.bashrc"
create_update_commands
success "✅ Đã tạo command: nginx-update, update-nginx"

PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')"

echo ""
success "✅ Hoàn tất cài đặt Nginx Proxy Manager."
echo ""
info "📁 Thư mục compose : $COMPOSE_DIR"
info "📁 Dữ liệu         : $COMPOSE_DIR/data và $COMPOSE_DIR/letsencrypt"
echo ""

if [ "$EXPOSE_ADMIN_PORT" = "yes" ]; then
  info "🔑 Trang quản trị: http://$PUBLIC_IP:81"
else
  info "🔑 Trang quản trị (qua SSH tunnel):"
  echo "ssh -L 81:127.0.0.1:81 root@$PUBLIC_IP"
  echo "-> mở http://127.0.0.1:81"
fi

echo ""
warn "Tài khoản mặc định lần đầu:"
echo "Email    : admin@example.com"
echo "Password : changeme"
warn "Đổi ngay sau khi đăng nhập lần đầu."
echo ""
info "💡 Commands: nginx-update, update-nginx"
warn "ℹ️ Alias sẽ có hiệu lực ở phiên shell mới tiếp theo."

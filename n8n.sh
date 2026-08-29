#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

N8N_DIR="/root/n8n"
ENV_FILE="$N8N_DIR/.env"

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

install_docker_if_needed() {
  info "🐳 Kiểm tra Docker..."

  # VPS dang chay: khong dung toi Docker daemon neu no da hoat dong binh thuong.
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    success "✅ Docker + Compose plugin đã sẵn sàng, bỏ qua bước cài đặt."
    info "   $(docker --version)"
    info "   $(docker compose version)"
    return
  fi

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

  if [ "$PROXY_MODE" = "npm" ]; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    success "   ✅ Allow 80/tcp, 443/tcp (Nginx Proxy Manager)"
  else
    info "   ℹ️ Cloudflare Tunnel chỉ dùng kết nối outbound, không cần mở 80/443."
  fi

  if [ "$ufw_active" = "no" ]; then
    ufw --force enable
    success "   ✅ Đã bật UFW."
  else
    success "   ✅ UFW đang bật sẵn, chỉ thêm rule mới (không reset cấu hình cũ)."
  fi

  ufw reload >/dev/null
}

create_update_commands() {
  cat > /usr/local/bin/n8n-update <<'EOF'
#!/bin/bash
set -e

N8N_DIR="/root/n8n"

if [[ $EUID -ne 0 ]]; then
  exec sudo /usr/local/bin/n8n-update "$@"
fi

if [ ! -f "$N8N_DIR/.env" ]; then
  echo "Missing $N8N_DIR/.env. Run the install script first."
  exit 1
fi

mkdir -p "$N8N_DIR/n8n_data" "$N8N_DIR/postgres" "$N8N_DIR/redis"
chown -R 1000:1000 "$N8N_DIR/n8n_data"
chown -R 999:999 "$N8N_DIR/postgres" "$N8N_DIR/redis"

if ! docker network inspect proxy >/dev/null 2>&1; then
  docker network create --driver bridge --attachable proxy
fi

cd "$N8N_DIR"
docker compose pull
docker compose up -d
docker compose ps
EOF

  cat > /usr/local/bin/update-n8n <<'EOF'
#!/bin/bash
set -e
/usr/local/bin/n8n-update "$@"
EOF

  chmod +x /usr/local/bin/n8n-update /usr/local/bin/update-n8n
}

add_aliases() {
  local target_file="$1"
  touch "$target_file"

  grep -q '^alias n8n-update=' "$target_file" || echo 'alias n8n-update="/usr/local/bin/n8n-update"' >> "$target_file"
  grep -q '^alias update-n8n=' "$target_file" || echo 'alias update-n8n="/usr/local/bin/update-n8n"' >> "$target_file"
}

success "✅ Bắt đầu cài đặt n8n queue mode..."

if [[ $EUID -ne 0 ]]; then
  error "❌ Vui lòng chạy script bằng quyền root (sudo)."
  exit 1
fi

info "📦 Cài đặt gói phụ thuộc..."
apt update
apt install -y ca-certificates curl gnupg lsb-release ufw dnsutils iproute2

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

install_docker_if_needed

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

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
fi

echo ""
info "🔀 n8n sẽ được truy cập qua reverse proxy nào?"
echo ""
echo "  1) Cloudflare Tunnel (cloudflared chạy Docker)   (khuyến nghị)"
echo "  2) Nginx Proxy Manager"
echo ""
read -rp "👉 Lựa chọn [1-2] (mặc định 1): " PROXY_CHOICE
PROXY_CHOICE="${PROXY_CHOICE:-1}"

case "$PROXY_CHOICE" in
  1) PROXY_MODE="cloudflare" ;;
  2) PROXY_MODE="npm" ;;
  *)
    error "❌ Lựa chọn không hợp lệ: $PROXY_CHOICE"
    exit 1
    ;;
esac

echo ""
info "🌍 Nhập domain/subdomain cho n8n (ví dụ: n8n.example.com)"
read -rp "👉 Domain: " N8N_DOMAIN_INPUT

N8N_DOMAIN="${N8N_DOMAIN_INPUT:-$N8N_HOST}"

if [ -z "$N8N_DOMAIN" ]; then
  error "❌ Domain không được để trống (WEBHOOK_URL của n8n phụ thuộc vào giá trị này)."
  exit 1
fi

# Giu nguyen secret cua lan cai truoc neu co; lan dau thi sinh ngau nhien.
# Khong dung mat khau mac dinh cho DB.
DB_PASSWORD="${DB_POSTGRESDB_PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)}"
ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)}"

if [ -f "$ENV_FILE" ]; then
  info "🔐 Đã tìm thấy .env cũ — giữ nguyên N8N_ENCRYPTION_KEY và mật khẩu Postgres."
  warn "   (Đổi encryption key sẽ làm mất toàn bộ credential đã lưu trong n8n.)"
fi

echo ""
info "📁 Tạo cấu trúc thư mục n8n..."
mkdir -p "$N8N_DIR"/n8n_data "$N8N_DIR"/postgres "$N8N_DIR"/redis
chown -R 1000:1000 "$N8N_DIR/n8n_data"
chown -R 999:999 "$N8N_DIR/postgres" "$N8N_DIR/redis"

info "🌐 Kiểm tra Docker network proxy..."
if docker network inspect proxy >/dev/null 2>&1; then
  success "✅ Network proxy đã tồn tại."
else
  docker network create --driver bridge --attachable proxy
  success "✅ Đã tạo network proxy."
fi

echo ""
info "📝 Tạo file .env..."
cat > "$ENV_FILE" <<EOF
N8N_HOST=$N8N_DOMAIN
N8N_PROTOCOL=https
N8N_PORT=5678
WEBHOOK_URL=https://$N8N_DOMAIN/
N8N_EDITOR_BASE_URL=https://$N8N_DOMAIN/
GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
EXECUTIONS_MODE=queue
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=168
N8N_PROXY_HOPS=1
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=$DB_PASSWORD
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
N8N_ENCRYPTION_KEY=$ENCRYPTION_KEY
EOF
chmod 600 "$ENV_FILE"

echo ""
info "📝 Tạo docker-compose.yml..."
cat > "$N8N_DIR/docker-compose.yml" <<'EOF'
services:
  postgres:
    image: postgres:15
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_POSTGRESDB_USER}
      POSTGRES_PASSWORD: ${DB_POSTGRESDB_PASSWORD}
      POSTGRES_DB: ${DB_POSTGRESDB_DATABASE}
    volumes:
      - ./postgres:/var/lib/postgresql/data
    networks:
      - n8n

  redis:
    image: redis:7
    container_name: n8n-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - ./redis:/data
    networks:
      - n8n

  n8n-main:
    image: n8nio/n8n:latest
    container_name: n8n-main
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      - postgres
      - redis
    volumes:
      - ./n8n_data:/home/node/.n8n
    networks:
      - proxy
      - n8n

  n8n-worker1:
    image: n8nio/n8n:latest
    container_name: n8n-worker1
    command: worker
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      - postgres
      - redis
    volumes:
      - ./n8n_data:/home/node/.n8n
    networks:
      - n8n

  n8n-worker2:
    image: n8nio/n8n:latest
    container_name: n8n-worker2
    command: worker
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      - postgres
      - redis
    volumes:
      - ./n8n_data:/home/node/.n8n
    networks:
      - n8n

  n8n-worker3:
    image: n8nio/n8n:latest
    container_name: n8n-worker3
    command: worker
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      - postgres
      - redis
    volumes:
      - ./n8n_data:/home/node/.n8n
    networks:
      - n8n

  n8n-worker4:
    image: n8nio/n8n:latest
    container_name: n8n-worker4
    command: worker
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      - postgres
      - redis
    volumes:
      - ./n8n_data:/home/node/.n8n
    networks:
      - n8n

networks:
  proxy:
    external: true
    name: proxy
  n8n:
    driver: bridge
EOF

echo ""
info "🚀 Khởi động n8n stack..."
cd "$N8N_DIR"
docker compose up -d

echo ""
info "🔎 Kiểm tra trạng thái stack..."
docker compose ps

echo ""
configure_ufw

echo ""
info "⚙️ Thêm alias và command update..."
add_aliases "$TARGET_BASHRC"
add_aliases "/root/.bashrc"
create_update_commands
success "✅ Đã tạo command: n8n-update, update-n8n"

echo ""
success "✅ CÀI ĐẶT N8N HOÀN TẤT"
echo ""
info "🌐 URL: https://$N8N_DOMAIN"
info "📁 Thư mục chứa compose: $N8N_DIR"
info "📁 n8n_data: $N8N_DIR/n8n_data"
info "📁 postgres: $N8N_DIR/postgres"
info "📁 redis: $N8N_DIR/redis"
echo ""
warn "🔐 $ENV_FILE chứa N8N_ENCRYPTION_KEY và mật khẩu Postgres (chmod 600)."
warn "   Hãy backup file này — mất encryption key là mất toàn bộ credential trong n8n."
echo ""

if [ "$PROXY_MODE" = "cloudflare" ]; then
  info "📌 CẤU HÌNH CLOUDFLARE TUNNEL"
  echo ""
  warn "1️⃣ Cho container cloudflared vào chung network proxy:"
  cat <<'EOF'
services:
  cloudflared:
    # ...
    networks:
      - proxy

networks:
  proxy:
    external: true
    name: proxy
EOF
  echo ""
  echo "Rồi chạy lại: docker compose up -d"
  echo ""
  warn "2️⃣ Zero Trust -> Networks -> Tunnels -> Public Hostname -> Add:"
  echo "   Domain : $N8N_DOMAIN"
  echo "   Type   : HTTP"
  echo "   URL    : n8n-main:5678"
  echo ""
  warn "3️⃣ Lưu ý: Cloudflare free giới hạn body upload ~100MB."
  echo "   Workflow xử lý file lớn hơn mức này nên đi qua reverse proxy khác."
else
  info "📌 HƯỚNG DẪN CONFIG NGINX PROXY MANAGER"
  echo ""
  warn "1️⃣ Add Proxy Host"
  echo "   Domain Names : $N8N_DOMAIN"
  echo "   Scheme       : http"
  echo "   Forward Host : n8n-main"
  echo "   Forward Port : 5678"
  warn "2️⃣ Bật Websockets Support"
  warn "3️⃣ Bật Block Common Exploits"
  warn "4️⃣ SSL: Request a new SSL Certificate, bật Force SSL và HTTP/2"
  warn "5️⃣ Nếu dùng Cloudflare proxy (orange cloud), nên dùng DNS challenge hoặc"
  echo "   chuyển DNS sang DNS-only khi xin cert lần đầu"
fi

echo ""
info "💡 Commands update:"
echo "n8n-update"
echo "update-n8n"
echo ""
warn "ℹ️ Alias sẽ có hiệu lực ở phiên shell mới tiếp theo."

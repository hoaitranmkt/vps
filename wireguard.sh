#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

COMPOSE_DIR="/root/wireguard"
INFO_FILE="$COMPOSE_DIR/install.info"
WG_IMAGE="ghcr.io/wg-easy/wg-easy:14"

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

is_udp_port_in_use() {
  local port="$1"
  ss -lun 2>/dev/null | tail -n +2 | awk '{print $4}' | grep -Eq "[:.]$port$"
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

ensure_proxy_network() {
  info "🌐 Kiểm tra Docker network proxy..."
  if docker network inspect proxy >/dev/null 2>&1; then
    success "✅ Network proxy đã tồn tại."
  else
    docker network create --driver bridge --attachable proxy
    success "✅ Đã tạo network proxy."
  fi
}

write_compose_file() {
  local ports_block="    ports:
      - \"51820:51820/udp\""
  local service_net_block=""
  local top_net_block=""

  if [ -n "$UI_PORT_MAPPING" ]; then
    ports_block="$ports_block
      - \"$UI_PORT_MAPPING\""
  fi

  if [ "$USE_PROXY_NETWORK" = "yes" ]; then
    service_net_block="    networks:
      - proxy
"
    top_net_block="
networks:
  proxy:
    external: true
    name: proxy
"
  fi

  cat > "$COMPOSE_DIR/docker-compose.yml" <<EOF
services:
  wg-easy:
    image: $WG_IMAGE
    container_name: wg-easy
    restart: unless-stopped
    environment:
      - LANG=en
      - WG_HOST=$WG_ENDPOINT
      - PORT=51821
      - HOST=0.0.0.0
      - PASSWORD_HASH=${PASSWORD_HASH_ESCAPED}
      - WG_PORT=51820
      - WG_DEFAULT_ADDRESS=10.0.0.x
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_ALLOWED_IPS=10.0.0.0/24
      - WG_PERSISTENT_KEEPALIVE=25
      - WG_MTU=1380
      - UI_TRAFFIC_STATS=true
    volumes:
      - ./config:/etc/wireguard
$ports_block
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
$service_net_block$top_net_block
EOF
}

create_update_commands() {
  cat > /usr/local/bin/wireguard-update <<'EOF'
#!/bin/bash
set -e

COMPOSE_DIR="/root/wireguard"

if [[ $EUID -ne 0 ]]; then
  exec sudo /usr/local/bin/wireguard-update "$@"
fi

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  echo "Missing $COMPOSE_DIR/docker-compose.yml. Run the install script again first."
  exit 1
fi

cd "$COMPOSE_DIR"

if grep -q 'name: proxy' docker-compose.yml; then
  docker network inspect proxy >/dev/null 2>&1 || docker network create --driver bridge --attachable proxy
fi

docker compose pull
docker compose up -d
docker compose ps
EOF

  cat > /usr/local/bin/update-wireguard <<'EOF'
#!/bin/bash
set -e
exec /usr/local/bin/wireguard-update "$@"
EOF

  chmod +x /usr/local/bin/wireguard-update /usr/local/bin/update-wireguard
}

add_aliases() {
  local target_file="$1"
  touch "$target_file"

  grep -q '^alias wireguard-update=' "$target_file" || echo 'alias wireguard-update="/usr/local/bin/wireguard-update"' >> "$target_file"
  grep -q '^alias update-wireguard=' "$target_file" || echo 'alias update-wireguard="/usr/local/bin/update-wireguard"' >> "$target_file"
}

configure_ufw() {
  local ssh_ports
  ssh_ports="$(detect_ssh_ports)"

  info "🔥 Cấu hình firewall (UFW)..."
  info "   Port SSH phát hiện được: $(echo $ssh_ports | tr '\n' ' ')"

  if ! command -v ufw >/dev/null 2>&1; then
    warn "⚠️ UFW chưa được cài, bỏ qua bước firewall."
    warn "   Hãy tự mở port 51820/udp trên firewall của nhà cung cấp VPS."
    return
  fi

  local ufw_active="no"
  ufw status 2>/dev/null | head -n1 | grep -q 'Status: active' && ufw_active="yes"

  if [ "$ufw_active" = "no" ]; then
    warn "⚠️ UFW hiện đang TẮT."
    warn "   Bật UFW sẽ chặn mọi port inbound không nằm trong danh sách allow."
    warn "   Các service khác đang chạy trực tiếp trên host (không qua Docker) có thể bị chặn."
    echo ""
    read -rp "Bạn có muốn bật UFW không? (y/N): " ENABLE_UFW

    if [[ "$ENABLE_UFW" != "y" && "$ENABLE_UFW" != "Y" ]]; then
      warn "ℹ️ Bỏ qua UFW. Hãy đảm bảo port 51820/udp được mở ở firewall của nhà cung cấp VPS."
      return
    fi
  fi

  local p
  for p in $ssh_ports; do
    ufw allow "$p/tcp" >/dev/null
    success "   ✅ Allow SSH $p/tcp"
  done

  ufw allow 51820/udp >/dev/null
  success "   ✅ Allow 51820/udp (WireGuard)"

  if [ "$PROXY_MODE" = "npm" ]; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    success "   ✅ Allow 80/tcp, 443/tcp (Nginx Proxy Manager)"
    warn "   ⚠️ KHÔNG mở port 81 (trang admin NPM) ra internet. Hãy vào qua SSH tunnel:"
    warn "      ssh -L 81:127.0.0.1:81 root@<IP-VPS>"
  fi

  if [ "$ufw_active" = "no" ]; then
    ufw --force enable
    success "   ✅ Đã bật UFW."
  else
    success "   ✅ UFW đang bật sẵn, chỉ thêm rule mới (không reset cấu hình cũ)."
  fi

  ufw reload >/dev/null
}

success "✅ Bắt đầu cài đặt WireGuard + wg-easy..."

if [[ $EUID -ne 0 ]]; then
  error "❌ Vui lòng chạy script với quyền root (sudo)."
  exit 1
fi

info "📦 Cài đặt gói phụ thuộc..."
apt update
apt install -y ca-certificates curl gnupg lsb-release ufw dnsutils iproute2

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

info "✅ Enable IP Forward..."
cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl --system >/dev/null
success "✅ Đã bật IP forwarding."

echo ""
info "🔀 Chọn cách truy cập giao diện quản trị wg-easy (port 51821):"
echo ""
echo "  1) Cloudflare Tunnel - cloudflared chạy bằng Docker   (khuyến nghị)"
echo "  2) Cloudflare Tunnel - cloudflared chạy trên host/systemd"
echo "  3) Nginx Proxy Manager (container tên nginx-proxy-manager)"
echo "  4) Không dùng reverse proxy - chỉ truy cập qua SSH tunnel"
echo ""
read -rp "👉 Lựa chọn [1-4] (mặc định 1): " PROXY_CHOICE
PROXY_CHOICE="${PROXY_CHOICE:-1}"

UI_PORT_MAPPING=""
USE_PROXY_NETWORK="no"
UI_DOMAIN=""

case "$PROXY_CHOICE" in
  1)
    PROXY_MODE="cf-docker"
    USE_PROXY_NETWORK="yes"
    ;;
  2)
    PROXY_MODE="cf-host"
    UI_PORT_MAPPING="127.0.0.1:51821:51821"
    ;;
  3)
    PROXY_MODE="npm"
    USE_PROXY_NETWORK="yes"
    ;;
  4)
    PROXY_MODE="none"
    UI_PORT_MAPPING="127.0.0.1:51821:51821"
    ;;
  *)
    error "❌ Lựa chọn không hợp lệ: $PROXY_CHOICE"
    exit 1
    ;;
esac

echo ""
info "🌍 Endpoint VPN (WG_HOST) - địa chỉ mà client WireGuard kết nối tới qua UDP 51820."
warn "   Đây PHẢI là IP public của VPS, hoặc domain có A record trỏ thẳng IP VPS."
warn "   Nếu dùng Cloudflare: bản ghi này phải để DNS-only (mây XÁM)."
warn "   Domain đang proxy qua Cloudflare (mây cam) sẽ KHÔNG bắt tay WireGuard được."
echo ""
info "🔍 Đang lấy IP public..."
PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org || true)"

if [ -n "$PUBLIC_IP" ]; then
  success "   IP public của VPS: $PUBLIC_IP"
else
  warn "   Không lấy được IP public tự động."
fi

echo ""
read -rp "👉 WG_HOST (domain hoặc IP, Enter để dùng $PUBLIC_IP): " WG_ENDPOINT
WG_ENDPOINT="${WG_ENDPOINT:-$PUBLIC_IP}"

if [ -z "$WG_ENDPOINT" ]; then
  error "❌ WG_HOST không được để trống."
  exit 1
fi

if [[ "$WG_ENDPOINT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  info "ℹ️ WG_HOST là IP, bỏ qua bước kiểm tra DNS."
else
  info "🔍 Kiểm tra DNS cho $WG_ENDPOINT..."
  DOMAIN_IP="$(dig +short A "$WG_ENDPOINT" | grep -E '^[0-9.]+$' | tail -n1)"

  if [ -z "$DOMAIN_IP" ]; then
    warn "⚠️ Không resolve được A record cho $WG_ENDPOINT."
  elif [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
    warn "⚠️ Domain KHÔNG trỏ về IP VPS."
    warn "   Domain IP : $DOMAIN_IP"
    warn "   Server IP : $PUBLIC_IP"
    warn "   Nguyên nhân thường gặp: domain đang bật proxy Cloudflare (mây cam)."
    warn "   Cloudflare Tunnel/Proxy KHÔNG chuyển tiếp được UDP của WireGuard."
    warn "   → Hãy dùng một hostname riêng, để DNS-only, trỏ A record về $PUBLIC_IP."
    echo ""
    read -rp "Vẫn tiếp tục? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      exit 1
    fi
  else
    success "✅ Domain đã trỏ đúng IP VPS."
  fi
fi

if [ "$PROXY_MODE" != "none" ]; then
  echo ""
  info "🌐 Domain dùng để vào giao diện quản trị wg-easy."
  warn "   Nên là hostname KHÁC với WG_HOST ở trên."
  read -rp "👉 Domain UI (có thể bỏ trống): " UI_DOMAIN
fi

echo ""
info "🔑 Nhập password đăng nhập wg-easy"
read -rsp "👉 Password: " WG_PASSWORD
echo ""

if [ -z "$WG_PASSWORD" ]; then
  error "❌ Password không được để trống."
  exit 1
fi

echo ""
info "🔐 Tạo PASSWORD_HASH..."
PASSWORD_HASH_RAW="$(docker run --rm "$WG_IMAGE" wgpw "$WG_PASSWORD" | tr -d '\r')"
PASSWORD_HASH_VALUE="$(printf '%s' "$PASSWORD_HASH_RAW" | sed -E "s/^PASSWORD_HASH=//; s/^'//; s/'$//; s/^\"//; s/\"$//")"

if [[ "$PASSWORD_HASH_VALUE" != \$2* ]]; then
  error "❌ Không tạo được password hash hợp lệ. Output: $PASSWORD_HASH_RAW"
  exit 1
fi

# Trong docker-compose.yml, ky tu $ phai viet thanh $$ de Compose khong hieu nham la bien.
PASSWORD_HASH_ESCAPED="$(printf '%s' "$PASSWORD_HASH_VALUE" | sed 's/\$/$$/g')"
success "✅ Đã tạo password hash."

info "🔎 Kiểm tra port 51820/udp..."
if is_udp_port_in_use 51820; then
  error "❌ Port 51820/udp đang được sử dụng. Hãy giải phóng port này trước khi deploy wg-easy."
  exit 1
fi
success "✅ Port 51820/udp sẵn sàng."

if [ -n "$UI_PORT_MAPPING" ] && is_tcp_port_in_use 51821; then
  error "❌ Port 51821/tcp đang được sử dụng."
  exit 1
fi

echo ""
info "📁 Tạo thư mục chứa docker-compose của WireGuard..."
mkdir -p "$COMPOSE_DIR"
cd "$COMPOSE_DIR"

if [ "$USE_PROXY_NETWORK" = "yes" ]; then
  ensure_proxy_network
fi

info "📦 Tạo docker-compose.yml..."
write_compose_file

cat > "$INFO_FILE" <<EOF
WG_HOST=$WG_ENDPOINT
UI_DOMAIN=$UI_DOMAIN
PROXY_MODE=$PROXY_MODE
INSTALLED_AT=$(date -Is)
EOF
chmod 600 "$INFO_FILE"

info "🚀 Khởi động wg-easy..."
docker compose pull
docker compose up -d

sleep 5

info "📊 Trạng thái stack:"
docker compose ps

info "📊 WG-EASY LOG:"
docker logs --tail=20 wg-easy || true

configure_ufw

if docker ps --format '{{.Names}}' | grep -qw wg-easy; then
  success "✅ wg-easy đang hoạt động."
else
  error "❌ wg-easy không chạy. Xem log: docker logs wg-easy"
  exit 1
fi

info "⚙️ Thêm alias và command update..."
add_aliases "$TARGET_BASHRC"
add_aliases "/root/.bashrc"
create_update_commands
success "✅ Đã tạo command: wireguard-update, update-wireguard"

echo ""
success "✅ INSTALL HOÀN TẤT"
echo ""
info "🔐 VPN endpoint (dùng trong file config client):"
echo "$WG_ENDPOINT:51820/udp"
echo ""

case "$PROXY_MODE" in
  cf-docker)
    info "📌 CẤU HÌNH CLOUDFLARE TUNNEL (cloudflared chạy Docker)"
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
    echo "Subdomain/Domain : ${UI_DOMAIN:-<domain UI của bạn>}"
    echo "Type             : HTTP"
    echo "URL              : wg-easy:51821"
    echo ""
    warn "3️⃣ Khuyến nghị: bọc thêm Cloudflare Access cho hostname này"
    echo "   để trang login wg-easy không lộ ra internet."
    ;;
  cf-host)
    info "📌 CẤU HÌNH CLOUDFLARE TUNNEL (cloudflared chạy host/systemd)"
    echo ""
    warn "1️⃣ Zero Trust -> Networks -> Tunnels -> Public Hostname -> Add:"
    echo "Subdomain/Domain : ${UI_DOMAIN:-<domain UI của bạn>}"
    echo "Type             : HTTP"
    echo "URL              : 127.0.0.1:51821"
    echo ""
    warn "Hoặc trong ~/.cloudflared/config.yml:"
    cat <<EOF
ingress:
  - hostname: ${UI_DOMAIN:-wg.example.com}
    service: http://127.0.0.1:51821
  - service: http_status:404
EOF
    echo ""
    echo "Rồi: systemctl restart cloudflared"
    ;;
  npm)
    info "📌 CẤU HÌNH NGINX PROXY MANAGER"
    echo ""
    warn "1️⃣ Đăng nhập NPM qua SSH tunnel (đừng mở port 81 ra internet):"
    echo "ssh -L 81:127.0.0.1:81 root@$PUBLIC_IP"
    echo "-> mở http://127.0.0.1:81"
    echo ""
    warn "2️⃣ Proxy Hosts -> Add Proxy Host"
    echo ""
    warn "Details:"
    echo "Domain Names : ${UI_DOMAIN:-<domain UI của bạn>}"
    echo "Scheme       : http"
    echo "Forward Host : wg-easy"
    echo "Forward Port : 51821"
    echo ""
    warn "SSL:"
    echo "- Request a new SSL Certificate"
    echo "- Force SSL"
    echo "- HTTP/2 Support"
    echo "- Websockets Support"
    echo ""
    warn "Advanced:"
    cat <<'EOF'
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";

proxy_http_version 1.1;

proxy_buffering off;
client_max_body_size 0;
EOF
    ;;
  none)
    info "📌 TRUY CẬP GIAO DIỆN QUẢN TRỊ QUA SSH TUNNEL"
    echo ""
    echo "ssh -L 51821:127.0.0.1:51821 root@$PUBLIC_IP"
    echo "-> mở http://127.0.0.1:51821"
    echo ""
    warn "UI chỉ lắng nghe trên 127.0.0.1 nên không lộ ra internet."
    ;;
esac

echo ""
info "📌 Kiểm tra:"
echo "docker logs -f wg-easy"
if [ "$USE_PROXY_NETWORK" = "yes" ]; then
  echo "docker network inspect proxy"
fi
echo ""
info "💡 Commands:"
echo "wireguard-update"
echo "update-wireguard"
echo ""
warn "ℹ️ Alias sẽ có hiệu lực ở phiên shell mới tiếp theo."

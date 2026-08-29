#!/bin/bash

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
NODE_SOURCE_VERSION='24.x'

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

success "🌿 Bắt đầu cài đặt hoặc cập nhật Node.js LTS..."

if [[ $EUID -ne 0 ]]; then
    error "❌ Vui lòng chạy script với quyền root (sudo)."
    exit 1
fi

info "📦 Cài đặt gói phụ thuộc..."
apt update
apt install -y ca-certificates curl gnupg lsb-release

if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    error "❌ Không thể xác định hệ điều hành."
    exit 1
fi

if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
    error "❌ Script chỉ hỗ trợ Ubuntu và Debian. Hệ hiện tại: $OS_ID"
    exit 1
fi

if command -v node >/dev/null 2>&1; then
    warn "🔄 Node.js đã tồn tại (phiên bản hiện tại: $(node -v)), tiến hành cập nhật LTS..."
else
    info "📦 Node.js chưa được cài, tiến hành cài đặt LTS..."
fi

info "🔑 Thiết lập NodeSource repository..."
install -m 0755 -d /usr/share/keyrings

rm -f /usr/share/keyrings/nodesource.gpg || true
rm -f /etc/apt/sources.list.d/nodesource.list || true
rm -f /etc/apt/sources.list.d/nodesource.sources || true

curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
chmod 644 /usr/share/keyrings/nodesource.gpg

ARCHITECTURE="$(dpkg --print-architecture)"

cat > /etc/apt/sources.list.d/nodesource.sources <<EOF
Types: deb
URIs: https://deb.nodesource.com/node_$NODE_SOURCE_VERSION
Suites: nodistro
Components: main
Architectures: $ARCHITECTURE
Signed-By: /usr/share/keyrings/nodesource.gpg
EOF

apt update
apt install -y nodejs

info "🔎 Kiểm tra Node.js..."
if node --version >/dev/null 2>&1; then
    INSTALLED_NODE_VERSION="$(node --version)"
    success "✅ Node.js đã sẵn sàng: $INSTALLED_NODE_VERSION"
else
    error "❌ Node.js không hoạt động sau khi cài đặt."
    exit 1
fi

info "🔎 Kiểm tra npm..."
if npm --version >/dev/null 2>&1; then
    NPM_VERSION="$(npm --version)"
    success "✅ npm đã sẵn sàng: v$NPM_VERSION"
else
    error "❌ npm không hoạt động sau khi cài đặt Node.js."
    exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
if [ "$TARGET_USER" = "root" ]; then
    TARGET_BASHRC="/root/.bashrc"
else
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    TARGET_BASHRC="$TARGET_HOME/.bashrc"
fi

add_aliases() {
    local target_file="$1"
    touch "$target_file"

    grep -q '^alias update-nodejs=' "$target_file" || echo 'alias update-nodejs="/usr/local/bin/update-nodejs"' >> "$target_file"
    grep -q '^alias nodejs-update=' "$target_file" || echo 'alias nodejs-update="/usr/local/bin/nodejs-update"' >> "$target_file"
}

create_update_commands() {
    # Ghi cung phien ban NodeSource dang dung o lan cai nay, tranh lech giua
    # script cai va script update.
    cat > /usr/local/bin/update-nodejs <<EOF
#!/bin/bash
set -e

NODE_SOURCE_VERSION='$NODE_SOURCE_VERSION'
EOF

    cat >> /usr/local/bin/update-nodejs <<'EOF'

if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

$SUDO apt install -y ca-certificates curl gnupg
$SUDO install -m 0755 -d /usr/share/keyrings
$SUDO rm -f /usr/share/keyrings/nodesource.gpg /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/nodesource.sources || true
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | $SUDO gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
$SUDO chmod 644 /usr/share/keyrings/nodesource.gpg
ARCHITECTURE="$($SUDO dpkg --print-architecture)"
cat <<NODEJS_EOF | $SUDO tee /etc/apt/sources.list.d/nodesource.sources > /dev/null
Types: deb
URIs: https://deb.nodesource.com/node_$NODE_SOURCE_VERSION
Suites: nodistro
Components: main
Architectures: $ARCHITECTURE
Signed-By: /usr/share/keyrings/nodesource.gpg
NODEJS_EOF
$SUDO apt update
$SUDO apt install -y nodejs
node -v
npm -v
EOF

    cat > /usr/local/bin/nodejs-update <<'EOF'
#!/bin/bash
set -e
exec /usr/local/bin/update-nodejs "$@"
EOF

    chmod +x /usr/local/bin/update-nodejs /usr/local/bin/nodejs-update
}

info "⚙️ Thêm alias và command update..."
add_aliases "$TARGET_BASHRC"
add_aliases "/root/.bashrc"
create_update_commands
success "✅ Đã tạo command: update-nodejs, nodejs-update"

warn "ℹ️ Alias sẽ có hiệu lực ở phiên shell mới tiếp theo."

echo ""
success "✅ Hoàn tất cài đặt Node.js LTS."
info "💡 NodeSource LTS: $NODE_SOURCE_VERSION | Node hiện tại: $INSTALLED_NODE_VERSION | npm: v$NPM_VERSION"
info "💡 Command đã thêm: update-nodejs, nodejs-update"

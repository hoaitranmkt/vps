#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${GREEN}🔧 Chuẩn bị hệ thống...${NC}"
sudo apt update
sudo apt install -y curl ca-certificates jq dnsutils ufw nginx certbot python3-certbot-nginx

echo -e "${GREEN}🌍 Nhập domain dành cho NetBird (ví dụ: vpn.example.com):${NC}"
read -rp "👉 Domain: " NB_DOMAIN
if [[ -z "${NB_DOMAIN}" ]]; then echo -e "${RED}❌ Domain không được để trống.${NC}"; exit 1; fi

echo -e "${GREEN}🔎 Kiểm tra DNS của domain...${NC}"
PUBLIC_IP=$(curl -s https://api.ipify.org || true)
DOMAIN_IP=$(dig +short A "$NB_DOMAIN" | tail -n1)

if [[ -z "$PUBLIC_IP" ]]; then
  echo -e "${RED}❌ Không lấy được IP public của máy. Kiểm tra kết nối mạng.${NC}"; exit 1
fi

if [[ -z "$DOMAIN_IP" ]]; then
  echo -e "${RED}❌ Domain chưa có bản ghi A (IPv4). Hãy trỏ ${NB_DOMAIN} về IP ${PUBLIC_IP}.${NC}"
  read -rp "⏸ Vẫn tiếp tục cài? (y/N): " confirm; [[ "${confirm:-N}" =~ ^[Yy]$ ]] || exit 1
else
  echo -e "${GREEN}ℹ️ Server IP: ${PUBLIC_IP}${NC}"
  echo -e "${GREEN}ℹ️ Domain IP: ${DOMAIN_IP}${NC}"
  if [[ "$PUBLIC_IP" != "$DOMAIN_IP" ]]; then
    echo -e "${YELLOW}⚠️ Domain ${NB_DOMAIN} CHƯA trỏ đúng IP server.${NC}"
    read -rp "⏸ Vẫn tiếp tục cài? (y/N): " confirm; [[ "${confirm:-N}" =~ ^[Yy]$ ]] || exit 1
  else
    echo -e "${GREEN}✅ Domain đã trỏ đúng IP.${NC}"
  fi
fi

echo -e "${GREEN}🧱 Mở firewall cần thiết (Nginx & TURN)...${NC}"

# Doc port SSH that thay vi hardcode "OpenSSH" (=22): bat UFW ma chi mo 22
# trong khi sshd nghe port khac se lam mat ket noi SSH.
SSH_PORTS="$(sudo sshd -T 2>/dev/null | awk '/^port /{print $2}' || true)"
if [[ -z "${SSH_PORTS}" ]]; then
  SSH_PORTS="$(ss -ltnp 2>/dev/null | grep -i sshd | awk '{print $4}' | sed 's/.*[:.]//' | sort -u || true)"
fi
if [[ -z "${SSH_PORTS}" ]]; then
  SSH_PORTS="22"
fi
echo -e "${GREEN}ℹ️ Port SSH phát hiện được: $(echo ${SSH_PORTS} | tr '\n' ' ')${NC}"

UFW_ACTIVE="no"
if sudo ufw status 2>/dev/null | head -n1 | grep -q 'Status: active'; then
  UFW_ACTIVE="yes"
fi

RUN_UFW="yes"
if [[ "${UFW_ACTIVE}" == "no" ]]; then
  echo -e "${YELLOW}⚠️ UFW đang TẮT. Bật lên sẽ chặn mọi port inbound không nằm trong danh sách allow,${NC}"
  echo -e "${YELLOW}   các service khác đang chạy trên host có thể bị chặn.${NC}"
  read -rp "⏸ Bật UFW và mở port cho NetBird? (y/N): " confirm_ufw
  [[ "${confirm_ufw:-N}" =~ ^[Yy]$ ]] || RUN_UFW="no"
fi

if [[ "${RUN_UFW}" == "yes" ]]; then
  for p in ${SSH_PORTS}; do
    sudo ufw allow "${p}/tcp" || true
  done
  sudo ufw allow 80/tcp || true
  sudo ufw allow 443/tcp || true
  sudo ufw allow 3478/udp || true
  sudo ufw allow 49152:65535/udp || true

  if [[ "${UFW_ACTIVE}" == "no" ]]; then
    sudo ufw --force enable || true
  else
    echo -e "${GREEN}✅ UFW đang bật sẵn, chỉ thêm rule mới.${NC}"
  fi
else
  echo -e "${YELLOW}ℹ️ Bỏ qua UFW. Hãy tự mở 80/tcp, 443/tcp, 3478/udp, 49152-65535/udp ở firewall nhà cung cấp VPS.${NC}"
fi

echo -e "${GREEN}🐳 Kiểm tra/Cài Docker & Compose...${NC}"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sudo bash
  sudo usermod -aG docker "$USER" || true
  echo -e "${YELLOW}ℹ️ Docker vừa cài xong; có thể cần logout/login để dùng docker không sudo.${NC}"
fi
if ! docker compose version &>/dev/null; then
  mkdir -p ~/.docker/cli-plugins
  curl -sSL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 \
    -o ~/.docker/cli-plugins/docker-compose
  chmod +x ~/.docker/cli-plugins/docker-compose
fi
echo -e "${GREEN}✅ Docker & Compose sẵn sàng.${NC}"

echo -e "${GREEN}📁 Tạo thư mục triển khai: /opt/netbird${NC}"
sudo mkdir -p /opt/netbird
sudo chown "$USER":"$USER" /opt/netbird
cd /opt/netbird

echo -e "${GREEN}🚀 Triển khai quickstart NetBird (Zitadel IdP)...${NC}"
export NETBIRD_DOMAIN="${NB_DOMAIN}"
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started-with-zitadel.sh | bash

echo -e "${GREEN}🧩 Publish cổng nội bộ để Nginx reverse proxy...${NC}"
cat > docker-compose.override.yml <<'YAML'
services:
  dashboard:
    ports:
      - "127.0.0.1:8080:80"
  management:
    ports:
      - "127.0.0.1:33073:33073"
  signal:
    ports:
      - "127.0.0.1:10000:10000"
YAML

echo -e "${GREEN}🔄 Khởi động lại NetBird stack...${NC}"
docker compose down
docker compose up -d
sleep 3
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo -e "${GREEN}🛠 Tạo Nginx server block cho ${NB_DOMAIN}...${NC}"
NGINX_CONF="/etc/nginx/sites-available/netbird-${NB_DOMAIN}.conf"
sudo tee "$NGINX_CONF" >/dev/null <<EOF
server {
    listen 80;
    server_name ${NB_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name ${NB_DOMAIN};
    client_max_body_size 50m;

    # SSL do Certbot cài đặt
    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_pass http://127.0.0.1:8080;
    }

    location ^~ /api {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_pass http://127.0.0.1:33073;
    }

    location ^~ /management.ManagementService/ {
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Host \$host;
        grpc_read_timeout 300s;
        grpc_pass grpc://127.0.0.1:33073;
    }

    location ^~ /signalexchange.SignalExchange/ {
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Host \$host;
        grpc_read_timeout 300s;
        grpc_pass grpc://127.0.0.1:10000;
    }
}
EOF

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

echo -e "${GREEN}🔐 Cấp SSL Let's Encrypt (Certbot) cho ${NB_DOMAIN}...${NC}"
sudo certbot --nginx -d "${NB_DOMAIN}" --non-interactive --agree-tos -m admin@"${NB_DOMAIN}" || \
  echo -e "${YELLOW}⚠️ Certbot chưa cấp được chứng chỉ. Kiểm tra DNS/port 80.${NC}"

echo -e "${GREEN}⚙️ Thêm alias cập nhật NetBird...${NC}"
cat <<'EOF' >> ~/.bashrc

# Alias cập nhật NetBird (agent & self-host stack)
alias update-netbird='bash -c "
echo \"📥 Cập nhật NetBird agent...\"
curl -fsSL https://get.netbird.io | bash
echo \"📦 Cập nhật stack self-host (Docker Compose)...\"
cd /opt/netbird || exit 1
docker compose pull
docker compose up -d
echo \"✅ NetBird đã được cập nhật!\"
"'
alias netbird-update='update-netbird'
EOF
[ "$EUID" -eq 0 ] && source ~/.bashrc || true

echo -e "${GREEN}🎉 Hoàn tất triển khai NetBird self-host qua Nginx!${NC}"
echo -e "${GREEN}🔗 Dashboard: https://${NB_DOMAIN}${NC}"
echo -e "${GREEN}ℹ️ Thêm node: 'netbird up --management-url https://${NB_DOMAIN}'${NC}"
echo -e "${GREEN}🔄 Cập nhật: 'update-netbird' hoặc 'netbird-update'${NC}"

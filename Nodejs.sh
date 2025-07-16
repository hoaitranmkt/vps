#!/bin/bash

# nodejs.sh - Script cài đặt hoặc cập nhật Node.js LTS mới nhất trên Ubuntu, kèm alias

set -e

# Màu sắc thông báo
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}🌿 Bắt đầu kiểm tra Node.js...${NC}"

# Kiểm tra Node.js đã cài chưa
if command -v node >/dev/null 2>&1; then
    CURRENT_VERSION=$(node -v)
    echo -e "${GREEN}✅ Node.js đã được cài đặt (phiên bản: $CURRENT_VERSION)${NC}"
    echo -e "${YELLOW}🔄 Đang tiến hành cập nhật lên phiên bản LTS mới nhất...${NC}"
else
    echo -e "${YELLOW}❌ Node.js chưa được cài đặt. Đang tiến hành cài đặt...${NC}"
fi

# Gỡ bản cũ (nếu có)
sudo apt remove -y nodejs || true

# Cài bản LTS mới nhất
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs

# Kiểm tra lại phiên bản
NEW_VERSION=$(node -v)
echo -e "${GREEN}🎉 Node.js đã được cài đặt/cập nhật lên phiên bản: $NEW_VERSION${NC}"

# Kiểm tra npm
if command -v npm >/dev/null 2>&1; then
    echo -e "${GREEN}✅ npm đã sẵn sàng (phiên bản: $(npm -v))${NC}"
else
    echo -e "${YELLOW}⚠️ npm chưa được cài, đang tiến hành cài đặt...${NC}"
    sudo apt install -y npm
fi

# Thêm alias vào ~/.bashrc nếu chưa có
ALIAS_CONTENT=$(cat <<EOF
# Alias update Node.js
alias update-nodejs="bash ~/nodejs.sh"
alias nodejs-update="bash ~/nodejs.sh"
EOF
)

if ! grep -q "alias update-nodejs=" ~/.bashrc; then
    echo -e "${YELLOW}➕ Đang thêm alias vào ~/.bashrc...${NC}"
    echo "$ALIAS_CONTENT" >> ~/.bashrc
    echo -e "${GREEN}✅ Đã thêm alias: update-nodejs, nodejs-update${NC}"
    echo -e "${YELLOW}⚠️ Hãy chạy 'source ~/.bashrc' hoặc mở terminal mới để dùng alias.${NC}"
else
    echo -e "${GREEN}✅ Alias đã tồn tại trong ~/.bashrc${NC}"
fi

echo -e "${GREEN}✅ Hoàn tất.${NC}"

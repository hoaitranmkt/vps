#!/bin/bash

# nodejs.sh - Script cài đặt hoặc cập nhật Node.js LTS mới nhất trên Ubuntu

set -e

# Màu sắc thông báo
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🚀 Bắt đầu kiểm tra Node.js...${NC}"

# Kiểm tra Node.js đã cài chưa
if command -v node >/dev/null 2>&1; then
    CURRENT_VERSION=$(node -v)
    echo -e "${GREEN}✅ Node.js đã được cài đặt (phiên bản: $CURRENT_VERSION)${NC}"
    echo -e "${YELLOW}🔄 Đang tiến hành cập nhật lên phiên bản LTS mới nhất...${NC}"
else
    echo -e "${YELLOW}❌ Node.js chưa được cài đặt. Đang tiến hành cài đặt...${NC}"
fi

# Gỡ bỏ bản Node.js cũ nếu có (không bắt buộc, nhưng nên làm sạch)
sudo apt remove -y nodejs || true

# Cài đặt Node.js LTS mới nhất
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs

# Kiểm tra lại phiên bản sau khi cài xong
NEW_VERSION=$(node -v)
echo -e "${GREEN}🎉 Node.js đã được cài đặt/cập nhật lên phiên bản: $NEW_VERSION${NC}"

# Kiểm tra npm
if command -v npm >/dev/null 2>&1; then
    echo -e "${GREEN}✅ npm đã sẵn sàng (phiên bản: $(npm -v))${NC}"
else
    echo -e "${YELLOW}⚠️ npm không được cài đặt kèm. Đang cài thêm...${NC}"
    sudo apt install -y npm
fi

echo -e "${GREEN}✅ Hoàn tất.${NC}"

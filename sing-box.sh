#!/bin/bash

# =================配置区域=================
# 二进制文件安装路径
TARGET_PATH="/usr/local/bin/sing-box"
# Systemd 服务名称
SERVICE_NAME="sing-box"
# GitHub 仓库
REPO="SagerNet/sing-box"
# ntfy 推送地址
NTFY_URL="https://ntfy.sh/flyzstu"
# 临时下载目录
TEMP_DIR="/tmp/singbox_update"
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}===> 开始 Sing-box 更新检测程序...${NC}"

# 1. 获取 GitHub 最新版本
echo -e "正在联网检查 GitHub 最新版本..."
# 获取 tag_name (例如 v1.12.14)
LATEST_TAG=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo -e "${RED}错误：无法获取 GitHub 版本信息，请检查网络。${NC}"
    exit 1
fi

# 去除 'v' 前缀
REMOTE_VERSION=${LATEST_TAG#v}

# 2. 获取本地版本并对比
LOCAL_VERSION=""
if [ -f "$TARGET_PATH" ]; then
    # 执行 version 命令，提取版本号
    LOCAL_VERSION=$("$TARGET_PATH" version 2>/dev/null | grep "sing-box version" | awk '{print $3}' | tr -d '\r')
fi

echo -e "远程版本: ${GREEN}$REMOTE_VERSION${NC}"
echo -e "本地版本: ${YELLOW}${LOCAL_VERSION:-未安装}${NC}"

# ===> 核心判断逻辑 <===
if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
    echo -e "${GREEN}当前已是最新版本，无需更新。${NC}"
    exit 0
fi

echo -e "${BLUE}发现新版本，准备开始更新...${NC}"

# 3. 检测系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64) FILE_ARCH="amd64" ;;
    aarch64) FILE_ARCH="arm64" ;;
    armv7l) FILE_ARCH="armv7" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 4. 下载文件
FILE_NAME="sing-box-${REMOTE_VERSION}-linux-${FILE_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/${LATEST_TAG}/${FILE_NAME}"

mkdir -p "$TEMP_DIR"
echo -e "正在下载: ${YELLOW}$DOWNLOAD_URL${NC}"
curl -L -o "$TEMP_DIR/$FILE_NAME" "$DOWNLOAD_URL" --progress-bar

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败！${NC}"; rm -rf "$TEMP_DIR"; exit 1
fi

# 5. 解压并安装
echo -e "正在安装到 ${YELLOW}$TARGET_PATH${NC} ..."
tar -xzf "$TEMP_DIR/$FILE_NAME" -C "$TEMP_DIR"
EXTRACTED_FOLDER="sing-box-${REMOTE_VERSION}-linux-${FILE_ARCH}"
BINARY_SOURCE="$TEMP_DIR/$EXTRACTED_FOLDER/sing-box"

if [ ! -f "$BINARY_SOURCE" ]; then
    echo -e "${RED}错误：解压失败，未找到二进制文件。${NC}"; rm -rf "$TEMP_DIR"; exit 1
fi

# 直接覆盖文件 (Systemd 重启时会加载新文件)
# 为了保险，先停止服务可以防止极少数情况下的 "Text file busy"
systemctl stop "$SERVICE_NAME" >/dev/null 2>&1

mv "$BINARY_SOURCE" "$TARGET_PATH"
chmod +x "$TARGET_PATH"
rm -rf "$TEMP_DIR"

echo -e "${GREEN}文件覆盖完成。${NC}"

# 6. 重启服务 (Systemd)
echo -e "${YELLOW}正在重启服务 (systemctl restart $SERVICE_NAME)...${NC}"
systemctl restart "$SERVICE_NAME"

# 7. 检查状态并推送通知
if [ $? -eq 0 ]; then
    # 等待几秒让服务完全启动
    sleep 3

    # 检查服务运行状态 (active)
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}更新成功！正在推送通知...${NC}"

        # 获取公网 IP
        PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org)
        [ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me)
        [ -z "$PUBLIC_IP" ] && PUBLIC_IP="未知IP"

        # 推送消息
        MESSAGE="✅ Sing-box 自动更新成功
版本: $REMOTE_VERSION
IP: $PUBLIC_IP"

        curl -s \
          -d "$MESSAGE" \
          -H "Title: Sing-box 更新通知" \
          -H "Tags: white_check_mark,server" \
          "$NTFY_URL"

        echo -e "通知已发送。"
    else
        echo -e "${RED}警告：重启命令执行成功，但服务状态不是 active。${NC}"
        # 尝试获取 systemctl status 的最后几行日志作为错误信息
        LOGS=$(systemctl status "$SERVICE_NAME" --no-pager | tail -n 3)
        curl -s -d "⚠️ Sing-box 更新后启动失败。
日志: $LOGS" -H "Title: 更新异常" -H "Tags: warning" "$NTFY_URL"
    fi
else
    echo -e "${RED}服务重启失败！${NC}"
    curl -s -d "❌ Sing-box systemctl restart 失败" -H "Title: 更新失败" -H "Tags: x" "$NTFY_URL"
fi

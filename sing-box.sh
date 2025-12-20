#!/bin/bash

# sing-box 一键安装最新二进制版脚本（2025 年 12 月）
# 功能：
#   - 自动检测系统架构
#   - 从 GitHub Releases 下载最新稳定版 sing-box 二进制
#   - 创建专用系统用户 singbox（无登录权限）
#   - 创建目录 /etc/sing-box 和 /var/lib/sing-box
#   - 放置二进制到 /usr/local/bin/sing-box
#   - 生成示例 config.json（空模板，用户需自行修改）
#   - 生成 systemd 服务单元文件 sing-box.service
#   - 设置正确权限（配置目录仅 root 可读写，运行目录归 singbox 用户）
#   - 启用并启动服务

set -e

echo "=================================================="
echo "sing-box 一键安装最新二进制版"
echo "=================================================="

# 需要 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "请使用 sudo 或 root 用户运行此脚本！"
   exit 1
fi

# 获取最新版本（稳定版，非 pre-release）
echo "正在获取最新版本信息..."
LATEST_TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)
if [ -z "$LATEST_TAG" ]; then
    echo "获取版本失败，请检查网络！"
    exit 1
fi
echo "最新版本：$LATEST_TAG"

# 检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)     GOARCH="amd64" ;;
    aarch64)    GOARCH="arm64" ;;
    armv7l)     GOARCH="armv7" ;;
    i386|i686)  GOARCH="386" ;;
    *)          echo "不支持的架构：$ARCH"; exit 1 ;;
esac

OS="linux"
FILE="sing-box-${LATEST_TAG}-${OS}-${GOARCH}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/${FILE}"

# 创建专用用户
echo "创建 singbox 系统用户..."
if ! id "singbox" &>/dev/null; then
    useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/sing-box singbox
fi

# 创建目录
mkdir -p /etc/sing-box /var/lib/sing-box
chown root:root /etc/sing-box
chmod 755 /etc/sing-box
chown singbox:singbox /var/lib/sing-box
chmod 700 /var/lib/sing-box

# 下载并安装二进制
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
echo "正在下载 $FILE ..."
curl -L -o "$FILE" "$URL"

tar -xzf "$FILE"
BINARY_DIR=$(find . -type d -name "sing-box-*")
cp "$BINARY_DIR/sing-box" /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box

# 清理临时文件
cd /
rm -rf "$TEMP_DIR"

# 生成示例配置文件（空模板，用户需自行编辑）
if [ ! -f /etc/sing-box/config.json ]; then
    cat > /etc/sing-box/config.json << 'EOF'
{
  "log": {
    "level": "info"
  },
  "inbounds": [],
  "outbounds": []
}
EOF
    chown root:root /etc/sing-box/config.json
    chmod 600 /etc/sing-box/config.json
    echo "已生成示例配置文件 /etc/sing-box/config.json（请自行编辑）"
fi

# 生成 systemd 服务单元
cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=singbox
Group=singbox
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd 并启用服务
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box

echo "=================================================="
echo "sing-box 安装完成！"
echo ""
echo "版本：$(/usr/local/bin/sing-box version)"
echo "配置文件：/etc/sing-box/config.json（请编辑后重启服务）"
echo "运行目录：/var/lib/sing-box"
echo ""
echo "服务管理命令："
echo "  systemctl status sing-box"
echo "  systemctl restart sing-box"
echo "  systemctl stop sing-box"
echo ""
echo "注意：请尽快编辑 /etc/sing-box/config.json 并重启服务："
echo "  systemctl restart sing-box"
echo "=================================================="
#!/bin/bash

# sing-box 一键安装最新二进制版脚本（带自动检测，避免重复操作）
# 2025 年 12 月

set -e

echo "=================================================="
echo "sing-box 一键安装最新二进制版（智能检测，避免重复）"
echo "=================================================="

# 需要 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "请使用 sudo 或 root 用户运行此脚本！"
   exit 1
fi

# 获取最新版本
echo "正在获取最新版本信息..."
LATEST_TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)
if [ -z "$LATEST_TAG" ]; then
    echo "获取版本失败，请检查网络！"
    exit 1
fi
echo "GitHub 最新版本：$LATEST_TAG"

# 检查本地是否已安装 sing-box 并比较版本
CURRENT_VERSION=""
if command -v sing-box >/dev/null 2>&1; then
    CURRENT_VERSION=$(sing-box version | grep "sing-box version" | awk '{print $3}')
    echo "本地已安装版本：$CURRENT_VERSION"

    # 版本比较（去除 v 前缀）
    LOCAL=$(echo $CURRENT_VERSION | sed 's/^v//')
    REMOTE=$(echo $LATEST_TAG | sed 's/^v//')

    if [[ "$LOCAL" == "$REMOTE" ]]; then
        echo "本地版本已是最新（$LATEST_TAG），跳过下载二进制。"
        SKIP_DOWNLOAD=true
    else
        echo "本地版本 $CURRENT_VERSION 低于最新 $LATEST_TAG，将更新二进制。"
        SKIP_DOWNLOAD=false
    fi
else
    echo "未检测到 sing-box，准备安装最新版。"
    SKIP_DOWNLOAD=false
fi

# 检测架构
if [ "$SKIP_DOWNLOAD" != true ]; then
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

    # 下载并安装二进制
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    echo "正在下载 $FILE ..."
    curl -L -o "$FILE" "$URL"

    tar -xzf "$FILE"
    BINARY_DIR=$(find . -type d -name "sing-box-*")
    cp "$BINARY_DIR/sing-box" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box

    cd /
    rm -rf "$TEMP_DIR"
    echo "sing-box 二进制已更新到最新版 $LATEST_TAG"
fi

# 创建专用用户（如果不存在）
if ! id "singbox" &>/dev/null; then
    echo "创建 singbox 系统用户..."
    useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/sing-box singbox
else
    echo "singbox 用户已存在，跳过创建。"
fi

# 创建并设置目录权限
mkdir -p /etc/sing-box /var/lib/sing-box
chown root:root /etc/sing-box
chmod 755 /etc/sing-box
chown singbox:singbox /var/lib/sing-box
chmod 700 /var/lib/sing-box
echo "目录权限设置完成"

# 生成示例配置文件（仅当不存在时）
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
    echo "已生成示例配置文件 /etc/sing-box/config.json"
else
    echo "配置文件 /etc/sing-box/config.json 已存在，跳过生成（不会覆盖）"
fi

# 生成 systemd 服务单元（仅当不存在时）
if [ ! -f /etc/systemd/system/sing-box.service ]; then
    echo "创建 systemd 服务单元..."
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
else
    echo "systemd 服务单元已存在，跳过创建。"
fi

# 重新加载 systemd 并管理服务
systemctl daemon-reload

if systemctl is-enabled sing-box >/dev/null 2>&1; then
    echo "sing-box 服务已启用开机自启。"
else
    echo "启用 sing-box 开机自启..."
    systemctl enable sing-box
fi

# 重启服务以应用更新
echo "重启 sing-box 服务..."
systemctl restart sing-box

echo "=================================================="
echo "sing-box 安装/更新完成！"
echo ""
echo "当前版本：$(/usr/local/bin/sing-box version | grep "sing-box version" | awk '{print $3}')"
echo "配置文件：/etc/sing-box/config.json（请根据需要编辑）"
echo "运行目录：/var/lib/sing-box"
echo ""
echo "服务管理命令："
echo "  systemctl status sing-box"
echo "  systemctl restart sing-box"
echo "  systemctl stop/start sing-box"
echo ""
echo "提示：如需更新，以后再次运行此脚本即可自动检测并更新。"
echo "=================================================="
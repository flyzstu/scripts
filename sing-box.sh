#!/bin/bash

set -e

echo "=================================================="
echo "sing-box 一键安装最新二进制版（支持 Base64 编码 Token）"
echo "=================================================="

if [[ $EUID -ne 0 ]]; then
   echo "请使用 sudo 或 root 运行！"
   exit 1
fi

SINGBOX_TOKEN_B64="Z2l0aHViX3BhdF8xMUFXT01XUFkwak43MEVDT0lBbXN0X2NXN3lEdWF2amRIYlVGdENjd2ZmMHFET2NLSEo5cURKN3JXWVkxS2R2VExGVzZDQkdYWE54a1BXeld2"
if [ -n "$SINGBOX_TOKEN_B64" ]; then
    echo "检测到 Base64 编码的 Token，正在解码..."
    GITHUB_TOKEN=$(echo "$SINGBOX_TOKEN_B64" | base64 -d 2>/dev/null || echo "$SINGBOX_TOKEN_B64" | base64 --decode 2>/dev/null)
    if [[ "$GITHUB_TOKEN" =~ ^ghp_ || "$GITHUB_TOKEN" =~ ^github_pat_ ]]; then
        echo "Token 解码成功，将使用认证下载（避免 GitHub 限速）"
    else
        echo "警告：解码后的 Token 格式不正确，仍将尝试使用"
    fi
elif [ -n "$GITHUB_TOKEN" ]; then
    echo "检测到明文 GITHUB_TOKEN，将直接使用（不推荐长期使用）"
    # 兼容旧方式
else
    echo "警告：未提供 Token（SINGBOX_TOKEN_B64 或 GITHUB_TOKEN）"
    echo "      将使用匿名下载，容易被 GitHub 限速"
    echo "      建议：export SINGBOX_TOKEN_B64=\"\$(echo -n 'ghp_xxx' | base64)\""
    sleep 3
fi

# 获取最新版本
LATEST_TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)
VERSION=${LATEST_TAG#v}
echo "最新版本：$LATEST_TAG (纯版本: $VERSION)"

# 版本检查
CURRENT_VERSION=""
if command -v sing-box >/dev/null 2>&1; then
    CURRENT_VERSION=$(sing-box version | grep "sing-box version" | awk '{print $3}')
    LOCAL=$(echo $CURRENT_VERSION | sed 's/^v//')
    if [[ "$LOCAL" == "$VERSION" ]]; then
        echo "已是最新版 $LATEST_TAG，跳过下载。"
        SKIP_DOWNLOAD=true
    else
        echo "本地 $CURRENT_VERSION < 最新 $LATEST_TAG，将更新。"
    fi
else
    echo "未安装 sing-box，将安装最新版。"
fi

if [ "$SKIP_DOWNLOAD" != true ]; then
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [[ "$OS" == "darwin" ]]; then
        OS="darwin"
    elif [[ "$OS" == "linux" ]]; then
        OS="linux"
    else
        echo "不支持的系统：$OS"
        exit 1
    fi

    ARCH=$(uname -m)
    case $ARCH in
        x86_64)     GOARCH="amd64" ;;
        aarch64|arm64) GOARCH="arm64" ;;
        armv7l)     GOARCH="armv7" ;;
        i386|i686)  GOARCH="386" ;;
        *)          echo "不支持的架构：$ARCH"; exit 1 ;;
    esac

    FILE="sing-box-${VERSION}-${OS}-${GOARCH}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/${FILE}"

    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"

    echo "正在下载：$FILE"
    if [ -n "$GITHUB_TOKEN" ]; then
        curl -L -f -o "$FILE" \
          -H "Authorization: Bearer $GITHUB_TOKEN" \
          -H "Accept: application/octet-stream" \
          -H "User-Agent: Mozilla/5.0" \
          "$URL" || {
            echo "下载失败！Token 可能无效或无权限"
            exit 1
        }
    else
        curl -L -f -o "$FILE" \
          -H "User-Agent: Mozilla/5.0" \
          "$URL" || {
            echo "下载失败！匿名下载可能被限速"
            exit 1
        }
    fi

    SIZE=$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE")
    if [ "$SIZE" -lt 5000000 ]; then
        echo "下载文件异常小（$SIZE 字节），失败！"
        exit 1
    fi

    tar -xzf "$FILE"
    BINARY_DIR=$(find . -mindepth 1 -maxdepth 1 -type d -name "sing-box-*")
    sudo cp "$BINARY_DIR/sing-box" /usr/local/bin/sing-box
    sudo chmod +x /usr/local/bin/sing-box

    cd /
    rm -rf "$TEMP_DIR"
    echo "sing-box 二进制更新完成（$LATEST_TAG）"
fi

# 创建专用系统用户 sing-box
if ! id "sing-box" &>/dev/null; then
    echo "创建 sing-box 系统用户..."
    useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/sing-box sing-box
else
    echo "sing-box 用户已存在，跳过创建。"
fi

# 目录权限
mkdir -p /etc/sing-box /var/lib/sing-box
chown root:root /etc/sing-box
chmod 755 /etc/sing-box
chown sing-box:sing-box /var/lib/sing-box
chmod 700 /var/lib/sing-box

# 示例配置
if [ ! -f /etc/sing-box/config.json ]; then
    cat > /etc/sing-box/config.json << 'EOF'
{
  "log": {"level": "info"},
  "inbounds": [],
  "outbounds": []
}
EOF
    chown root:root /etc/sing-box/config.json
    chmod 600 /etc/sing-box/config.json
    echo "已生成示例配置文件"
else
    echo "配置文件已存在，跳过生成"
fi

# systemd 服务
if [ ! -f /etc/systemd/system/sing-box.service ]; then
    cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=sing-box
Group=sing-box
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    echo "systemd 服务创建完成"
else
    echo "systemd 服务已存在"
fi

systemctl daemon-reload
systemctl enable --now sing-box
systemctl restart sing-box

echo "=================================================="
echo "sing-box 安装/更新完成！"
echo "当前版本：$(/usr/local/bin/sing-box version | grep "sing-box version" | awk '{print $3}')"
echo "请编辑 /etc/sing-box/config.json 后执行：systemctl restart sing-box"
echo "=================================================="
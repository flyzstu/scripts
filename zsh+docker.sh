#!/bin/bash

set -e

echo "=================================================="
echo "一键配置 zsh + Oh My Zsh + 自动补全插件 + Docker"
echo "并在终端提示符前显示当前公网 IP"
echo "=================================================="

# 检测包管理器
if command -v apt >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    INSTALL_CMD="apt install -y"
    UPDATE_CMD="apt update"
elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    INSTALL_CMD="yum install -y"
    UPDATE_CMD="yum makecache"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
    UPDATE_CMD="dnf makecache"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="pacman -S --noconfirm"
    UPDATE_CMD="pacman -Sy"
else
    echo "不支持的系统包管理器！"
    exit 1
fi

# 1. 安装 zsh 和 git
echo "[1/6] 正在安装 zsh 和 git..."
if [ "$PKG_MANAGER" = "apt" ]; then
    $UPDATE_CMD
    $INSTALL_CMD zsh git curl wget
elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
    $UPDATE_CMD
    $INSTALL_CMD zsh git curl wget
elif [ "$PKG_MANAGER" = "pacman" ]; then
    $UPDATE_CMD
    $INSTALL_CMD zsh git curl wget
fi

# 2. 安装 Oh My Zsh
echo "[2/6] 正在安装 Oh My Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended
else
    echo "Oh My Zsh 已存在，跳过。"
fi

# 3. 安装自动补全插件
echo "[3/6] 正在安装 zsh-autosuggestions 和 zsh-syntax-highlighting..."
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
fi
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
fi

# 4. 配置 .zshrc（含 IP 显示）
echo "[4/6] 正在配置 .zshrc..."
ZSHRC="$HOME/.zshrc"
if [ -f "$ZSHRC" ]; then
    cp "$ZSHRC" "${ZSHRC}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "已备份原 .zshrc"
fi

cat > "$ZSHRC" << 'EOF'
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    docker
    sudo
    extract
)

source $ZSH/oh-my-zsh.sh

# 在命令执行前显示当前公网 IP（仅在新会话或未显示时）
precmd_show_ip() {
    [[ -o interactive ]] || return
    if [[ "$LAST_IP_SHOWN" != "$PROMPT" ]]; then
        echo -n "当前公网 IP: "
        IP=$(curl -s --connect-timeout 3 https://api.ipify.org 2>/dev/null || \
             curl -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || \
             curl -s --connect-timeout 3 https://ipinfo.io/ip 2>/dev/null || \
             echo "获取失败")
        echo "$IP"
        LAST_IP_SHOWN="$PROMPT"
    fi
}
precmd_functions+=(precmd_show_ip)
EOF

# 5. 安装 Docker
echo "[5/6] 正在安装 Docker..."
if command -v docker >/dev/null 2>&1; then
    echo "Docker 已安装，跳过。"
else
    if [ "$PKG_MANAGER" = "apt" ]; then
        $UPDATE_CMD
        $INSTALL_CMD ca-certificates curl gnupg lsb-release
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        $UPDATE_CMD
        $INSTALL_CMD docker-ce docker-ce-cli containerd.io docker-compose-plugin
    elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
        $INSTALL_CMD yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        $INSTALL_CMD docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif [ "$PKG_MANAGER" = "pacman" ]; then
        $INSTALL_CMD docker
    fi
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
fi

echo "=================================================="
echo "全部完成！"
echo ""
echo "已完成以下操作："
echo "  • zsh + Oh My Zsh + 补全插件"
echo "  • Docker 安装并免 sudo"
echo "  • 终端每次打开将显示当前公网 IP"
echo ""
echo "请执行： exec zsh   或重启终端"
echo "=================================================="
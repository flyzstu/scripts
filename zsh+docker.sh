#!/usr/bin/env bash

set -Eeuo pipefail

SSHD_DROPIN="/etc/ssh/sshd_config.d/99-disable-password-login.conf"
OH_MY_ZSH_INSTALL_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

die() {
    echo "错误：$*" >&2
    exit 1
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        die "请使用 sudo 或 root 运行：sudo bash $0"
    fi
}

detect_target_user() {
    TARGET_USER="${SUDO_USER:-${USER:-root}}"
    if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
        TARGET_USER="root"
        TARGET_HOME="/root"
    else
        TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
        [[ -n "${TARGET_HOME}" ]] || die "无法获取用户 ${TARGET_USER} 的 home 目录"
    fi
}

run_as_target_user() {
    if [[ "${TARGET_USER}" == "root" ]]; then
        HOME="${TARGET_HOME}" bash -lc "$*"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -H -u "${TARGET_USER}" bash -lc "$*"
    else
        su - "${TARGET_USER}" -c "$*"
    fi
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    else
        die "不支持的系统包管理器（需要 apt、dnf、yum 或 pacman）"
    fi
}

pkg_update() {
    case "${PKG_MANAGER}" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update ;;
        dnf) dnf makecache -y ;;
        yum) yum makecache -y ;;
        pacman) pacman -Sy --noconfirm ;;
    esac
}

pkg_install() {
    case "${PKG_MANAGER}" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
    esac
}

install_base_packages() {
    log "[1/7] 安装基础软件：git、zsh、curl、wget"
    pkg_update
    case "${PKG_MANAGER}" in
        apt) pkg_install git zsh curl wget ca-certificates gnupg lsb-release ;;
        dnf|yum) pkg_install git zsh curl wget ca-certificates ;;
        pacman) pkg_install git zsh curl wget ca-certificates ;;
    esac
}

configure_sshd_password_login() {
    log "[2/7] 配置 sshd：禁用密码登录"

    local main_conf="/etc/ssh/sshd_config"
    install -d -m 755 /etc/ssh/sshd_config.d
    if [[ -f "${main_conf}" ]] && ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${main_conf}"; then
        local tmp_conf
        tmp_conf="$(mktemp)"
        cp "${main_conf}" "${main_conf}.backup.$(date +%Y%m%d_%H%M%S)"
        {
            echo "Include /etc/ssh/sshd_config.d/*.conf"
            cat "${main_conf}"
        } > "${tmp_conf}"
        cat "${tmp_conf}" > "${main_conf}"
        rm -f "${tmp_conf}"
    fi

    if [[ -f "${SSHD_DROPIN}" ]]; then
        cp "${SSHD_DROPIN}" "${SSHD_DROPIN}.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    cat > "${SSHD_DROPIN}" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
EOF
    chmod 644 "${SSHD_DROPIN}"

    if command -v sshd >/dev/null 2>&1; then
        sshd -t
    else
        log "未找到 sshd 命令，已写入配置，跳过语法检查和服务重载。"
        return
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files sshd.service >/dev/null 2>&1; then
            systemctl reload sshd || systemctl restart sshd
        elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then
            systemctl reload ssh || systemctl restart ssh
        else
            log "未找到 sshd/ssh systemd 服务，已写入配置，跳过服务重载。"
        fi
    elif command -v service >/dev/null 2>&1; then
        service sshd reload 2>/dev/null || service ssh reload 2>/dev/null || log "无法自动重载 sshd，请手动重启服务。"
    else
        log "未找到服务管理器，请手动重启 sshd。"
    fi
}

install_oh_my_zsh() {
    log "[3/7] 安装 Oh My Zsh 到 ${TARGET_HOME}"

    if [[ -d "${TARGET_HOME}/.oh-my-zsh" ]]; then
        log "Oh My Zsh 已存在，跳过。"
        return
    fi

    run_as_target_user "RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \"\$(curl -fsSL ${OH_MY_ZSH_INSTALL_URL})\" -- --unattended"
}

clone_or_update_plugin() {
    local repo="$1"
    local dir="$2"

    if [[ -d "${dir}/.git" ]]; then
        run_as_target_user "git -C '${dir}' pull --ff-only"
    elif [[ -d "${dir}" ]]; then
        log "${dir} 已存在但不是 git 仓库，跳过。"
    else
        run_as_target_user "git clone --depth=1 '${repo}' '${dir}'"
    fi
}

install_zsh_plugins() {
    log "[4/7] 安装常见 Oh My Zsh 插件"

    local custom_dir="${TARGET_HOME}/.oh-my-zsh/custom"
    local plugin_dir="${custom_dir}/plugins"
    install -d -m 755 -o "${TARGET_USER}" -g "$(id -gn "${TARGET_USER}")" "${plugin_dir}"

    clone_or_update_plugin "https://github.com/zsh-users/zsh-autosuggestions.git" "${plugin_dir}/zsh-autosuggestions"
    clone_or_update_plugin "https://github.com/zsh-users/zsh-syntax-highlighting.git" "${plugin_dir}/zsh-syntax-highlighting"
    clone_or_update_plugin "https://github.com/zsh-users/zsh-completions.git" "${plugin_dir}/zsh-completions"
    clone_or_update_plugin "https://github.com/zsh-users/zsh-history-substring-search.git" "${plugin_dir}/zsh-history-substring-search"
    clone_or_update_plugin "https://github.com/MichaelAquilina/zsh-you-should-use.git" "${plugin_dir}/you-should-use"
}

write_zshrc() {
    log "[5/7] 写入 ${TARGET_HOME}/.zshrc"

    local zshrc="${TARGET_HOME}/.zshrc"
    if [[ -f "${zshrc}" ]]; then
        cp "${zshrc}" "${zshrc}.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    cat > "${zshrc}" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

plugins=(
  git
  docker
  docker-compose
  sudo
  extract
  colored-man-pages
  command-not-found
  zsh-completions
  zsh-autosuggestions
  zsh-history-substring-search
  you-should-use
  zsh-syntax-highlighting
)

source "$ZSH/oh-my-zsh.sh"

autoload -U compinit && compinit
EOF

    chown "${TARGET_USER}:$(id -gn "${TARGET_USER}")" "${zshrc}"
    chmod 644 "${zshrc}"
}

install_docker() {
    log "[6/7] 安装 Docker"

    if command -v docker >/dev/null 2>&1; then
        log "Docker 已安装，跳过安装。"
    else
        case "${PKG_MANAGER}" in
            apt)
                install -d -m 0755 /etc/apt/keyrings
                . /etc/os-release
                local docker_id="${ID}"
                local docker_codename="${VERSION_CODENAME:-}"
                if [[ "${ID}" != "ubuntu" && "${ID}" != "debian" ]]; then
                    die "Docker 官方 apt 仓库仅在此脚本中支持 Debian/Ubuntu，当前系统为 ${ID}"
                fi
                if [[ -z "${docker_codename}" ]] && command -v lsb_release >/dev/null 2>&1; then
                    docker_codename="$(lsb_release -cs)"
                fi
                [[ -n "${docker_codename}" ]] || die "无法识别 Debian/Ubuntu 发行版代号"
                curl -fsSL "https://download.docker.com/linux/${docker_id}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                chmod a+r /etc/apt/keyrings/docker.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_id} ${docker_codename} stable" > /etc/apt/sources.list.d/docker.list
                pkg_update
                pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            dnf)
                pkg_install dnf-plugins-core
                dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            yum)
                pkg_install yum-utils
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            pacman)
                pkg_install docker docker-compose
                ;;
        esac
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    else
        log "未找到 systemctl，请手动启动 Docker 服务。"
    fi

    if getent group docker >/dev/null 2>&1 && [[ "${TARGET_USER}" != "root" ]]; then
        usermod -aG docker "${TARGET_USER}"
    fi
}

set_default_shell() {
    log "[7/7] 设置 ${TARGET_USER} 默认 shell 为 zsh"

    local zsh_path
    zsh_path="$(command -v zsh)"
    if ! grep -qxF "${zsh_path}" /etc/shells; then
        echo "${zsh_path}" >> /etc/shells
    fi

    local current_shell
    current_shell="$(getent passwd "${TARGET_USER}" | cut -d: -f7)"
    if [[ "${current_shell}" == "${zsh_path}" ]]; then
        log "默认 shell 已是 zsh，跳过。"
    else
        chsh -s "${zsh_path}" "${TARGET_USER}"
    fi
}

main() {
    echo "=================================================="
    echo "一键配置 SSHD + Git + Zsh + Oh My Zsh + Docker"
    echo "=================================================="

    require_root
    detect_target_user
    detect_pkg_manager

    log "目标用户：${TARGET_USER} (${TARGET_HOME})"
    log "包管理器：${PKG_MANAGER}"

    install_base_packages
    configure_sshd_password_login
    install_oh_my_zsh
    install_zsh_plugins
    write_zshrc
    install_docker
    set_default_shell

    echo "=================================================="
    echo "全部完成。"
    echo "已禁用 sshd 密码登录；请确认 SSH key 登录可用后再断开当前会话。"
    echo "Docker 免 sudo 需要重新登录或执行：newgrp docker"
    echo "Zsh 立即生效可执行：exec zsh"
    echo "=================================================="
}

main "$@"

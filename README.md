# Scripts

常用服务器初始化脚本集合。

## Zsh + Docker 初始化

一键安装并配置：

- 禁用 `sshd` 密码登录
- `git`
- `zsh`
- Oh My Zsh
- 常见 Oh My Zsh 插件
- Docker 和 Docker Compose 插件
- 将当前 sudo 用户加入 `docker` 组
- 将默认 shell 切换为 `zsh`

### 快速安装

```bash
curl -fsSL https://tinyurl.com/flyzstuzsh | sudo bash
```

或：

```bash
wget -qO- https://tinyurl.com/flyzstuzsh | sudo bash
```

### 注意事项

运行前请确保服务器已经配置好 SSH key 登录。脚本会禁用 SSH 密码登录：

```sshconfig
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
```

脚本完成后，Docker 免 sudo 通常需要重新登录后生效，也可以临时执行：

```bash
newgrp docker
```

Zsh 可立即切换：

```bash
exec zsh
```

## Sing-box

仓库同时包含 `sing-box.sh`，用于安装或更新 sing-box 二进制和 systemd 服务。


# Docker 镜像自动更新作业

这个 Ansible playbook 会在目标机器上安装一个 systemd timer，定时用 Watchtower 检查并更新 Docker 镜像和容器。

默认行为：

- 每天运行一次
- 只运行一次后退出，不常驻
- 有新镜像时自动拉取并重建对应容器
- 更新成功后清理旧镜像

## 使用

复制 inventory 示例：

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
```

编辑 `ansible/inventory.ini` 后执行：

```bash
ansible-playbook -i ansible/inventory.ini ansible/docker-auto-update.yml
```

## 常用变量

```yaml
watchtower_schedule: daily
watchtower_cleanup: true
watchtower_label_enable: false
watchtower_timeout: 300s
```

如果只想更新带标签的容器：

```bash
ansible-playbook -i ansible/inventory.ini ansible/docker-auto-update.yml -e watchtower_label_enable=true
```

然后给需要自动更新的容器加标签：

```bash
docker run -d \
  --label com.centurylinklabs.watchtower.enable=true \
  nginx:latest
```

## 手动触发

```bash
sudo systemctl start docker-image-auto-update.service
```

查看定时器：

```bash
systemctl list-timers docker-image-auto-update.timer
```

## 开启内核 TCP Brutal

执行：

```bash
ansible-playbook -i ansible/inventory.ini ansible/brutal-kernel.yml
```

这个 playbook 会在目标机上执行：

```bash
bash <(curl -fsSL https://tcp.hy2.sh/)
```

默认检测到 `brutal` 已经存在时会跳过安装。强制重新执行安装脚本：

```bash
ansible-playbook -i ansible/inventory.ini ansible/brutal-kernel.yml -e brutal_force_install=true
```

如果要把 Brutal 设置为系统默认 TCP 拥塞控制：

```bash
ansible-playbook -i ansible/inventory.ini ansible/brutal-kernel.yml -e brutal_set_default=true
```

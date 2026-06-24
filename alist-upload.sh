#!/usr/bin/env bash

# 使用方式：
#   source ./alist-upload.sh
#   ALIST_TOKEN="你的 token" alist_upload "./example.zip" "/backup/example.zip"

set -euo pipefail

BACKUP_DIR="/backup/etcd"
LOG_FILE="/var/log/etcd-backup.log"
DATE=$(date +"%Y%m%d-%H%M%S")
SNAPSHOT="${BACKUP_DIR}/etcd-snapshot-${DATE}.db"

: "${ALIST_TOKEN:?请通过环境变量设置 ALIST_TOKEN}"


mkdir -p $BACKUP_DIR

# 只保留最近 14 天的备份
find "${BACKUP_DIR}" -type f -name '*.db' -mtime +14 -delete

echo "===================================" >> $LOG_FILE
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting etcd backup..." >> $LOG_FILE

ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/k0s/pki/etcd/ca.crt \
  --cert=/var/lib/k0s/pki/etcd/server.crt \
  --key=/var/lib/k0s/pki/etcd/server.key \
  snapshot save "${SNAPSHOT}"

# 验证快照完整性
etcdutl snapshot status "${SNAPSHOT}" >> $LOG_FILE

echo "$(date '+%Y-%m-%d %H:%M:%S') - Backup success: ${SNAPSHOT}" >> $LOG_FILE



alist_upload() {
  local alist_url="https://pan.fly97.fun:8443"
  local local_file=${1:-}
  local remote_path=${2:-}
  local file_name file_size encoded_path char hex i

  if [[ -z "$local_file" ]]; then
    echo "用法: ALIST_TOKEN=<token> alist_upload <本地文件> [AList 目标路径]" >&2
    return 2
  fi

  if [[ -z "${ALIST_TOKEN:-}" ]]; then
    echo "错误: 未设置 ALIST_TOKEN。" >&2
    return 2
  fi

  if [[ ! -f "$local_file" ]]; then
    echo "错误: 文件不存在或不是普通文件: $local_file" >&2
    return 2
  fi

  file_name=${local_file##*/}
  remote_path=${remote_path:-"/$file_name"}

  if [[ "$remote_path" == */ ]]; then
    remote_path="${remote_path}${file_name}"
  elif [[ "$remote_path" != /* ]]; then
    remote_path="/$remote_path"
  fi

  # AList 要求 File-Path 是经过 URL 编码的完整目标路径。
  encoded_path=""
  LC_ALL=C
  for ((i = 0; i < ${#remote_path}; i++)); do
    char=${remote_path:i:1}
    case "$char" in
      [a-zA-Z0-9.~_-])
        encoded_path+="$char"
        ;;
      *)
        printf -v hex '%02X' "'$char"
        encoded_path+="%$hex"
        ;;
    esac
  done

  file_size=$(wc -c < "$local_file")
  file_size=${file_size//[[:space:]]/}

  curl --fail-with-body --show-error \
    --connect-timeout 15 \
    --max-time 1800 \
    --request PUT \
    --url "${alist_url%/}/api/fs/put" \
    --header "Authorization: $ALIST_TOKEN" \
    --header "File-Path: $encoded_path" \
    --header "As-Task: true" \
    --header "Content-Type: application/octet-stream" \
    --header "Content-Length: $file_size" \
    --data-binary "@$local_file"
}


alist_upload "$SNAPSHOT" "/onedrive/Backup/K0s/etcd/"

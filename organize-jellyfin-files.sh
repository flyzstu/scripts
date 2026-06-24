#!/usr/bin/env bash

set -euo pipefail

# 默认整理当前目录，也可以将目标目录作为第一个参数传入。
root_dir=${1:-.}

if [[ ! -d "$root_dir" ]]; then
  echo "错误: 目录不存在: $root_dir" >&2
  exit 2
fi

declare -a source_files=()
declare -a target_dirs=()
declare -a target_files=()
declare -a conflicts=()

while IFS= read -r -d '' source_file; do
  file_name=${source_file##*/}

  # 匹配 SNOS-206、SNOS-206-C、SNOS-206-UC 等编号。
  if [[ "$file_name" =~ ([[:alpha:]]{2,10}-[[:digit:]]{2,6}(-(UC|C))?) ]]; then
    video_code=${BASH_REMATCH[1]}
    video_code=$(printf '%s' "$video_code" | tr '[:lower:]' '[:upper:]')
    target_dir="${root_dir%/}/${video_code}"
    target_file="${target_dir}/${file_name}"

    if [[ -e "$target_file" ]]; then
      conflicts+=("$target_file")
      continue
    fi

    source_files+=("$source_file")
    target_dirs+=("$target_dir")
    target_files+=("$target_file")
  fi
done < <(find "$root_dir" -mindepth 1 -maxdepth 1 -type f -print0)

if ((${#conflicts[@]} > 0)); then
  echo "发现目标文件冲突，未执行任何修改：" >&2
  for conflict in "${conflicts[@]}"; do
    printf '  %s\n' "$conflict" >&2
  done
  exit 1
fi

if ((${#source_files[@]} == 0)); then
  echo "没有找到需要整理的第一层文件。"
  exit 0
fi

echo "计划执行以下修改："
for ((i = 0; i < ${#source_files[@]}; i++)); do
  printf '  %s\n    -> %s\n' "${source_files[$i]}" "${target_files[$i]}"
done

printf '\n共移动 %d 个文件。确认执行吗？[y/N] ' "${#source_files[@]}"
read -r answer

case "$answer" in
  y|Y|yes|YES)
    ;;
  *)
    echo "已取消，未修改任何文件。"
    exit 0
    ;;
esac

declare -a created_dirs=()

for ((i = 0; i < ${#source_files[@]}; i++)); do
  if [[ ! -d "${target_dirs[$i]}" ]]; then
    mkdir -p -- "${target_dirs[$i]}"
    created_dirs+=("${target_dirs[$i]}")
  fi

  mv -- "${source_files[$i]}" "${target_files[$i]}"
done

echo
echo "整理完成："
printf '  移动文件: %d 个\n' "${#source_files[@]}"
printf '  新建目录: %d 个\n' "${#created_dirs[@]}"

if ((${#created_dirs[@]} > 0)); then
  echo "新建的目录："
  printf '  %s\n' "${created_dirs[@]}"
fi

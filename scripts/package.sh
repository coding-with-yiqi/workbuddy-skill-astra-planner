#!/usr/bin/env bash
# 把本 skill 打成可分发的压缩包：拷到别处解压到 ~/.workbuddy/skills/ 即可用。
# 用法: package.sh [输出目录(默认当前目录)]
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

name="$(sed -n 's/^name: //p' "$root/SKILL.md" | head -1)"
version="$(sed -n 's/^version: //p' "$root/SKILL.md" | head -1)"
[ -z "$name" ] && { echo "读不到 name"; exit 1; }
[ -z "$version" ] && version="0.0.0"

dest_dir="$(cd "${1:-.}" 2>/dev/null && pwd)" || { echo "输出目录不存在"; exit 1; }
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/$name"
cp "$root/SKILL.md" "$staging/$name/"
for d in scripts references; do
  [ -d "$root/$d" ] || continue
  mkdir -p "$staging/$name/$d"
  # 排除系统垃圾与临时文件
  (cd "$root/$d" && tar cf - --exclude='.DS_Store' --exclude='*.tmp' .) | (cd "$staging/$name/$d" && tar xf -)
done

archive="$dest_dir/$name-$version.zip"
rm -f "$archive"
(cd "$staging" && zip -q -r -X "$archive" "$name")

if [ ! -f "$archive" ]; then echo "打包失败"; exit 1; fi

echo "PKG_OK $archive"
echo "内含:"
(cd "$staging/$name" && find . -type f | sed 's|^\./|  - |' | sort)
echo "sha256: $(shasum -a 256 "$archive" | awk '{print $1}')"
echo "安装: unzip -o '$archive' -d ~/.workbuddy/skills/"

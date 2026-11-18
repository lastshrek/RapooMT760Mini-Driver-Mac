#!/bin/bash
# 彻底清理 pkg 里的 AppleDouble (._*) 垃圾：Payload + Bom + Scripts
set -e
PKG="$1"
OUT="$2"
WORK=$(mktemp -d)
pkgutil --expand "$PKG" "$WORK/exp"
EXP="$WORK/exp"

# 1) 重建 Payload，跳过 ._*
mkdir -p "$WORK/clean"
(cd "$WORK/clean" && gzip -dc "$EXP/Payload" | cpio -id --quiet 2>/dev/null)
find "$WORK/clean" -name '._*' -delete 2>/dev/null || true
rm -f "$EXP/Payload"
(cd "$WORK/clean" && find . -mindepth 1 ! -name '._*' -print0 | sort -z | cpio -o --quiet -H odc --null 2>/dev/null) | gzip -9 > "$EXP/Payload"

# 2) 重建 Bom：用文件清单生成全新 bom（不含 ._*）
rm -f "$EXP/Bom"
mkbom "$WORK/clean" "$EXP/Bom"

# 3) 清理 Scripts 里的 ._*
find "$EXP/Scripts" -name '._*' -delete 2>/dev/null || true

# 4) 重新压平
rm -f "$OUT"
pkgutil --flatten "$EXP" "$OUT"
rm -rf "$WORK"

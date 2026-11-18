#!/bin/bash
# Build rapookeys as a UNIVERSAL binary (arm64 + x86_64) and package it as a .app bundle.
# Universal matters: the second machine is a dual-boot Mac and is likely Intel.
set -e
cd "$(dirname "$0")"

IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # 没有显式指定时，自动挑一个可用的签名身份（优先 Developer ID，其次 Apple Development）
  for PATTERN in "Developer ID Application: " "Apple Development: "; do
    IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
      | sed -n "s/.*\"\\(${PATTERN}[^\"]*\\)\".*/\\1/p" | head -1)"
    [ -n "$IDENTITY" ] && break
  done
fi
BUNDLE="RapooKeys.app"
MIN_MACOS="10.15"

echo "==> compiling arm64"
swiftc -O -target arm64-apple-macos${MIN_MACOS} main.swift -o rapookeys-arm64
echo "==> compiling x86_64"
swiftc -O -target x86_64-apple-macos${MIN_MACOS} main.swift -o rapookeys-x86_64
echo "==> creating universal binary"
lipo -create rapookeys-arm64 rapookeys-x86_64 -output rapookeys
rm -f rapookeys-arm64 rapookeys-x86_64
lipo -info rapookeys

mkdir -p "$BUNDLE/Contents/MacOS"
cp rapookeys "$BUNDLE/Contents/MacOS/rapookeys"
cp Info.plist "$BUNDLE/Contents/Info.plist"

# 未指定签名身份时退化为 ad-hoc，避免换机器构建失败（ad-hoc 下 TCC 授权每次编译会失效）
if [ -n "$IDENTITY" ] && security find-identity -p codesigning -v 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "==> signing with: $IDENTITY"
    codesign --force --identifier "com.rapookeys.driver" -s "$IDENTITY" "$BUNDLE"
else
    echo "!! 未找到可用的开发者证书，使用 ad-hoc 签名（重新编译后需重新授权输入监控）"
    echo "   也可以指定：CODE_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" ./build.sh"
    codesign --force --identifier "com.rapookeys.driver" -s - "$BUNDLE"
fi
codesign --verify --verbose=2 "$BUNDLE"
echo "Build OK: $BUNDLE (com.rapookeys.driver, universal)"

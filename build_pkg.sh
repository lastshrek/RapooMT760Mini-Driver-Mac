#!/bin/bash
# 生成两个 macOS 安装包：MT760-A.pkg（主）/ MT760-B.pkg（副）
# 安装内容：RapooKeys.app → /Applications；配置文件；LaunchAgent 开机自启
#
# 关键：payload(root) 里【只能】放 Applications/RapooKeys.app，绝不能放
# /Library 或 /scripts —— macOS 15 会把"往系统卷写内容"判为不兼容。
# 所有用户态文件（配置、LaunchAgent）一律由 postinstall 写到用户 home。
# scripts 目录必须放在 root 之外，否则会被一起打进 payload。
#
# 未签名 pkg（无 Developer ID Installer），首次需「仍要打开」；
# App 本身 Developer ID Application 签名，TCC 授权可跨更新保留。
set -e
cd "$(dirname "$0")"

ROOT="pkgbuild-root"
SCRIPTS="$ROOT/scripts"     # 与 payload root 平级，不进包体
mkdir -p "$ROOT"

build_pkg() {
  local role="$1"      # A or B
  local self_ch="$2"   # 本机所在信道
  local target_ch="$3" # 双击要切到的目标信道
  local label="$4"
  local pkg="MT760-${role}.pkg"
  local d="$ROOT/payload-$role"   # payload root：只放 App
  rm -rf "$d" "$SCRIPTS"
  mkdir -p "$d/Applications" "$SCRIPTS"

  # 配置由 gen_config.py 生成：devices 清单来自 devices.json（与 zip 包、Windows 端共用同一份来源）。
  # 以后加设备只改 devices.json，然后重新打包即可，不用动这个脚本。
  local CONFIG_JSON DEVICES_JSON
  CONFIG_JSON="$(python3 gen_config.py "$self_ch" "$target_ch")"
  DEVICES_JSON="$(python3 gen_config.py --devices-only)"

  # 用 ditto 排除扩展属性/资源分支，避免生成 ._ 垃圾文件
  rm -rf "$d/Applications/RapooKeys.app"
  ditto --norsrc --noextattr --noacl RapooKeys.app "$d/Applications/RapooKeys.app"

  # postinstall：写用户配置 + LaunchAgent（用户目录）+ 启动一次
  cat > "$SCRIPTS/postinstall" <<POST
#!/bin/bash
set -e
APP="/Applications/RapooKeys.app"
CONSOLE_USER=\$(stat -f "%Su" /dev/console)
[ -z "\$CONSOLE_USER" ] && CONSOLE_USER="\$USER"
HOME_DIR=\$(dscl . -read "/Users/\$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print \$2}')
[ -z "\$HOME_DIR" ] && HOME_DIR="\$HOME"

# 1. 解除隔离 + 可执行
xattr -dr com.apple.quarantine "\$APP" 2>/dev/null || true
chmod +x "\$APP/Contents/MacOS/rapookeys"

# 2. 配置（本机信道 ${self_ch}，双击目标信道 ${target_ch}；设备清单来自 devices.json）
mkdir -p "\$HOME_DIR/.config/rapookeys"
cat > "\$HOME_DIR/.config/rapookeys/mappings.json" <<'JSON'
${CONFIG_JSON}
JSON

# 2b. 设备清单单独一份：以后加设备只改这个文件，不碰 mappings.json
cat > "\$HOME_DIR/.config/rapookeys/devices.json" <<'JSON'
${DEVICES_JSON}
JSON
chown -R "\$CONSOLE_USER" "\$HOME_DIR/.config/rapookeys"

# 3. LaunchAgent 开机自启（写到用户目录，不碰系统卷）
mkdir -p "\$HOME_DIR/Library/LaunchAgents"
cat > "\$HOME_DIR/Library/LaunchAgents/com.rapookeys.menubar.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.rapookeys.menubar</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>-c</string>
    <string>/usr/bin/pkill -x rapookeys 2>/dev/null; sleep 0.6; printf 'bar' > /tmp/rapookeys.mode; /usr/bin/open /Applications/RapooKeys.app</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST
chown "\$CONSOLE_USER" "\$HOME_DIR/Library/LaunchAgents/com.rapookeys.menubar.plist" 2>/dev/null || true

# 4. 先结束所有旧实例（包括项目目录里的旧版、之前安装残留的实例），
#    否则两个进程会各建一套事件监听并争抢 0xBA 通道，导致双击切屏失效。
#    用 -x 按进程名精确匹配，不用 -f 避免误伤 installer 自身。
/usr/bin/pkill -x rapookeys 2>/dev/null || true
sleep 0.6

# 5. 只启动一个新实例（去掉 -n，-n 会强制再开一个进程，正是多实例的来源）
UID_NUM=\$(id -u "\$CONSOLE_USER" 2>/dev/null || echo 501)
printf 'bar' > /tmp/rapookeys.mode
launchctl asuser "\$UID_NUM" /usr/bin/open "\$APP" 2>/dev/null || /usr/bin/open "\$APP" 2>/dev/null || true

echo "MT760 安装完成。若菜单栏未出现绿色鼠标图标，请给 RapooKeys.app 授权「输入监控」+「辅助功能」后注销重登。"
exit 0
POST
  chmod +x "$SCRIPTS/postinstall"

  rm -f "$pkg"
  pkgbuild --root "$d" \
           --scripts "$SCRIPTS" \
           --identifier "com.rapookeys.menubar.${role}" \
           --version "1.0" \
           --install-location / \
           --ownership recommended \
           "$pkg"

  # macOS 15 会给本地文件自动加系统保护的 com.apple.provenance，xattr -cr 无权删除，
  # pkgbuild 会把它转成 ._ AppleDouble 垃圾；根目录的 ._Applications 会被判为写系统卷 → "不兼容"。
  # 用 clean_pkg.sh 展开→重建 Payload/Bom/Scripts→压平，彻底剔除。
  if [ -x ./clean_pkg.sh ]; then
    ./clean_pkg.sh "$pkg" "${pkg%.pkg}.tmp.pkg" && mv -f "${pkg%.pkg}.tmp.pkg" "$pkg"
  fi
  echo "生成: $pkg  ($(du -h "$pkg" | awk '{print $1}'))  —— $label 本机信道 ${self_ch} / 双击→信道 ${target_ch}"
}

build_pkg A 1 2 "主机 A（去 B）"
build_pkg B 2 1 "副机 B（回 A）"

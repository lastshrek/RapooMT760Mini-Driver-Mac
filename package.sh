#!/bin/bash
# 把 RapooKeys.app + Windows 托盘工具打成可拷到另一台 Mac 的部署包
set -e
cd "$(dirname "$0")"

OUT="rapookeys-deploy"
rm -rf "$OUT" rapookeys-deploy.zip
mkdir -p "$OUT"

cp -R RapooKeys.app "$OUT/"
cp "双机协同指南.md" "$OUT/GUIDE.md"
# 排除 __pycache__：本地跑过脚本会留下 .pyc，打进包既没用又会让人困惑
rsync -a --exclude '__pycache__' --exclude '*.pyc' windows-tray/ "$OUT/windows-tray/"

# 部署包给「另一台 Mac」用：本机 = 信道 2，双击目标 = 信道 1（回 A）。
# 设备清单与 pkg 共用 devices.json 这一个来源，加设备只改它。
python3 gen_config.py 2 1 > "$OUT/mappings.json"
cp devices.json "$OUT/devices.json"
# Windows 托盘：设备清单同样读 devices.json，本机身份（信道 3）单独放 self.json
cat > "$OUT/windows-tray/self.json" <<'EOS'
{ "selfChannel": 3 }
EOS

cat > "$OUT/step1-allow-app.sh" <<'EOS'
#!/bin/bash
# 在另一台 Mac 上运行一次：去掉 Gatekeeper 隔离标记，并打印本机接收器身份
set -e
cd "$(dirname "$0")"
xattr -dr com.apple.quarantine RapooKeys.app 2>/dev/null || true
chmod +x RapooKeys.app/Contents/MacOS/rapookeys
echo "已解除隔离标记。"
echo
echo "=== 版本 ==="
./RapooKeys.app/Contents/MacOS/rapookeys hid-cmd version || true
echo
echo "=== 本机接收器身份（把结果发回给另一台机器确认识别）==="
./RapooKeys.app/Contents/MacOS/rapookeys hid-cmd info
echo
echo "=== 下一步 ==="
echo "1) 系统设置 → 隐私与安全性：把 RapooKeys.app 加入「输入监控」+「辅助功能」"
echo "2) ./step2-menubar.sh   启动菜单栏小组件"
EOS
chmod +x "$OUT/step1-allow-app.sh"

cat > "$OUT/step2-menubar.sh" <<'EOS'
#!/bin/bash
# 启动菜单栏小组件（状态栏常驻：开关服务、按 devices.json 动态列出设备、双击切屏）
# 必须用 open 以 App 身份启动，否则 TCC 输入监控授权不归属 App
cd "$(dirname "$0")"
pkill -x rapookeys 2>/dev/null || true
sleep 0.6
printf 'bar' > /tmp/rapookeys.mode
open "$(pwd)/RapooKeys.app"
sleep 3
echo "=== 启动日志 ==="
L="$(ls -t /tmp/rapookeys-*.log 2>/dev/null | head -1)"
[ -n "$L" ] && tail -n 20 "$L"
echo
echo "状态栏应出现绿色小鼠标图标（灰=服务已停）。点图标可停止服务 / 在「切换设备」里选目标 / 退出。"
echo "若日志里出现 0xBA 通道警告：确认 RapooKeys.app 已加入「输入监控」后点菜单「重新打开指令通道」。"
EOS
chmod +x "$OUT/step2-menubar.sh"

cat > "$OUT/启动MT760.command" <<'EOS'
#!/bin/bash
# 双击即用：解除隔离 → 启动菜单栏组件（等价于安装，但不经过 pkg 安装器）
cd "$(dirname "$0")"
echo "==> 解除隔离标记"
xattr -dr com.apple.quarantine RapooKeys.app 2>/dev/null || true
chmod +x RapooKeys.app/Contents/MacOS/rapookeys
echo "==> 启动菜单栏组件"
pkill -x rapookeys 2>/dev/null || true
sleep 0.6
printf 'bar' > /tmp/rapookeys.mode
open "$(pwd)/RapooKeys.app"
sleep 3
echo "==> 启动日志"
L="$(ls -t /tmp/rapookeys-*.log 2>/dev/null | head -1)"
[ -n "$L" ] && tail -n 15 "$L"
echo
echo "状态栏应出现绿色鼠标图标。首次使用请先给 RapooKeys.app 授权「输入监控」+「辅助功能」。"
echo "本窗口可以关闭，组件继续在后台运行。"
EOS
chmod +x "$OUT/启动MT760.command"

cat > "$OUT/step3-cmd.sh" <<'EOS'
#!/bin/bash
# 命令行备用（菜单栏组件才是日常方式）
BIN="./RapooKeys.app/Contents/MacOS/rapookeys"
case "${1:-help}" in
  version)     $BIN hid-cmd version ;;
  devices)     $BIN hid-cmd devices ;;
  info)        $BIN hid-cmd info ;;
  status)      $BIN hid-cmd status ;;
  chan)        $BIN hid-cmd chan "${2:-1}" ;;
  selftest)    $BIN hid-probe --open ;;
  *) cat <<'HELP'
用法（0xBA 通道需「输入监控」授权）:
  ./step3-cmd.sh version       核对版本（应含 bar、chan）
  ./step3-cmd.sh chan 1        切到配置里信道 1 的设备（默认 A）
  ./step3-cmd.sh chan 2        切到配置里信道 2 的设备（默认 B）
  ./step3-cmd.sh chan 3        切到信道 3（例如 Windows / 蓝牙）
  ./step3-cmd.sh status        状态轮询
  ./step3-cmd.sh info          接收器身份 / 配置
  ./step3-cmd.sh devices       枚举所有 HID 设备并试打开
  ./step3-cmd.sh selftest      打开三个接口观察报文（Ctrl+C 退出）

设备清单在 devices.json 里改；改完重启菜单栏组件（或打开一次菜单）即生效。
HELP
  ;;
esac
EOS
chmod +x "$OUT/step3-cmd.sh"

zip -qr rapookeys-deploy.zip "$OUT"
ls -lh rapookeys-deploy.zip
echo "部署包已生成: $(pwd)/rapookeys-deploy.zip"

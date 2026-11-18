# Windows 抓包指南：抓「切换设备」指令

目标：在 Windows 上用 Wireshark 抓到雷柏驱动发给接收器的「切换设备」指令报文。
抓到后我就能在 Mac 端复现，让你不摸鼠标底部就能切设备。

预计耗时：15~20 分钟。

---

## 第一步：安装 Wireshark（含 USBPcap）

1. 打开 https://www.wireshark.org/download.html 下载 Windows 安装包（x64 Installer）
2. 安装时**所有组件保持默认勾选**——重点是确认 `USBPcap` 这一项被勾上
   （新版 Wireshark 安装器默认包含 USBPcap；如果组件列表里没有，另去
   https://desowin.org/usbpcap/ 下载 USBPcap 安装包补装一次）
3. 安装完成后**重启电脑**（USBPcap 是驱动，必须重启才生效）

## 第二步：找到鼠标接收器挂在哪条 USB 总线上

1. 把接收器插在 Windows 这台电脑上，确认鼠标能移动
2. 打开 `C:\Program Files\USBPcap\x64\USBPcapCMD.exe`（双击运行）
3. 它会列出所有 USB 总线和挂在上面的设备，类似：

```
1) \\.\USBPcap1
   |-- Standard Enhanced PCI to USB Host Controller
       |-- Human Interface Device  VID=0x24AE PID=0x1871 REV=...
```

4. 记下 VID=0x24AE（雷柏）那个设备所在的**编号**（比如 `1` 对应 USBPcap1）
   - 如果列表里有多个控制器都看得到这个设备，选它直接挂在的那个编号
5. 这个窗口先别关

## 第三步：开始抓包

1. 打开 Wireshark
2. 在接口列表里找到 `USBPcap1`（数字对应上一步记下的编号）
3. **双击它**会弹出 USBPcap 选项窗口：
   - 勾选 VID=0x24AE 的那个设备（只抓鼠标，文件小、好分析）
   - 其他保持默认，点 OK 开始抓包
4. 界面开始滚动就是抓上了

## 第四步：触发一次「设备切换」（最关键的一步）

抓包进行中，做**任意一次**会让驱动向鼠标发切换指令的操作：

- **首选**：打开雷柏 Windows 驱动（A HUB Office）→ 找「跨屏 / 多设备 / 设备管理」页面
  → 手动点击切换到另一台设备的按钮
- **备选**：如果两台电脑都装了驱动，把光标推过屏幕边缘触发一次跨屏切换
- **再备选**：驱动里如果有「重新连接 / 切换通道」之类的功能按钮，点一次也行

操作一次就够了，然后回 Wireshark 点红色方块**停止抓包**。

## 第五步：导出并传给我

1. Wireshark 菜单：File → Save As → 存成 `switch.pcapng`（桌面即可）
2. 把文件传到 Mac：微信「文件传输助手」/ 网盘 / U 盘都行
3. 放到这个目录：`/Users/lastshrek/Documents/Github/RapooMT760Mini-Driver-Mac/`
4. 告诉我一声，我来解析

---

## 我拿到文件后会做什么

1. 过滤出「电脑 → 接收器」的写指令：`usb.transfer_type == 0x02`（Interrupt OUT），
   且载荷以 report ID 6 开头、长度 28 字节——切换指令一定在其中
2. 比对几条候选报文，定位出切换设备的命令字节
3. 在 Mac 端用已验证的写入通道（0xFF01 接口，无需任何权限）复现这条指令
4. 给你绑上触发方式（键盘快捷键 / 鼠标手势），收工

## 常见问题

- **USBPcap 接口列表里没有 USBPcap1**：没重启电脑，重启后再看
- **抓包文件太大**：抓包时间别太长，触发切换后 10 秒内停止就够了
- **切换没触发报文**：说明那个操作是纯软件行为，试驱动页面里的其他按钮再抓一次
- **担心误操作改了鼠标配置**：抓包是纯监听，不会写入；Windows 驱动里有「恢复出厂设置」可随时兜底

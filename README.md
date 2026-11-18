# Rapoo MT760 mini — 软件切换设备 + 按键自定义

给**雷柏 MT760 mini**（以及同协议的其他雷柏多模鼠标）做的 macOS / Windows 小工具。

解决的问题很具体：**不想弯腰去拨鼠标底部的切换开关**。工具直接向接收器发一条 HID 指令，让鼠标在 2.4G / 蓝牙信道之间跳转，配合菜单栏（macOS）或托盘（Windows）一点即切。

> 非官方工具。协议是通过抓包逆向得到的，与雷柏无关，使用风险自负。

## 功能

| 功能 | macOS | Windows |
|---|---|---|
| 双击切换设备（中键双击 / `Ctrl+↑` 双击） | ✅ | — |
| 菜单栏 / 托盘常驻，列出所有设备一点即切 | ✅ | ✅ |
| 任意信道试切（1–4），用于给新设备确定信道号 | ✅ | ✅ |
| 改配置即时生效（不用重启） | ✅ | 重启托盘 |
| 按键重映射（把侧键改成任意键或组合键） | ✅ 可选 | — |
| 开机自启（LaunchAgent） | ✅ | 手动放启动目录 |
| 首次运行授权引导 | ✅ | — |

## 原理（一句话）

接收器的 HID 接口（`usage=6`，即"键盘类"接口）上有一条厂商指令，32 字节，第 8 个字节是信道号：

```
ba a5 ae 00 00 00 00 [信道] 00 00 ...
```

发一次就能让鼠标切过去。`1` = 第一个信道，`2` = 第二个，依此类推（2.4G 接收器和蓝牙各占一个）。

两个重要前提：

1. **指令只能由"当前正持有鼠标"的那台机器发出**。所以每台机器都要装一份，否则切过去就切不回来（只能拨底部开关）。
2. **协议只能"指定切到第几号信道"**，不能查询"鼠标现在在哪"，也不能枚举已配对设备。所以设备清单要写在配置里。

协议细节见 [`rapoo_protocol.md`](rapoo_protocol.md)。

## 快速开始

### 方式一：安装包（推荐）

| 文件 | 用途 |
|---|---|
| `MT760-A.pkg` | 主机 A：本机在信道 1，双击切到信道 2 |
| `MT760-B.pkg` | 副机 B：本机在信道 2，双击切回信道 1 |

双击安装 → 因为安装包没有 Developer ID Installer 签名，首次需在「系统设置 → 隐私与安全性」里点**仍要打开**。安装完会自动启动菜单栏图标。

### 方式二：解压即用

```bash
unzip rapookeys-deploy.zip
cd rapookeys-deploy
./step1-allow-app.sh   # 打开授权面板
./step2-menubar.sh     # 启动菜单栏组件
```

### 首次必须授权两项

系统设置 → 隐私与安全性：

| 权限 | 用途 | 不给会怎样 |
|---|---|---|
| **辅助功能** | 建立事件监听、合成按键 | 按键映射、双击判定全部失效 |
| **输入监控** | 读写 HID 接口 | 发不出切换指令（`0xBA` 通道打不开） |

授权后要**重启程序**。菜单栏图标颜色即状态：🟢 运行中 / ⚪️ 已停止 / 🟠 待授权。菜单里点「授权设置…」可随时重新检查。

> 每次重新编译都会改变二进制哈希，ad-hoc 签名下需要重新授权；用固定开发者证书签名则可跨更新保留。

## 配置

### 配置文件在哪

程序按下面顺序找第一个存在的 `mappings.json`：

1. 命令行显式指定的路径（`rapookeys sniff /path/to/mappings.json`）
2. 当前工作目录
3. App 所在目录（部署包根目录）
4. App 包内 `Resources/`
5. **`~/.config/rapookeys/mappings.json`** ← 安装包写的就是这里，一般改这个

设备清单 `devices.json` 按同样思路找：`mappings.json` 同目录 → `~/.config/rapookeys/` → App 目录。

### mappings.json

完整字段（全部可省略，省略即关闭对应功能）：

```json
{
  "buttons": {},
  "selfChannel": 1,
  "switchTarget": "B",
  "doubleSwitchButtons": { "2": 2 },
  "ctrlUpDoubleSwitch": 2,
  "switchButtons": {},
  "devices": []
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `buttons` | 对象 | 按键重映射，见下节。**默认空 = 不拦截任何鼠标键**，侧键、DPI 键都按原生行为直通 |
| `selfChannel` | 数字 | 本机所在信道。**只用于在菜单里标记"本机"并置灰**，不参与判定 |
| `switchTarget` | 字符串/数字 | 双击的目标：可以写设备名（`"B"`，会去 `devices` 清单里查信道）或直接写信道号（`"2"` / `2`）。**仅在下面两个字段都没写时生效** |
| `doubleSwitchButtons` | 对象 | 鼠标按键 → 目标信道，**双击**触发。`{"2": 2}` = 双击中键切到 2 |
| `ctrlUpDoubleSwitch` | 数字 | **双击 `Ctrl+↑`** 触发的目标信道。用于中键被固件占用成 `Ctrl+↑` 的鼠标（见下文） |
| `switchButtons` | 对象 | 鼠标按键 → 目标信道，**单击立即**触发（有延迟顾虑才需要，一般不用） |
| `devices` | 数组 | 内嵌设备清单；留空则读独立的 `devices.json` |

典型配置：

```jsonc
// A 机（信道 1）：双击 → 去 B
{ "selfChannel": 1, "doubleSwitchButtons": { "2": 2 }, "ctrlUpDoubleSwitch": 2 }

// B 机（信道 2）：双击 → 回 A
{ "selfChannel": 2, "doubleSwitchButtons": { "2": 1 }, "ctrlUpDoubleSwitch": 1 }
```

### 鼠标按键编号

`buttons` / `doubleSwitchButtons` / `switchButtons` 的键是 **CGEvent 按键号**（从 0 开始，比 HID 描述符里的 Button 编号小 1）：

| 编号 | 物理键 |
|---|---|
| `0` | 左键 |
| `1` | 右键 |
| `2` | 中键（滚轮按下） |
| `3` | 后退（通常是靠拇指的前一个侧键） |
| `4` | 前进 |

不确定时：菜单栏 →「中键硬件诊断（20 秒）」，按一下对应键，日志会打印实际按键号与原始 HID 报文。

### 按键重映射（可选）

```json
{
  "buttons": {
    "3": { "keyCode": 33, "flags": 1048576, "note": "后退侧键 → Cmd+[" },
    "4": { "keyCode": 30, "flags": 1048576, "note": "前进侧键 → Cmd+]" }
  }
}
```

| 字段 | 说明 |
|---|---|
| `keyCode` | 虚拟键码。`33` = `[`、`30` = `]`、`0` = `A`、`48` = `Tab`、`53` = `Esc`、`126` = `↑` |
| `flags` | 修饰键位掩码，可相加：`1048576` Cmd、`131072` Shift、`262144` Ctrl、`524288` Option、`8388608` Fn |
| `button` | 不想发按键时，也可以映射成另一个鼠标键（`{"button": 2}` = 变成中键） |

只按**按下**触发一次（抬起只被吞掉），所以不会出现"后退连跳两页"。

### devices.json

```json
{
  "devices": [
    { "name": "A", "channel": 1, "note": "2.4G 接收器" },
    { "name": "B", "channel": 2, "note": "2.4G 接收器" },
    { "name": "Windows", "channel": 3, "note": "蓝牙" }
  ]
}
```

菜单里的「切换设备 ▸」就是按它生成的，`⌥⌘1…9` 依次分配。

### 加一台设备

1. 先用菜单栏 →「切换设备」→「任意信道」→ 试切 `1`–`4`，看指针跟到哪个就是几号信道（**2.4G 接收器和蓝牙各占一个；同一台机器换 macOS/Windows 不算新信道**）。
2. 在 `devices.json` 里加一行。
3. 打开一次菜单栏菜单即自动重载（或点「重新读取配置」）。
4. 想让双击直接切到它：把 `switchTarget` 改成设备名，或直接把 `doubleSwitchButtons` / `ctrlUpDoubleSwitch` 的值改成新信道号。

### 关于 `Ctrl+↑`

不少雷柏鼠标的"中键"在固件里并不是标准中键，而是被映射成 **`Ctrl+↑`**（macOS 的调度中心快捷键）。这种鼠标在系统层面**根本不产生中键事件**，所以 `doubleSwitchButtons` 永远等不到 `button=2`。

`ctrlUpDoubleSwitch` 就是为它准备的：把「双击 `Ctrl+↑`」当触发器。

- **单击照旧**：第一次按下先扣住 0.22 秒，期间没有第二次按下就把 `Ctrl+↑` 原样补发，调度中心正常弹出（代价是约 0.2 秒延迟）
- **双击切设备**：窗口内出现第二次按下 → 两次都不透传，只发切换指令

## 菜单栏

点图标直接开/关服务，右键（或长按）看完整菜单：

| 菜单项 | 作用 |
|---|---|
| 服务：运行中 / 已停止 | 开关双击切设备监听（手动切换不受影响） |
| **切换设备 ▸** | 按 `devices.json` 生成，本机项置灰，其余一点即切 |
| **任意信道 ▸** | 试切 1–4 号信道 |
| 重新读取配置 | 改完 JSON 立即生效 |
| 授权设置… | 检查辅助功能 / 输入监控 |
| 中键硬件诊断（20 秒） | 打印原始 HID 报文，排查"某个键到底上报成什么" |
| 退出 | 结束程序 |

## 命令行

```bash
BIN=/Applications/RapooKeys.app/Contents/MacOS/rapookeys

$BIN bar                   # 菜单栏模式（默认入口）
$BIN setup                 # 强制打开授权引导窗口
$BIN sniff                 # 监听并打印所有鼠标/滚轮事件，用来确认按键号
$BIN hid-probe             # 枚举接收器的 HID 接口
$BIN hid-probe --open      # 打开接口并打印原始报文
$BIN hid-cmd chan 1        # 切到信道 1
$BIN hid-cmd devices       # 列出所有 HID 设备
$BIN hid-cmd info          # 接收器身份与当前配置
```

> 注意：如果鼠标是走 `Ctrl+↑` 的那种，`chan` 命令仍然可用——它只依赖 0xBA 通道，与鼠标事件无关。
> 但从**终端**直接跑这些子命令通常拿不到 TCC 授权（授权绑定的是 App 而不是终端），会看到 `0xBA 通道不可用`。命令行排查请优先看 `/tmp/rapookeys-<pid>.log`。

日志：每次启动写到 `/tmp/rapookeys-<pid>.log`，第一行含 `build=` 版本标记。

## Windows

Windows 端只用托盘发同一条指令，不需要驱动：

```bat
cd windows-tray
install.bat   :: 安装 hid / pystray / Pillow（pip，失败自动回退默认源）
start.bat     :: 启动托盘
```

- 托盘菜单：切到各设备 / 任意信道 / 自检 / 退出
- 本机是几号信道写在 `windows-tray/self.json`，默认 `{"selfChannel": 3}`
- 设备清单与 macOS 共用同一份 `devices.json`
- 想开机自启：把 `start.bat` 的快捷方式放进 `shell:startup`

## 从源码构建

需要 Xcode 命令行工具（`swiftc`）。产物是 `arm64 + x86_64` 通用二进制，最低 macOS 10.15。

```bash
./build.sh          # 编译 + 组装 RapooKeys.app + 签名
./build_pkg.sh      # 生成 MT760-A.pkg / MT760-B.pkg
./package.sh        # 生成 rapookeys-deploy.zip
```

签名身份自动探测（优先 Developer ID，其次 Apple Development），也可以用环境变量指定：

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

没证书时退化为 ad-hoc 签名——能跑，但每次重编译都要重新授权。

安装包的配置由 `gen_config.py` 从 `devices.json` 生成，所以打包前先把 `devices.json` 改成你们自己的设备清单：

```bash
python3 gen_config.py 1 2              # 生成 A 机配置（本机 1，双击→2）
python3 gen_config.py --devices-only   # 只生成 devices.json
```

> 打包坑：macOS 15 会给本地文件自动加 `com.apple.provenance` 属性，pkgbuild 会把它转成 `._*` 垃圾文件塞进包顶层，导致安装时报"软件包与 macOS 不兼容"。`build_pkg.sh` 末尾会自动调用 `clean_pkg.sh` 重建 Payload / Bom / Scripts 清掉这些文件。

## 排障

| 现象 | 原因 / 处理 |
|---|---|
| 双击没反应 | 先看进程是不是只有一个：`pgrep -fl rapookeys`。多个实例会互相抢事件和 0xBA 通道，`pkill -x rapookeys` 后重开 |
| 双击没反应，日志里也没有 `button=2` | 中键大概率被固件映射成 `Ctrl+↑`。用「中键硬件诊断」确认，然后靠 `ctrlUpDoubleSwitch` 触发 |
| 单击中键不再弹调度中心 | 检查是否写了 `ctrlUpDoubleSwitch`（会扣住首次点击 0.22 秒再补发）；确认版本日志含 `private-source=on` |
| `0xBA 通道不可用` | 输入监控没授权，或授权后没重启程序 |
| 重新装包后要重新授权 | 换了签名身份（ad-hoc）导致 TCC 记录失效，重新授权一次 |
| 装了但开机不自启 | 检查 `~/Library/LaunchAgents/com.rapookeys.menubar.plist` 是否存在 |

## 已知限制

- 指令只能由持有鼠标的一端发出，所以每台都要装；切过去后只能在那台上切回来
- 协议没有"查询当前信道 / 枚举已配对设备"的指令，设备清单靠配置维护
- 事件监听是全局的，理论上也会影响其他鼠标；按键重映射按按键号匹配，不区分设备
- 密码框等"安全输入"场景下，合成事件会被系统丢弃
- 只有 0xBA 这一条通道能确认可用；DPI 键、蓝牙配对键在固件内部处理，软件层拿不到

## 目录

```
main.swift             主程序（菜单栏、事件监听、HID 协议、诊断）
mappings.json          默认行为配置示例
devices.json           设备清单（打包时的唯一来源）
gen_config.py          由清单生成 pkg / zip 用的配置
build.sh               编译 + 签名
build_pkg.sh           生成 A/B 安装包
package.sh             生成 zip 部署包
clean_pkg.sh           清理 pkg 内的 AppleDouble 垃圾
windows-tray/          Windows 托盘（Python）
rapoo_protocol.md      协议逆向记录
安装包说明.md           面向使用者的完整说明
双机协同指南.md         两台机器的协同流程（部署包内为 GUIDE.md）
```

## 声明

协议为抓包逆向所得，与雷柏官方无关，不提供任何担保。若你打算以开源方式发布，记得自己选一个 LICENSE（MIT 之类）并放进来。

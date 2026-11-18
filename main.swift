import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import Darwin
import IOKit
import IOKit.hid

// kIOMainPortDefault 是 macOS 12+ 符号；旧系统用 kIOMasterPortDefault（值相同，均等于 0）。
// 统一用自己的常量，保证 10.15 也能编译运行。
private let rapooIOMainPort: mach_port_t = {
    if #available(macOS 12.0, *) { return kIOMainPortDefault }
    return kIOMasterPortDefault
}()

// Rapoo MT760 Mini (BLE) button remapper / sniffer — proof of concept
// Build: swiftc -O main.swift -o rapookeys
// Run:   ./rapookeys                 (sniff + remap using mappings.json if present)
//        ./rapookeys hid-probe       (try to open the raw HID device / vendor report)

var gTap: CFMachPort?
var gMappings: [Int: Action] = [:]
var gSwitchButtons: [Int: UInt8] = [:]         // 鼠标按键 -> 目标信道（单击触发）
var gDoubleSwitchButtons: [Int: UInt8] = [:]   // 鼠标按键 -> 目标信道（双击触发）
// 「双击 Ctrl+↑」切信道：用于鼠标中键被固件映射成 Ctrl+↑ 的情况（此时系统层没有中键事件）
var gCtrlUpChannel: UInt8? = nil
// 判定节奏从「抬起」开始算：这个固件按一次 Ctrl+↑ 会按住约 220ms，
// 若从按下开始算窗口，第二下很容易超时被误判成单击。
enum CtrlUpState: Equatable { case idle, firstDown, awaitSecond, swallowSecond }
var gCtrlUpState: CtrlUpState = .idle
var gCtrlUpDownFlags: CGEventFlags = []   // 第一次按下的 flags（含 Ctrl），补发时必须用它
var gCtrlUpWatchdog: DispatchWorkItem?
let kCtrlUpWindow: TimeInterval = 0.22
let kCtrlUpStuckTimeout: TimeInterval = 1.5
let gProcStart = Date()
func msClock() -> Int { Int(Date().timeIntervalSince(gProcStart) * 1000) }

// 中键单击/双击延迟判定状态机：
//   .pendingDown   第一次按下已扣住，等待第二次按下（双击）或超时（补发单击）
//   .pendingHeld   超时后已补发按下，等待物理抬起放行（长按/自动滚动仍可用）
//   .swallowSecond 双击第二下，吞掉它的按下与抬起
enum ClickJudge: Equatable { case idle, pendingDown, pendingHeld, swallowSecond }
var gClickJudge: [Int: ClickJudge] = [:]
var gFirstUpSeen: Set<Int> = []           // 第一次按下后的抬起已到达（被吞掉）
let kDoubleClickWindow: TimeInterval = 0.30
// 合成事件双标记：补发的单击若被自己的 tap 再次捕获，任一命中即直接放行，
// 避免被当成新的第一次点击而无限补发。双保险是因为 flags 高位可能被系统规范化丢弃，
// 而 eventSourceUserData(字段42) 是 CGEvent 自带的 64 位用户字段，post 后稳定保留。
let kSyntheticFlag = CGEventFlags(rawValue: 1 << 60)
let kSyntheticMagic: Int64 = 0x5241504F4D373630  // "RAPOM760"
var gVerbose = true
// 演练模式：只打印要发的帧，不真的发出去。用于在不敢打断当前信道的情况下验证判定逻辑。
// 触发方式：环境变量 RAPOO_DRYRUN=1，或存在文件 ~/.config/rapookeys/dryrun
let gDryRun = ProcessInfo.processInfo.environment["RAPOO_DRYRUN"] == "1"
    || FileManager.default.fileExists(
        atPath: NSString(string: "~/.config/rapookeys/dryrun").expandingTildeInPath)
var gZeroScroll = 0
var gConfigPath: String? = nil      // 实际加载的配置文件路径，键位设置写回这里
var gConfigMTime: Date? = nil       // 配置文件的修改时间，用于菜单打开时判断是否需要热重载
var gDevices: [DeviceEntry] = []    // 配置里的设备清单（菜单数据源）
var gSelfChannel: Int? = nil        // 本机所在信道
var gSwitchTargetName: String? = nil// 双击目标（设备名或信道号文本）

struct Action: Codable {
    var keyCode: UInt16?     // CGKeyCode, e.g. 33 = "[" on US layout
    var flags: UInt64?       // CGEventFlags bitmask, e.g. 0x100000 = Command
    var button: Int?         // or remap to another mouse button number
    var note: String?
}

/// 一台可切换的目标设备。信道号就是 `ba a5 ae ... 00 [ch]` 里的第 8 字节。
/// 鼠标协议只能「指定切到哪个信道」，没有查询/枚举能力，
/// 所以设备清单必须写在配置里，工具据此生成菜单。
struct DeviceEntry: Codable {
    var name: String
    var channel: Int
    var note: String?   // 例如 "2.4G 接收器" / "蓝牙"，仅用于显示
}

struct ConfigFile: Codable {
    var buttons: [String: Action]
    var switchButtons: [String: Int]?        // "2": 2 表示单击中键 → 2 号信道
    var doubleSwitchButtons: [String: Int]?  // "2": 2 表示双击中键 → 2 号信道
    // 有些鼠标的「中键」在固件里被映射成 Ctrl+↑（会以键盘组合键上报，
    // 系统层根本没有中键事件）。这个字段让工具把「双击 Ctrl+↑」当作切信道。
    var ctrlUpDoubleSwitch: Int?
    // 设备清单（动态切换的核心）：菜单按这个列表生成，之后加设备只改 JSON，不用重新编译。
    var devices: [DeviceEntry]?
    var selfChannel: Int?      // 本机所在信道，用于菜单里标记「本机」
    var switchTarget: String?  // 双击要切到哪台：设备名或信道号（字符串/数字都行）
}

/// 把 switchTarget（可能是设备名、也可能是信道号文本）解析成信道号
func resolveDeviceChannel(_ target: String?) -> UInt8? {
    guard let raw = target?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if let n = Int(raw), n >= 0, n <= 255 { return UInt8(n) }
    // 名字匹配：先精确，再忽略大小写/前缀（允许写 "B" 匹配到 "B · Mac mini"）
    if let hit = gDevices.first(where: { $0.name == raw }) { return UInt8(clamping: hit.channel) }
    let lower = raw.lowercased()
    if let hit = gDevices.first(where: {
        let n = $0.name.lowercased()
        return n == lower || n.hasPrefix(lower + " ") || n.hasPrefix(lower + "·") || n.hasPrefix(lower + "-")
    }) { return UInt8(clamping: hit.channel) }
    if let hit = gDevices.first(where: { $0.name.lowercased().contains(lower) }) {
        return UInt8(clamping: hit.channel)
    }
    return nil
}

func describeDevices() -> String {
    if gDevices.isEmpty { return "(未配置)" }
    return gDevices.map { d in
        let me = (gSelfChannel == d.channel) ? " ← 本机" : ""
        let note = d.note.map { " [\($0)]" } ?? ""
        return "\(d.name)=ch\(d.channel)\(note)\(me)"
    }.joined(separator: ", ")
}

/// 设备清单可以单独放在 devices.json 里（推荐），这样 mappings.json 保持「纯行为配置」，
/// 原有键位/触发器一个字段都不用动。也兼容写在 mappings.json 的 devices 字段里。
func loadDevicesFile(near configPath: String?) -> [DeviceEntry] {
    struct Wrapper: Codable { var devices: [DeviceEntry] }
    var candidates: [String] = []
    if let cp = configPath {
        candidates.append((cp as NSString).deletingLastPathComponent + "/devices.json")
    }
    candidates.append(NSString(string: "~/.config/rapookeys/devices.json").expandingTildeInPath)
    candidates.append(Bundle.main.bundleURL.deletingLastPathComponent()
                        .appendingPathComponent("devices.json").path)
    candidates.append("devices.json")
    for p in candidates where FileManager.default.fileExists(atPath: p) {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
           let w = try? JSONDecoder().decode(Wrapper.self, from: data) {
            print("[config] devices 来自 \(p)")
            gDevicesPath = p
            return w.devices
        }
    }
    return []
}

func loadConfig(_ explicit: String?) {
    var candidates: [String] = []
    if let p = explicit {
        candidates.append(p)
    } else {
        candidates.append("mappings.json")
        // open/LaunchServices 启动时工作目录是 "/"，需从 App 所在目录（部署包根目录）找
        let deployDir = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(deployDir.appendingPathComponent("mappings.json").path)
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("mappings.json").path)
        }
        candidates.append(NSString(string: "~/.config/rapookeys/mappings.json").expandingTildeInPath)
    }
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let cfg = try JSONDecoder().decode(ConfigFile.self, from: data)

            // 重新加载时先清空，避免改配置后旧设备/旧映射残留
            gMappings.removeAll()
            gSwitchButtons.removeAll()
            gDoubleSwitchButtons.removeAll()
            gCtrlUpChannel = nil
            gDevices.removeAll()
            gDevicesPath = nil
            gSelfChannel = nil
            gSwitchTargetName = nil

            for (k, v) in cfg.buttons {
                if let n = Int(k) { gMappings[n] = v }
            }
            for (k, ch) in cfg.switchButtons ?? [:] {
                if let n = Int(k), ch >= 0, ch <= 255 { gSwitchButtons[n] = UInt8(ch) }
            }
            for (k, ch) in cfg.doubleSwitchButtons ?? [:] {
                if let n = Int(k), ch >= 0, ch <= 255 { gDoubleSwitchButtons[n] = UInt8(ch) }
            }
            if let ch = cfg.ctrlUpDoubleSwitch, ch >= 0, ch <= 255 { gCtrlUpChannel = UInt8(ch) }

            // 设备清单：优先用 mappings.json 内嵌的；没有就读同目录/配置目录的 devices.json
            var deviceSource = cfg.devices ?? []
            if deviceSource.isEmpty {
                deviceSource = loadDevicesFile(near: path)
            }
            var seen = Set<Int>()
            for d in deviceSource {
                guard d.channel >= 1, d.channel <= 255, !seen.contains(d.channel) else { continue }
                seen.insert(d.channel)
                gDevices.append(d)
            }
            gDevices.sort { $0.channel < $1.channel }
            if let s = cfg.selfChannel, s >= 1, s <= 255 { gSelfChannel = s }

            // switchTarget：设备名或信道号。未显式写 doubleSwitchButtons / ctrlUpDoubleSwitch 时，
            // 用它作为双击目标，这样加设备只需要改 devices + switchTarget 一处。
            let target = resolveDeviceChannel(cfg.switchTarget)
            gSwitchTargetName = cfg.switchTarget
            if let t = target {
                if gDoubleSwitchButtons[2] == nil { gDoubleSwitchButtons[2] = t }
                if gCtrlUpChannel == nil { gCtrlUpChannel = t }
            }

            gConfigPath = path
            gConfigMTime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            if let dp = gDevicesPath {
                gDevicesMTime = (try? FileManager.default.attributesOfItem(atPath: dp)[.modificationDate]) as? Date
            } else {
                gDevicesMTime = nil
            }

            let targetDesc = target.map { "ch\($0)" } ?? "off"
            print("[config] loaded \(gMappings.count) mapping(s), \(gSwitchButtons.count) click-switch(es), \(gDoubleSwitchButtons.count) double-click-switch(es), ctrlUp-double→\(gCtrlUpChannel.map(String.init) ?? "off"), target=\(targetDesc) from \(path)")
            if !gDevices.isEmpty {
                print("[config] devices: \(describeDevices())")
            }
            return
        } catch {
            print("[config] parse error in \(path): \(error)")
        }
    }
    if let p = explicit { print("[config] file not found: \(p)") }
}

var gDevicesPath: String? = nil     // 独立设备清单 devices.json 的实际路径
var gDevicesMTime: Date? = nil      // 它的修改时间，改了清单也要能热重载

/// 配置文件是否被改动（菜单打开时调用，实现「改完 JSON 立即生效」）
func configChangedOnDisk() -> Bool {
    func changed(_ path: String?, _ old: Date?) -> Bool {
        guard let path, let m = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        else { return false }
        guard let old else { return false }
        return m.timeIntervalSince(old) > 0.5
    }
    return changed(gConfigPath, gConfigMTime) || changed(gDevicesPath, gDevicesMTime)
}

func currentCursor() -> CGPoint {
    let p = NSEvent.mouseLocation
    let h = NSScreen.main?.frame.height ?? 0
    return CGPoint(x: p.x, y: h - p.y)
}

func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
    // 逐个发 down/up 并打合成标记：合成事件重入自己的 tap 时会被直接放行，
    // 不会被当成真实按键再做一次映射（否则会递归）。
    postKeyRaw(code, flags: flags, down: true)
    usleep(8_000)
    postKeyRaw(code, flags: flags, down: false)
}

/// 补发被扣住的按键（语义别名，内部同样用 privateState，保证修饰位不被改写）
func postKeyReplay(_ code: CGKeyCode, flags: CGEventFlags, down: Bool) {
    postKeyRaw(code, flags: flags, down: down)
}

/// 只发一个键盘 DOWN 或 UP，并打上合成标记。
/// 必须用 privateState 事件源：用 nil（= 合并会话状态）时，系统会按当前真实按下的
/// 修饰键改写 flags —— Cmd+[ 会退化成 [，Ctrl+↑ 会退化成 ↑，组合键全部失效。
func postKeyRaw(_ code: CGKeyCode, flags: CGEventFlags, down: Bool) {
    let src = CGEventSource(stateID: .privateState)
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
    e.flags = flags
    e.flags.insert(kSyntheticFlag)
    e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMagic)
    e.post(tap: .cghidEventTap)
}

func postButton(_ number: Int64, down: Bool) {
    let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                          mouseCursorPosition: currentCursor(),
                          mouseButton: CGMouseButton(rawValue: UInt32(number)) ?? .left) else { return }
    e.setIntegerValueField(.mouseEventButtonNumber, value: number)
    e.flags.insert(kSyntheticFlag)
    e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMagic)
    e.post(tap: .cghidEventTap)
}

let tapCallback: CGEventTapCallBack = { proxy, type, event, _ in
    // 自己补发的合成单击直接放行（并清掉标记），不参与双击判定与按键映射。
    // 两个标记任一命中即可：flags 高位可能被系统规范化丢弃，userData 稳定保留。
    if event.flags.contains(kSyntheticFlag)
        || event.getIntegerValueField(.eventSourceUserData) == kSyntheticMagic {
        event.flags.remove(kSyntheticFlag)
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        return Unmanaged.passUnretained(event)
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // 服务被用户主动停止时，不要因为系统事件又偷偷重启 tap
        if gBarServiceOn {
            print("[warn] event tap was disabled; re-enabling")
            if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return nil
    }

    let button = event.getIntegerValueField(.mouseEventButtonNumber)

    switch type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
         .otherMouseDown, .otherMouseUp:
        let isDown = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown)
        if gVerbose {
            print(String(format: "[mouse] button=%lld %@ flags=0x%llx",
                         button, isDown ? "DOWN" : "UP  ", event.flags.rawValue))
        }
        // 双击切屏：延迟判定。第一次按下先扣住 0.30 秒——
        //   窗口内出现第二次按下 → 判定双击，两次点击都不透传，只切屏；
        //   超时无第二次 → 补发一次普通单击。
        // 这样中键原生单击（自动滚动/点击粘贴）不会再和双击切换叠加。
        if let dbl = gDoubleSwitchButtons[Int(button)] {
            let b = Int(button)
            let st = gClickJudge[b] ?? .idle
            if isDown {
                switch st {
                case .pendingDown:
                    // 第二次按下 → 双击
                    gClickJudge[b] = .swallowSecond
                    gFirstUpSeen.remove(b)
                    print("[switch] button=\(button) 双击 → 切到信道 \(dbl)")
                    if let dev = gCmdDevice {
                        sendBA(dev, baFrame([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0x00, dbl]),
                               label: "double-click switch")
                    } else {
                        print("[switch] 0xBA 通道未打开，无法切换（检查输入监控授权）")
                    }
                    return nil
                case .swallowSecond:
                    return nil  // 第二下还没抬起又来一下，继续吞
                case .idle, .pendingHeld:
                    // 新的第一次按下：扣住，起定时器等待双击判定
                    gClickJudge[b] = .pendingDown
                    gFirstUpSeen.remove(b)
                    DispatchQueue.main.asyncAfter(deadline: .now() + kDoubleClickWindow) {
                        guard gClickJudge[b] == .pendingDown else { return }  // 已判定为双击
                        gClickJudge[b] = .pendingHeld
                        // 补发按下；若抬起已先到（快速单击）则 down+up 一起补发，
                        // 若仍按住则只补 down，物理抬起稍后放行，保留长按/自动滚动
                        postButton(Int64(button), down: true)
                        if gFirstUpSeen.contains(b) {
                            gFirstUpSeen.remove(b)
                            gClickJudge[b] = .idle
                            postButton(Int64(button), down: false)
                        }
                    }
                    return nil
                }
            } else {
                switch st {
                case .pendingDown:
                    gFirstUpSeen.insert(b)  // 第一次抬起吞掉，记下来供补发配对
                    return nil
                case .swallowSecond:
                    gClickJudge[b] = .idle
                    return nil
                case .pendingHeld:
                    // 补发的 down 已发出，放行物理抬起，形成完整单击/结束长按
                    gClickJudge[b] = .idle
                    return Unmanaged.passUnretained(event)
                case .idle:
                    break
                }
            }
        }
        // 单击切屏（如另行配置）
        if isDown, let ch = gSwitchButtons[Int(button)] {
            print("[switch] button=\(button) → 切到信道 \(ch)")
            if let dev = gCmdDevice {
                sendBA(dev, baFrame([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0x00, ch]),
                       label: "click switch")
            } else {
                print("[switch] 0xBA 通道未打开，无法切换（检查输入监控授权）")
            }
            return nil
        }
        if let action = gMappings[Int(button)] {
            if let code = action.keyCode {
                // 只在按下时发一次按键，抬起仅吞掉。
                // 否则一次点击会发两遍（按下一次、抬起一次），后退/前进会连跳两页。
                if isDown { postKey(CGKeyCode(code), flags: CGEventFlags(rawValue: action.flags ?? 0)) }
                return nil  // swallow original
            } else if let target = action.button {
                postButton(Int64(target), down: isDown)
                return nil
            }
        }
    case .keyDown, .keyUp:
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // 诊断期间记录键盘事件：如果鼠标某个键被固件映射成组合键，这里能直接看到
        if gDiagActive {
            print(String(format: "[kbd +%dms] %@ keycode=%lld flags=0x%llx",
                         diagMs(), type == .keyDown ? "DOWN" : "UP  ", code, event.flags.rawValue))
        }
        // 某些鼠标把「中键」映射成 Ctrl+↑（键盘组合键），系统层没有中键事件。
        // 这里把「双击 Ctrl+↑」当作切信道触发器：
        //   按下先吞掉；抬起后开始计时 0.32 秒——窗口内再来一次按下 → 只切信道；
        //   超时没有第二次 → 原样补发一次，Mission Control 等原生功能照旧。
        if code == 126, let ch = gCtrlUpChannel,
           event.flags.contains(.maskControl) || gCtrlUpState != .idle {
            let isDown = (type == .keyDown)
            if isDown {
                switch gCtrlUpState {
                case .awaitSecond:
                    gCtrlUpState = .swallowSecond
                    print("[switch +ms] Ctrl+↑ 双击 → 切到信道 \(ch)   t=\(msClock())")
                    if let dev = gCmdDevice ?? findCmdDevice() {
                        gCmdDevice = dev
                        sendBA(dev, baFrame([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0x00, ch]),
                               label: "ctrl-up double switch")
                    } else {
                        print("[switch] 0xBA 通道未打开，无法切换（检查输入监控授权）")
                    }
                    return nil
                case .firstDown, .swallowSecond:
                    return nil
                case .idle:
                    gCtrlUpState = .firstDown
                    // 记住「按下」时的 flags：固件的抬起报文通常不带 Ctrl 位，
                    // 用它补发会把 Ctrl+↑ 变成纯 ↑。
                    gCtrlUpDownFlags = event.flags
                    gCtrlUpDownFlags.insert(.maskControl)
                    gCtrlUpDownFlags.remove(kSyntheticFlag)
                    print("[ctrlup] 按下 Ctrl+↑，扣住等第二次  t=\(msClock())")
                    // 万一起抬事件丢失，别让状态卡死在 firstDown（会一直吞键）
                    gCtrlUpWatchdog?.cancel()
                    let wd = DispatchWorkItem {
                        guard gCtrlUpState == .firstDown else { return }
                        gCtrlUpState = .idle
                        print("[ctrlup] 未收到抬起事件，状态复位")
                    }
                    gCtrlUpWatchdog = wd
                    DispatchQueue.main.asyncAfter(deadline: .now() + kCtrlUpStuckTimeout, execute: wd)
                    return nil
                }
            } else {
                switch gCtrlUpState {
                case .firstDown:
                    gCtrlUpState = .awaitSecond
                    gCtrlUpWatchdog?.cancel()
                    let replayFlags = gCtrlUpDownFlags.union(.maskControl)
                    DispatchQueue.main.asyncAfter(deadline: .now() + kCtrlUpWindow) {
                        guard gCtrlUpState == .awaitSecond else { return }  // 已判为双击
                        gCtrlUpState = .idle
                        print("[ctrlup] 未出现第二次，原样补发 Ctrl+↑  t=\(msClock()) flags=0x\(String(replayFlags.rawValue, radix: 16))")
                        postKeyReplay(126, flags: replayFlags, down: true)
                        usleep(10_000)
                        postKeyReplay(126, flags: replayFlags, down: false)
                    }
                    return nil
                case .swallowSecond:
                    gCtrlUpState = .idle
                    return nil
                case .awaitSecond:
                    return nil
                case .idle:
                    break
                }
            }
        }
    case .scrollWheel:
        let y = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let x = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if y == 0 && x == 0 {
            gZeroScroll += 1
        } else {
            if gZeroScroll > 0 {
                print("[scroll] (skipped \(gZeroScroll) zero-delta noise events)")
                gZeroScroll = 0
            }
            print(String(format: "[scroll] vertical=%lld horizontal=%lld", y, x))
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

var gProbeOpen = false
var gSeize = false
var gPoke = false
var gDevice: IOHIDDevice?
var gCmdDevice: IOHIDDevice?   // 0xBA 指令通道（复合键盘接口）
var gPokeStep = 0

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func sendPoke(_ device: IOHIDDevice, payload: [UInt8]) {
    var buf = payload
    let reportID = Int(buf[0])
    let len = buf.count
    let ret = buf.withUnsafeMutableBufferPointer { p -> IOReturn in
        guard let base = p.baseAddress else { return kIOReturnError }
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, base, len)
    }
    print("[poke] sent report 0x\(String(reportID, radix: 16)) len=\(buf.count): \(hex(buf)) -> status \(ret)")
}

// 用 IORegistry 枚举 + IOHIDDeviceCreate，绕开 IOHIDManager 在 macOS 27 上
// 的 os_unfair_lock 损坏崩溃（匹配回调里调 GetProperty 必死）
func runHIDProbe(openDevices: Bool) {
    gProbeOpen = openDevices
    setvbuf(stdout, nil, _IONBF, 0)

    guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else {
        print("[hid] IOServiceMatching failed")
        exit(1)
    }
    matching["VendorID"] = 9390  // 0x24AE Rapoo

    var iterator: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(rapooIOMainPort, matching as CFDictionary, &iterator)
    guard kr == kIOReturnSuccess else {
        print("[hid] IOServiceGetMatchingServices failed: \(kr)")
        exit(1)
    }
    defer { IOObjectRelease(iterator) }

    var count = 0
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        count += 1

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            print("[hid] #\(count) (无法读取属性)")
            IOObjectRelease(service)
            continue
        }
        let name = props["Product"] as? String ?? "(unknown)"
        let usagePage = props["PrimaryUsagePage"] as? Int ?? -1
        let usage = props["PrimaryUsage"] as? Int ?? -1
        let transport = props["Transport"] as? String ?? "?"
        let tcc = props["RequiresTCCAuthorization"] as? Bool ?? false
        print(String(format: "[hid] #%d: %@  usagePage=%d(0x%02x) usage=%d transport=%@ tcc=%@",
                      count, name, usagePage, usagePage, usage, transport, String(tcc)))

        let isVendor = (usagePage == 0xFF00 || usagePage == 0xFF01)
        if !gProbeOpen {
            print("[hid]   -> enumerate only (pass --open to try opening interfaces)")
        } else {
            guard let device = IOHIDDeviceCreate(nil, service) else {
                print("[hid]   -> IOHIDDeviceCreate failed")
                IOObjectRelease(service)
                continue
            }
            print("[hid]   -> opening interface\(gSeize ? " (seize)" : "")...")
            let options: IOOptionBits = IOOptionBits(gSeize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
            let ret = IOHIDDeviceOpen(device, options)
            print("[hid]   -> open status: \(ret)  (0 = OK; 0xE00002C2 = need Input Monitoring)")
            if ret == kIOReturnSuccess {
                gDevice = device
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
                IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { _, _, _, _, reportID, report, reportLength in
                    let n = min(Int(reportLength), 64)
                    let bytes = (0..<n).map { String(format: "%02x", report[$0]) }.joined()
                    print(String(format: "[hid] report 0x%02x len=%ld: %@", reportID, reportLength, bytes))
                }, nil)
                print("[hid]   -> listening; press keys / move mouse")
                // 0xBA 指令通道在复合接口（键盘+多媒体+厂商 collection）上：usagePage=1, usage=6
                if usagePage == 1 && usage == 6 {
                    gCmdDevice = device
                    print("[hid]   -> 0xBA command channel available on this interface")
                }
            }
        }
        IOObjectRelease(service)
    }

    print("[hid] done. \(count) interface(s) enumerated." + (openDevices ? " Waiting for reports (Ctrl+C / pkill to quit)..." : ""))
    if openDevices {
        if gPoke {
            // 每 2 秒发一条探测指令，观察鼠标是否有应答报文
            let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0) { _ in
                if let d = gCmdDevice {
                    // 0xBA 指令通道（32 字节，协议见 rapoo_protocol.md）
                    let probes: [[UInt8]] = [
                        [0xBA, 0xA5, 0xA1, 0x01],                 // 状态轮询（只读，安全）
                        [0xBA, 0xA5, 0xAF],                       // 开 swap 窗口
                        [0xBA, 0xA5, 0xA1, 0x01],                 // 再轮询一次
                    ]
                    if gPokeStep < probes.count {
                        var buf = probes[gPokeStep]
                        buf.append(contentsOf: [UInt8](repeating: 0, count: 32 - buf.count))
                        let reportID = Int(buf[0])
                        let len = buf.count
                        let ret = buf.withUnsafeMutableBufferPointer { p -> IOReturn in
                            guard let base = p.baseAddress else { return kIOReturnError }
                            return IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, reportID, base, len)
                        }
                        print("[poke] 0xBA frame #\(gPokeStep): \(hex(buf)) -> status \(ret)")
                        gPokeStep += 1
                    } else {
                        print("[poke] 0xBA probes done; listening for replies (Ctrl+C / pkill to quit)")
                    }
                } else if let d = gDevice {
                    // 回退：0xFF01 接口（29 字节 report 6）
                    let probes: [[UInt8]] = [
                        [0x06] + [UInt8](repeating: 0x00, count: 27),
                        [0x06, 0x01] + [UInt8](repeating: 0x00, count: 26),
                        [0x06, 0x09] + [UInt8](repeating: 0x00, count: 26),
                    ]
                    if gPokeStep < probes.count {
                        sendPoke(d, payload: probes[gPokeStep])
                        gPokeStep += 1
                    } else {
                        print("[poke] all probes sent; keep listening for replies (Ctrl+C / pkill to quit)")
                    }
                }
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, CFRunLoopMode.commonModes)
            print("[poke] will send probe commands (one every 2s) and watch for replies")
        }
        RunLoop.current.run()
    }
}

// MARK: - 0xBA 指令通道高层命令（协议见 rapoo_protocol.md）
// 接收器 RF 地址：本机地址从 ~/.rapoo-dongle 读取，缺省为已验证的地址
// 文件格式（每行 key=value，忽略 # 注释）：
//   self=44C60769     本机接收器 RF 地址（大端书写，内部转小端）
//   peer=44B0076A     对端接收器 RF 地址（用于双端协同）
let DEFAULT_SELF_ADDR = "44C60769"

struct DongleConfig {
    var selfAddr: String = DEFAULT_SELF_ADDR
    var peerAddr: String? = nil
}

func loadDongleConfig() -> DongleConfig {
    var cfg = DongleConfig()
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".rapoo-dongle")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return cfg }
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { continue }
        let value = parts[1].uppercased().replacingOccurrences(of: "0X", with: "")
        switch parts[0].lowercased() {
        case "self": if value.count == 8 { cfg.selfAddr = value }
        case "peer": if value.count == 8 { cfg.peerAddr = value }
        default: break
        }
    }
    return cfg
}

/// "44C60769" -> [0x69, 0x07, 0xC6, 0x44]（协议要求小端）
func addrToLE(_ hex: String) -> [UInt8]? {
    guard hex.count == 8, let v = UInt32(hex, radix: 16) else { return nil }
    return [
        UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
        UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)
    ]
}

let gCfg = loadDongleConfig()
var LOCAL_DONGLE_ADDR: [UInt8] { addrToLE(gCfg.selfAddr) ?? [0x69, 0x07, 0xC6, 0x44] }

var gWatchT0 = Date()
func watchElapsed() -> Double { -gWatchT0.timeIntervalSinceNow }

func baFrame(_ head: [UInt8]) -> [UInt8] {
    var f = head
    f.append(contentsOf: [UInt8](repeating: 0, count: 32 - f.count))
    return f
}

func sendBA(_ device: IOHIDDevice, _ frame: [UInt8], label: String) {
    var buf = frame
    let reportID = Int(buf[0])
    let len = buf.count
    if gDryRun {
        print("[cmd] \(label): \(hex(buf)) -> (演练模式，未发送)")
        return
    }
    let ret = buf.withUnsafeMutableBufferPointer { p -> IOReturn in
        guard let base = p.baseAddress else { return kIOReturnError }
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, base, len)
    }
    print("[cmd] \(label): \(hex(buf)) -> status \(ret)")
}

func findCmdDevice() -> IOHIDDevice? {
    guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return nil }
    matching["VendorID"] = 9390
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(rapooIOMainPort, matching as CFDictionary, &iterator) == kIOReturnSuccess else { return nil }
    defer { IOObjectRelease(iterator) }
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { continue }
        let usagePage = props["PrimaryUsagePage"] as? Int ?? -1
        let usage = props["PrimaryUsage"] as? Int ?? -1
        if usagePage == 1 && usage == 6, let d = IOHIDDeviceCreate(nil, service) {
            if IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
                return d
            }
        }
    }
    return nil
}

func archName() -> String {
    #if arch(arm64)
    return "arm64 (Apple Silicon)"
    #elseif arch(x86_64)
    return "x86_64 (Intel)"
    #else
    return "unknown"
    #endif
}

/// 打印接收器的 USB 身份（序列号 / LocationID），用于区分两台机器的接收器
func printDongleIdentity() {
    guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return }
    matching["VendorID"] = 9390
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(rapooIOMainPort, matching as CFDictionary, &iterator) == kIOReturnSuccess else { return }
    defer { IOObjectRelease(iterator) }
    var seen = Set<String>()
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        var propsRef: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
           let props = propsRef?.takeRetainedValue() as? [String: Any] {
            let serial = props["SerialNumber"] as? String ?? "(无)"
            let product = props["Product"] as? String ?? "?"
            let pid = props["ProductID"] as? Int ?? -1
            let loc = props["LocationID"] as? Int ?? -1
            let key = "\(serial)-\(loc)"
            if !seen.contains(key) {
                seen.insert(key)
                print(String(format: "[info] 接收器: %@  PID=0x%04x  序列号=%@  locationID=0x%08x",
                             product, pid, serial, loc))
            }
        }
        IOObjectRelease(service)
    }
    if seen.isEmpty { print("[info] 未发现 VID=0x24AE 的 HID 设备（接收器已拔掉或仅走蓝牙）") }
}

/// 把 IOReturn 错误码翻译成人能看懂的原因
func openErrName(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess: return "成功"
    case kIOReturnNotPermitted: return "权限不足（需输入监控）"
    case kIOReturnExclusiveAccess: return "已被其他进程独占"
    case kIOReturnNotAttached: return "设备未挂载"
    case kIOReturnNotOpen: return "设备未打开"
    case kIOReturnBusy: return "设备忙"
    case kIOReturnUnsupported: return "该接口不支持此操作"
    default: return "未知错误"
    }
}

/// 列出系统里所有 HID 设备（不筛选厂商），用于诊断「为什么找不到指令通道」
func listAllHIDDevices() {
    guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(rapooIOMainPort, matching as CFDictionary, &iterator) == kIOReturnSuccess else {
        print("[dev] IOServiceGetMatchingServices 失败")
        return
    }
    defer { IOObjectRelease(iterator) }
    var idx = 0
    var seen = Set<String>()
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        var propsRef: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
           let props = propsRef?.takeRetainedValue() as? [String: Any] {
            let vid = props["VendorID"] as? Int ?? -1
            let pid = props["ProductID"] as? Int ?? -1
            let product = props["Product"] as? String ?? "?"
            let up = props["PrimaryUsagePage"] as? Int ?? -1
            let u = props["PrimaryUsage"] as? Int ?? -1
            let transport = props["Transport"] as? String ?? "?"
            let key = "\(vid)-\(pid)-\(up)-\(u)"
            if !seen.contains(key) {
                seen.insert(key)
                idx += 1
                let isRapoo = (vid == 0x24AE)
                print(String(format: "[dev] #%02d %@VID=0x%04x PID=0x%04x usagePage=%d(0x%02x) usage=%d transport=%@  %@",
                             idx, isRapoo ? "★RAPOO " : "", vid, pid, up, up, u, transport, product))
                // 对雷柏接口额外试打开，区分「找不到」和「打不开」
                if isRapoo, let dev = IOHIDDeviceCreate(nil, service) {
                    let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
                    if r == kIOReturnSuccess {
                        let tag = (up == 1 && u == 6) ? "，这就是指令通道" : ""
                        print("        └─ open: OK (0)  ← 可读写\(tag)")
                        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
                    } else {
                        print(String(format: "        └─ open: FAIL 0x%08x", r) + "  (\(openErrName(r)))")
                    }
                } else if isRapoo {
                    print("        └─ IOHIDDeviceCreate 失败")
                }
            }
        }
        IOObjectRelease(service)
    }
    if idx == 0 {
        print("[dev] 系统里没有任何 HID 设备（异常）")
    } else if !seen.contains(where: { $0.hasPrefix("9390-") }) {
        print("[dev] 未发现任何 VID=0x24AE(9390) 的雷柏设备 —— 接收器可能没插在这台机器上")
    }
}

func runCommand(_ op: String) {
    setvbuf(stdout, nil, _IONBF, 0)
    if op == "devices" {
        print("[info] 架构: \(archName())  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        listAllHIDDevices()
        exit(0)
    }
    guard let d = findCmdDevice() else {
        print("[cmd] 找不到/打不开 0xBA 指令通道（usage=6 接口）")
        print("[cmd] ---- 自动诊断 ----")
        print("[info] 架构: \(archName())  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        listAllHIDDevices()
        exit(1)
    }
    print("[cmd] 0xBA channel opened.")
    // 让 SetReport 有机会先走通：先开窗再执行动作
    switch op {
    case "info":
        // 输出本机接收器身份，便于两台机器互相确认
        print("[info] macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("[info] 架构: \(archName())")
        print("[info] 配置的 self 地址: \(gCfg.selfAddr)")
        print("[info] 配置的 peer 地址: \(gCfg.peerAddr ?? "(未设置)")")
        printDongleIdentity()
    case "status":
        sendBA(d, baFrame([0xBA, 0xA5, 0xA1, 0x01]), label: "status poll")
    case "release":
        // 驱动同款时序：af 开窗保持期间，每 1s 发一次 ae 释放，共 3 次，再关窗
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "open window")
        Thread.sleep(forTimeInterval: 0.2)
        for i in 1...3 {
            sendBA(d, baFrame([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0xFF, 0x00]), label: "release #\(i)")
            Thread.sleep(forTimeInterval: 1.0)
        }
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "close window")
        print("[cmd] release sent — 鼠标应短暂掉线（约 2s~20s）后自动回连")
    case "resync":
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "open window")
        Thread.sleep(forTimeInterval: 0.2)
        sendBA(d, baFrame([0xBA, 0xA5, 0xAE] + LOCAL_DONGLE_ADDR), label: "hop to local addr")
        Thread.sleep(forTimeInterval: 2.0)
        sendBA(d, baFrame([0xBA, 0xA5, 0xAE] + LOCAL_DONGLE_ADDR), label: "hop #2")
        Thread.sleep(forTimeInterval: 1.0)
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "close window")
        print("[cmd] resync sent — 鼠标应重新握手（掉线 ~2s）")
    case "chan":
        // chan <1..4>：切换鼠标到指定信道（真正的切换指令，见 phreer.github.io 的 MT760 逆向）
        // 帧：ba a5 ae 00 00 00 00 <信道> 00...   第 8 字节（index 7）= 信道号，无需前置开窗
        let chArg = CommandLine.arguments.dropFirst(3).first(where: { UInt8($0) != nil })
        let ch = chArg.flatMap { UInt8($0) } ?? 1
        print("[cmd] 切换信道 → \(ch)   帧内 index7 = \(String(format: "%02x", ch))")
        for i in 1...3 {
            sendBA(d, baFrame([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0x00, ch]),
                   label: "switch ch\(ch) #\(i)")
            Thread.sleep(forTimeInterval: 0.4)
        }
        print("[cmd] 已发送 —— 鼠标应立刻跳到 \(ch) 号信道对应的接收器；本机若无鼠标输入属正常")
    case "jump":
        // jump <8位hex>：从「持有方」发起，命令鼠标跳到指定 RF 地址（实验用，地址可任意指定）
        let jumpArg = CommandLine.arguments.dropFirst(3).first(where: { $0.count == 8 && UInt32($0, radix: 16) != nil })
        guard let jumpHex = jumpArg, let jumpLE = addrToLE(jumpHex) else {
            print("用法: hid-cmd jump <8位hex地址>   例: hid-cmd jump 44B0076A")
            break
        }
        let leText = jumpLE.map { String(format: "%02x", $0) }.joined()
        print("[cmd] 目标地址 \(jumpHex) → 帧内字节 \(leText)")
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "open window")
        Thread.sleep(forTimeInterval: 0.2)
        for i in 1...3 {
            sendBA(d, baFrame([0xBA, 0xA5, 0xAE] + jumpLE), label: "jump #\(i) → \(jumpHex)")
            Thread.sleep(forTimeInterval: 1.0)
        }
        print("[cmd] 窗口保持 15 秒不关（协议 §6.5：过早关窗会取消跳转）...")
        Thread.sleep(forTimeInterval: 15)
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "close window")
        print("[cmd] jump done — 若鼠标跳到该地址所属接收器，指针会出现在那台机器上")
    case "version":
        print("[ver] build=2026-11-18T1900  ops=bar,setup,chan,jump,version,devices,info,status,release,resync,claim,pull,open-window,handoff,watch,monitor,lan-on,lan-off,reg")
        print("[ver] self=\(gCfg.selfAddr) peer=\(gCfg.peerAddr ?? "(未设置)")")
    case "claim":
        // 认领：开窗保持 ~20s，每 1s 发一次「跳转到本机地址」，等待持有方释放后鼠标跳过来
        print("[cmd] 认领窗口开启 120 秒 — 请在此期间把鼠标电源关开一次！")
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "open window")
        Thread.sleep(forTimeInterval: 0.2)
        for i in 1...115 {
            sendBA(d, baFrame([0xBA, 0xA5, 0xAE] + LOCAL_DONGLE_ADDR), label: "claim #\(i)")
            Thread.sleep(forTimeInterval: 1.0)
        }
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "close window")
        print("[cmd] claim done — 若鼠标已跳到本机，指针现在应该能动")
    case "lan-on":
        // 跨屏/LAN 模式寄存器（rapoo_protocol.md §3）：跨设备页开关打开时的写入序列
        sendBA(d, baFrame([0xBA, 0xA5, 0xA4, 0x18, 0x34]), label: "reg 0x18 = 0x34")
        Thread.sleep(forTimeInterval: 0.3)
        sendBA(d, baFrame([0xBA, 0xA5, 0xA4, 0x08, 0x54]), label: "reg 0x08 = 0x54")
        Thread.sleep(forTimeInterval: 0.3)
        print("[cmd] lan-on sent — 跨屏模式寄存器已写入")
    case "lan-off":
        sendBA(d, baFrame([0xBA, 0xA5, 0xA4, 0x18, 0x23]), label: "reg 0x18 = 0x23")
        Thread.sleep(forTimeInterval: 0.3)
        sendBA(d, baFrame([0xBA, 0xA5, 0xA4, 0x08, 0x20]), label: "reg 0x08 = 0x20")
        Thread.sleep(forTimeInterval: 0.3)
        print("[cmd] lan-off sent — 跨屏模式寄存器已复位")
    case "reg":
        // reg <寄存器hex> <值hex>：直接写寄存器，用于实验
        let regArgs = CommandLine.arguments.dropFirst(3).compactMap { UInt8($0, radix: 16) }
        if regArgs.count >= 2 {
            sendBA(d, baFrame([0xBA, 0xA5, 0xA4, regArgs[0], regArgs[1]]),
                   label: String(format: "reg 0x%02x = 0x%02x", regArgs[0], regArgs[1]))
        } else {
            print("用法: hid-cmd reg <寄存器hex> <值hex>   例: hid-cmd reg 18 34")
        }
    case "pull":
        // 定向认领窗口：pull [秒数] — 开窗后持续喊本机地址，配合对端 release
        let secs = CommandLine.arguments.dropFirst(3).compactMap { Int($0) }.first ?? 25
        print("[cmd] 认领窗口开启 \(secs) 秒（本机地址 \(gCfg.selfAddr)）")
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "open window")
        Thread.sleep(forTimeInterval: 0.2)
        for i in 1...max(1, secs) {
            sendBA(d, baFrame([0xBA, 0xA5, 0xAE] + LOCAL_DONGLE_ADDR), label: "claim #\(i)")
            Thread.sleep(forTimeInterval: 1.0)
        }
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "close window")
        print("[cmd] pull done")
    case "open-window":
        // 只开窗不认领：不需要知道本机地址，用于「张网等待对端移交」
        // open-window [秒数]
        let waitSecs = CommandLine.arguments.dropFirst(3).compactMap { Int($0) }.first ?? 30
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "open window")
        print("[cmd] 窗口保持 \(waitSecs) 秒（等待对端 release/移交，期间周期轮询保持活跃）")
        var tick = 0
        let openDeadline = Date().addingTimeInterval(Double(waitSecs))
        while Date() < openDeadline {
            Thread.sleep(forTimeInterval: 1.0)
            tick += 1
            if tick % 3 == 0 {
                sendBA(d, baFrame([0xBA, 0xA5, 0xA1, 0x01]), label: "[poll \(tick)s]")
            }
        }
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "close window")
        print("[cmd] 窗口已关闭")
    case "handoff":
        // 移交：开窗 + 多次释放 + 保持窗口等对端接住（过早关窗会取消跳转，协议 §6.5）
        // handoff [保持秒数]
        let holdSecs = CommandLine.arguments.dropFirst(3).compactMap { Int($0) }.first ?? 20
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "open window")
        Thread.sleep(forTimeInterval: 0.2)
        for i in 1...5 {
            sendBA(d, baFrame([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0xFF, 0x00]), label: "release #\(i)")
            Thread.sleep(forTimeInterval: 1.0)
        }
        print("[cmd] 已释放，窗口继续保持 \(holdSecs) 秒等待对端接住 ...")
        let holdDeadline = Date().addingTimeInterval(Double(holdSecs))
        while Date() < holdDeadline { Thread.sleep(forTimeInterval: 1.0) }
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "close window")
        print("[cmd] handoff done — 若对端接住，鼠标应已跳到那台机器")
    case "watch":
        // 全自动实验：同进程内轮询+监听，15s 基线 → release → 35s 观察
        gWatchT0 = Date()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        IOHIDDeviceRegisterInputReportCallback(d, buffer, 64, { _, _, _, _, reportID, report, reportLength in
            let n = min(Int(reportLength), 64)
            let bytes = (0..<n).map { String(format: "%02x", report[$0]) }.joined()
            print(String(format: "[rx %.1fs] report 0x%02x len=%ld: %@", watchElapsed(), reportID, reportLength, bytes))
        }, nil)
        let poller = Thread {
            while true {
                sendBA(d, baFrame([0xBA, 0xA5, 0xA1, 0x01]), label: String(format: "[poll %.1fs]", watchElapsed()))
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
        poller.start()
        print("[watch] 基线 15 秒 ...")
        Thread.sleep(forTimeInterval: 15)
        print("[watch] 发送 release ...")
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "open window")
        Thread.sleep(forTimeInterval: 0.2)
        for i in 1...3 {
            sendBA(d, baFrame([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0xFF, 0x00]), label: "release #\(i)")
            Thread.sleep(forTimeInterval: 1.0)
        }
        sendBA(d, baFrame([0xBA, 0xA5, 0xAF]), label: "close window")
        print("[watch] release 完成，继续观察 35 秒 ...")
        Thread.sleep(forTimeInterval: 35)
        print("[watch] 实验结束")
        exit(0)
    case "monitor":
        // 持续监听输入报告（需要输入监控权限真正生效）
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        IOHIDDeviceRegisterInputReportCallback(d, buffer, 64, { _, _, _, _, reportID, report, reportLength in
            let n = min(Int(reportLength), 64)
            let bytes = (0..<n).map { String(format: "%02x", report[$0]) }.joined()
            print(String(format: "[rx] report 0x%02x len=%ld: %@", reportID, reportLength, bytes))
        }, nil)
        print("[cmd] monitoring input reports; Ctrl+C to quit")
        RunLoop.current.run()
    default:
        print("用法: hid-cmd status|release|resync|monitor")
    }
    exit(0)
}

// MARK: - 菜单栏组件（bar 模式）
// 常驻状态栏的「可视化小组件」：可开关中键双击服务、手动切 A/B、自检通道。
// 事件监听用 CGEventTap（需辅助功能），0xBA 写入用 IOHIDDevice（需输入监控）。
private var gBarItem: NSStatusItem?
private var gBarStatusMenuItem: NSMenuItem?
private var gBarToggleMenuItem: NSMenuItem?
private var gDeviceMenu: NSMenu?          // 「切换设备」子菜单，打开时按配置重建
private var gLastTarget: UInt8? = nil     // 本机最近一次发送的目标信道（仅 UI 提示，不是鼠标真实位置）
private var gBarServiceOn = true          // 「服务」= 中键双击自动切屏监听

/// 信道 → 显示名（优先用配置里的设备名，没配就退回「信道 N」）
private func barDeviceName(_ ch: UInt8) -> String {
    if let d = gDevices.first(where: { $0.channel == Int(ch) }) { return d.name }
    return "信道 \(ch)"
}
private func barChannelName(_ ch: UInt8) -> String {
    let n = barDeviceName(ch)
    return n == "信道 \(ch)" ? n : "\(n)（信道 \(ch)）"
}

private func barSendChannel(_ ch: UInt8, _ label: String) {
    guard let d = gCmdDevice ?? findCmdDevice() else {
        gCmdDevice = nil
        print("[bar] 0xBA 通道不可用 —— 请给 RapooKeys.app 授权「输入监控」")
        return
    }
    gCmdDevice = d
    // 一帧即生效（协议文档与实测一致）；发两帧只为抗偶发丢包，间隔 0.1s 不至于卡住菜单
    for i in 1...2 {
        sendBA(d, baFrame([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0x00, ch]),
               label: "\(label) #\(i)")
        if i == 1 { Thread.sleep(forTimeInterval: 0.1) }
    }
    let text = "上次目标：\(barChannelName(ch))"
    gLastTarget = ch
    print("[bar] \(text)")
    barRefreshUI()
}

/// 自绘鼠标图标：绿色=服务运行，灰色=已停止。isTemplate=false 以保留颜色。
private func barMouseImage(active: Bool, tint: NSColor? = nil) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18))
    img.lockFocus()
    defer { img.unlockFocus() }

    // 鼠标外形（AppKit 坐标，原点左下）
    (tint ?? (active ? NSColor.systemGreen : NSColor.systemGray)).setFill()
    let body = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 1, width: 9, height: 16),
                            xRadius: 4.5, yRadius: 4.5)
    body.fill()

    // 镂空出滚轮与左右键分界线
    NSColor.clear.setFill()
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    NSBezierPath(roundedRect: NSRect(x: 8.3, y: 12.6, width: 1.4, height: 3.2),
                 xRadius: 0.7, yRadius: 0.7).fill()
    NSBezierPath(rect: NSRect(x: 8.7, y: 6.5, width: 0.6, height: 5.2)).fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver

    img.isTemplate = false
    return img
}

// MARK: - 首次运行授权引导
// TCC 的「辅助功能」「输入监控」无法静默授予，但可以做三件事：
//   1. 实时检测两项是否已授权；2. 一键打开对应系统设置面板；3. 授权后自动检测并继续。
// 这样分享给别人时，对方跟着弹窗点几下即可，不必读文档。
private var gSetupWindow: NSWindow?
private var gSetupPoll: Timer?
private var gAXGranted = false
private var gIMGranted = false
private var gSetupKeepOpen = false   // 用户主动点「授权设置」时保持窗口，不自动关

/// 辅助功能是否已授权（不弹系统提示，只查询）
private func barAXGranted() -> Bool {
    return AXIsProcessTrusted()
}

/// 输入监控是否已授权：能否打开 usage=6 的 0xBA 通道
private func barIMGranted() -> Bool {
    if gCmdDevice != nil { return true }
    guard let d = findCmdDevice() else { return false }
    gCmdDevice = d
    return true
}

private func barOpenSettings(_ pane: String) {
    // 系统设置 → 隐私与安全性 → 对应面板
    let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    if let u = URL(string: url) {
        NSWorkspace.shared.open(u)
    } else {
        // 老系统回退到通用隐私面板
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane"))
    }
}

private final class SetupBridge: NSObject {
    @objc func openAccessibility() {
        barOpenSettings("Privacy_Accessibility")
    }
    @objc func openInputMonitoring() {
        barOpenSettings("Privacy_ListenEvent")
    }
    @objc func recheck() {
        setupRecheck()
    }
    @objc func skip() {
        gSetupPoll?.invalidate(); gSetupPoll = nil
        gSetupWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        print("[setup] 用户跳过授权引导，稍后可从菜单栏「授权设置」重新打开")
    }
}
private let setupBridge = SetupBridge()

/// 刷新引导窗口里两项的状态文字与颜色
private func setupRefresh() {
    guard let win = gSetupWindow, let cv = win.contentView else { return }
    let axLabel = cv.viewWithTag(11) as? NSTextField
    let imLabel = cv.viewWithTag(12) as? NSTextField
    let hint = cv.viewWithTag(20) as? NSTextField
    axLabel?.stringValue = gAXGranted ? "✅ 已授权" : "❌ 未授权 —— 点右侧按钮去开启"
    axLabel?.textColor = gAXGranted ? .systemGreen : .systemOrange
    imLabel?.stringValue = gIMGranted ? "✅ 已授权" : "❌ 未授权 —— 点右侧按钮去开启"
    imLabel?.textColor = gIMGranted ? .systemGreen : .systemOrange
    if gAXGranted && gIMGranted {
        hint?.stringValue = "两项都已就绪，中键双击切屏可以使用了。"
        hint?.textColor = .systemGreen
    }
    barRefreshUI()
}

/// 重新检测两项授权；全部通过后停止轮询、关窗、恢复菜单栏
private func setupRecheck() {
    gAXGranted = barAXGranted()
    gIMGranted = barIMGranted()
    print("[setup] 检测：辅助功能=\(gAXGranted ? "已授权" : "未授权")  输入监控=\(gIMGranted ? "已授权" : "未授权")")
    setupRefresh()
    if gAXGranted && gIMGranted && !gSetupKeepOpen {
        gSetupPoll?.invalidate(); gSetupPoll = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            gSetupWindow?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            print("[setup] 授权完成，引导窗口已关闭，服务可用")
        }
    }
}

/// 构建并显示引导窗口（幂等：已显示则只重新检测）
private func barShowSetup(keepOpen: Bool = false) {
    gSetupKeepOpen = keepOpen
    if let win = gSetupWindow, win.isVisible {
        setupRecheck()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        return
    }
    gAXGranted = barAXGranted()
    gIMGranted = barIMGranted()

    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
    win.title = "MT760 首次设置"
    win.isRestorable = false
    let cv = win.contentView!

    let title = NSTextField(labelWithString: "需要授权两项系统权限")
    title.font = .boldSystemFont(ofSize: 16)
    title.frame = NSRect(x: 24, y: 254, width: 430, height: 26)
    cv.addSubview(title)

    let intro = NSTextField(labelWithString: "macOS 不允许程序自己开启这些权限，请点按钮打开系统设置并打开开关。")
    intro.font = .systemFont(ofSize: 12)
    intro.textColor = .secondaryLabelColor
    intro.frame = NSRect(x: 24, y: 230, width: 440, height: 20)
    cv.addSubview(intro)

    // 辅助功能行
    let axTitle = NSTextField(labelWithString: "辅助功能")
    axTitle.font = .boldSystemFont(ofSize: 13)
    axTitle.frame = NSRect(x: 24, y: 190, width: 120, height: 22)
    cv.addSubview(axTitle)
    let axDesc = NSTextField(labelWithString: "用于监听鼠标中键双击")
    axDesc.font = .systemFont(ofSize: 11)
    axDesc.textColor = .secondaryLabelColor
    axDesc.frame = NSRect(x: 24, y: 170, width: 240, height: 18)
    cv.addSubview(axDesc)
    let axLabel = NSTextField(labelWithString: "")
    axLabel.tag = 11
    axLabel.font = .systemFont(ofSize: 12)
    axLabel.frame = NSRect(x: 24, y: 148, width: 280, height: 20)
    cv.addSubview(axLabel)
    let axBtn = NSButton(title: "去授权", target: setupBridge, action: #selector(SetupBridge.openAccessibility))
    axBtn.frame = NSRect(x: 330, y: 168, width: 120, height: 32)
    axBtn.bezelStyle = .rounded
    cv.addSubview(axBtn)

    // 输入监控行
    let imTitle = NSTextField(labelWithString: "输入监控")
    imTitle.font = .boldSystemFont(ofSize: 13)
    imTitle.frame = NSRect(x: 24, y: 112, width: 120, height: 22)
    cv.addSubview(imTitle)
    let imDesc = NSTextField(labelWithString: "用于向接收器发送切换指令")
    imDesc.font = .systemFont(ofSize: 11)
    imDesc.textColor = .secondaryLabelColor
    imDesc.frame = NSRect(x: 24, y: 92, width: 240, height: 18)
    cv.addSubview(imDesc)
    let imLabel = NSTextField(labelWithString: "")
    imLabel.tag = 12
    imLabel.font = .systemFont(ofSize: 12)
    imLabel.frame = NSRect(x: 24, y: 70, width: 280, height: 20)
    cv.addSubview(imLabel)
    let imBtn = NSButton(title: "去授权", target: setupBridge, action: #selector(SetupBridge.openInputMonitoring))
    imBtn.frame = NSRect(x: 330, y: 90, width: 120, height: 32)
    imBtn.bezelStyle = .rounded
    cv.addSubview(imBtn)

    let hint = NSTextField(labelWithString: "打开后可自动检测，无需回来点确认。手动切 A/B 不受授权影响。")
    hint.tag = 20
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = .secondaryLabelColor
    hint.frame = NSRect(x: 24, y: 38, width: 430, height: 18)
    cv.addSubview(hint)

    let recheckBtn = NSButton(title: "重新检测", target: setupBridge, action: #selector(SetupBridge.recheck))
    recheckBtn.frame = NSRect(x: 24, y: 8, width: 110, height: 26)
    recheckBtn.bezelStyle = .rounded
    cv.addSubview(recheckBtn)
    let skipBtn = NSButton(title: "稍后设置", target: setupBridge, action: #selector(SetupBridge.skip))
    skipBtn.frame = NSRect(x: 140, y: 8, width: 110, height: 26)
    skipBtn.bezelStyle = .rounded
    cv.addSubview(skipBtn)

    gSetupWindow = win
    setupRefresh()
    win.center()
    // LSUIElement（无 Dock）App 的 activate() 常常无效，必须：
    // 1) 临时切到 regular 让它能成为前台 App；2) orderFrontRegardless 强制置顶
    NSApp.setActivationPolicy(.regular)
    NSApp.unhide(nil)
    win.makeKeyAndOrderFront(nil)
    win.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    // 强制置前：临时用浮动层级确保不被其他窗口盖住，1 秒后恢复普通层级
    win.level = .floating
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { win.level = .normal }
    print("[setup] 窗口已显示: isVisible=\(win.isVisible) isKey=\(win.isKeyWindow) frontmost=\(NSApp.isActive)")
    // 用户点红叉关闭时也要切回无 Dock 模式
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in
        gSetupPoll?.invalidate(); gSetupPoll = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // 每 1.5 秒自动检测，用户授权完回来无需操作
    gSetupPoll?.invalidate()
    gSetupPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
        setupRecheck()
    }
    print("[setup] 已显示首次授权引导窗口")
}

private func barStatusText() -> String {
    let needSetup = !gAXGranted || !gIMGranted
    if needSetup { return "⚠️ 需要授权（点「授权设置」）" }
    var parts: [String] = [gBarServiceOn ? "服务：运行中" : "服务：已停止"]
    if let s = gSelfChannel { parts.append("本机 \(barDeviceName(UInt8(clamping: s)))") }
    if let t = gLastTarget {
        parts.append("上次→\(barDeviceName(t))")
    } else if let t = gCtrlUpChannel {
        parts.append("双击→\(barDeviceName(t))")
    }
    return parts.joined(separator: " · ")
}

private func barRefreshUI() {
    gBarItem?.button?.title = ""
    // 缺任一授权时显示橙色，提示还需设置；否则按服务开关显示绿/灰
    let needSetup = !gAXGranted || !gIMGranted
    gBarItem?.button?.image = barMouseImage(active: needSetup ? true : gBarServiceOn,
                                            tint: needSetup ? .systemOrange : nil)
    gBarItem?.button?.toolTip = needSetup
        ? "MT760：需要授权（点此打开设置）"
        : (gBarServiceOn ? "MT760：服务运行中（点此开关）" : "MT760：服务已停止（点此开关）")
    gBarStatusMenuItem?.title = barStatusText()
    gBarToggleMenuItem?.title = gBarServiceOn ? "停止服务" : "启动服务"
}

/// 按配置重建「切换设备」子菜单。
/// 设备清单来自 mappings.json，加一台设备只要往 devices 里加一项，不用重新编译/打包。
private func rebuildDeviceMenu() {
    guard let menu = gDeviceMenu else { return }
    menu.removeAllItems()

    let selfCh = gSelfChannel
    var shortcut = 1
    for d in gDevices {
        guard d.channel >= 1, d.channel <= 255 else { continue }
        let isSelf = (selfCh == d.channel)
        let note = d.note.map { " · \($0)" } ?? ""
        let title = isSelf ? "\(d.name)（本机，信道 \(d.channel)）\(note)"
                           : "切到 \(d.name)（信道 \(d.channel)）\(note)"
        let it = NSMenuItem(title: title, action: isSelf ? nil : #selector(BarBridge.switchToDevice),
                            keyEquivalent: "")
        if !isSelf {
            it.target = barBridge
            it.representedObject = NSNumber(value: d.channel)
            if shortcut <= 9 {
                it.keyEquivalent = "\(shortcut)"
                it.keyEquivalentModifierMask = [.command, .option]
                shortcut += 1
            }
        } else {
            it.isEnabled = false
        }
        menu.addItem(it)
    }

    if gDevices.isEmpty {
        // 没配 devices：退回按信道直选，保证工具在任何配置下都可用
        let hint = NSMenuItem(title: "未配置设备清单（可在 mappings.json 添加 devices）", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    menu.addItem(NSMenuItem.separator())
    let head = NSMenuItem(title: "任意信道（先试再登记）", action: nil, keyEquivalent: "")
    head.isEnabled = false
    menu.addItem(head)
    for ch in 1...4 {
        let it = NSMenuItem(title: "切到信道 \(ch)", action: #selector(BarBridge.switchToDevice), keyEquivalent: "")
        it.target = barBridge
        it.representedObject = NSNumber(value: ch)
        menu.addItem(it)
    }

    menu.addItem(NSMenuItem.separator())
    let reload = NSMenuItem(title: "重新读取配置", action: #selector(BarBridge.reloadConfig), keyEquivalent: "")
    reload.target = barBridge
    menu.addItem(reload)
}

private final class BarBridge: NSObject {
    @objc func toggleService() {
        gBarServiceOn = !gBarServiceOn
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: gBarServiceOn) }
        print("[bar] 服务已\(gBarServiceOn ? "启动" : "停止")")
        barRefreshUI()
    }
    @objc func switchToDevice(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        let ch = UInt8(truncating: num)
        barSendChannel(ch, "菜单栏 → \(barDeviceName(ch))")
    }
    @objc func reloadConfig() {
        loadConfig(gConfigPath)
        print("[bar] 配置已重新读取：\(describeDevices())")
        barRefreshUI()
    }
    @objc func reopen() {
        gCmdDevice = findCmdDevice()
        print(gCmdDevice != nil ? "[bar] 指令通道已就绪" : "[bar] 仍打不开 0xBA —— 检查输入监控授权")
        barRefreshUI()
    }
    @objc func openSetup() { barShowSetup(keepOpen: true) }
    @objc func runDiag() { startMouseDiag(seconds: 20) }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - 中键硬件诊断
// 直接打开接收器的鼠标接口（usagePage=1 usage=2）读原始输入报文，
// 打印按键位图的变化。用来区分两种情况：
//   硬件根本没发中键（报文位图不变） vs 硬件发了但被系统/别的软件吃掉了。
// 标准 boot mouse 报文的第 1 字节是按键位图：bit0 左键、bit1 右键、bit2 中键。
private var gDiagDevices: [IOHIDDevice] = []
private var gDiagBuffers: [UnsafeMutablePointer<UInt8>] = []
private var gDiagUsagePtrs: [UnsafeMutablePointer<Int32>] = []
private var gDiagActive = false
private var gDiagT0: Date?
private func diagMs() -> Int {
    guard let t0 = gDiagT0 else { return 0 }
    return Int(Date().timeIntervalSince(t0) * 1000)
}
private var gDiagLastBitmap: [String: UInt8] = [:]
private var gDiagBudget = 150

private func stopMouseDiag() {
    for d in gDiagDevices {
        IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    gDiagDevices.removeAll()
    for b in gDiagBuffers { b.deallocate() }
    gDiagBuffers.removeAll()
    for p in gDiagUsagePtrs { p.deallocate() }
    gDiagUsagePtrs.removeAll()
    gDiagActive = false
}

private func startMouseDiag(seconds: Int = 20) {
    if gDiagActive {
        print("[diag] 诊断已在进行中，请稍等它结束")
        return
    }
    gDiagLastBitmap.removeAll()
    gDiagBudget = 150
    gDiagActive = true
    gDiagT0 = Date()
    gDiagDevices.removeAll()
    print("[diag] ===== 中键硬件诊断开始（\(seconds) 秒）=====")
    print("[diag] 请现在用鼠标连点几下中键（滚轮垂直按下），也顺便点一下左键/右键做对照")

    guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else {
        gDiagActive = false
        return
    }
    matching["VendorID"] = 9390  // 0x24AE Rapoo
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(rapooIOMainPort, matching as CFDictionary, &iterator) == kIOReturnSuccess else {
        gDiagActive = false
        print("[diag] 无法枚举 HID 设备")
        return
    }
    defer { IOObjectRelease(iterator) }

    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { continue }
        let usagePage = props["PrimaryUsagePage"] as? Int ?? -1
        let usage = props["PrimaryUsage"] as? Int ?? -1
        // 只看鼠标接口（1/2）和键盘类接口（1/6，中键有可能被上报到这里）
        guard usagePage == 1, usage == 2 || usage == 6 else { continue }
        guard let d = IOHIDDeviceCreate(nil, service) else { continue }
        let ret = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        print("[diag] 打开 usagePage=1 usage=\(usage) → status \(ret)")
        guard ret == kIOReturnSuccess else { continue }
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        let usagePtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        usagePtr.pointee = Int32(usage)
        IOHIDDeviceRegisterInputReportCallback(d, buf, 64, { ctx, _, _, _, reportID, report, len in
            guard gDiagBudget > 0 else { return }
            let n = min(Int(len), 16)
            guard n >= 1 else { return }
            let u = ctx?.load(as: Int32.self) ?? 0
            // 标准鼠标报文（reportID 0）只在按键位图变化时打印，避免移动事件刷屏
            let bitmap: UInt8 = (reportID == 0) ? report[0] : (n >= 2 ? report[1] : 0)
            let key = "\(u)-\(reportID)"
            if reportID == 0 {
                guard bitmap != (gDiagLastBitmap[key] ?? 0) else { return }
            }
            gDiagLastBitmap[key] = bitmap
            gDiagBudget -= 1
            let bytes = (0..<n).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
            print(String(format: "[diag +%dms] u=%d report 0x%02x len=%ld bitmap=0x%02x : %@",
                         diagMs(), u, reportID, len, bitmap, bytes))
        }, usagePtr)
        gDiagDevices.append(d)
        gDiagBuffers.append(buf)
        gDiagUsagePtrs.append(usagePtr)
    }

    if gDiagDevices.isEmpty {
        print("[diag] 没有可打开的接口 —— 检查输入监控授权")
        gDiagActive = false
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds)) {
        stopMouseDiag()
        print("[diag] ===== 诊断结束（\(seconds) 秒）=====")
    }
}
private let barBridge = BarBridge()

private final class BarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()

        let status = NSMenuItem(title: "服务：运行中（中键双击切屏）", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        gBarStatusMenuItem = status

        let toggle = NSMenuItem(title: "停止服务", action: #selector(BarBridge.toggleService), keyEquivalent: "")
        toggle.target = barBridge
        menu.addItem(toggle)
        gBarToggleMenuItem = toggle

        menu.addItem(NSMenuItem.separator())
        // 设备清单来自配置，菜单项动态生成：以后加设备只改 mappings.json，不用重编译
        let devRoot = NSMenuItem(title: "切换设备", action: nil, keyEquivalent: "")
        let devSub = NSMenu(title: "切换设备")
        devRoot.submenu = devSub
        menu.addItem(devRoot)
        gDeviceMenu = devSub
        rebuildDeviceMenu()

        menu.addItem(NSMenuItem.separator())
        let reopen = NSMenuItem(title: "重新打开指令通道", action: #selector(BarBridge.reopen), keyEquivalent: "")
        reopen.target = barBridge
        menu.addItem(reopen)
        let setup = NSMenuItem(title: "授权设置…", action: #selector(BarBridge.openSetup), keyEquivalent: "")
        setup.target = barBridge
        menu.addItem(setup)
        let diag = NSMenuItem(title: "中键硬件诊断（20 秒）", action: #selector(BarBridge.runDiag), keyEquivalent: "")
        diag.target = barBridge
        menu.addItem(diag)
        let q = NSMenuItem(title: "退出", action: #selector(BarBridge.quit), keyEquivalent: "q")
        q.target = barBridge
        menu.addItem(q)

        item.menu = menu
        menu.delegate = self
        gBarItem = item
        barRefreshUI()
    }

    /// 每次打开菜单：先看配置文件有没有被改过（改完 JSON 免重启），再重建设备菜单。
    /// 协议只能「指定切到哪个信道」，没有查询/枚举接口，所以设备清单必须由配置驱动。
    func menuWillOpen(_ menu: NSMenu) {
        if configChangedOnDisk() {
            print("[bar] 检测到配置改动，自动重新加载")
            loadConfig(gConfigPath)
        }
        rebuildDeviceMenu()
        barRefreshUI()
    }
}

/// 单实例锁：菜单栏组件全局只允许一个进程存在。
/// 之前 postinstall 用 `open -n` 强开新实例却没清掉旧进程，导致两个进程各建一套
/// CGEventTap、各自占用 0xBA 通道互相打架——正是在另一台机器上报「没切成功」的根因。
/// 用 flock 文件锁，任何来源（项目目录旧版 / /Applications 新版 / LaunchAgent）都抢同一把锁；
/// 拿不到锁就直接退出，让已在运行的实例继续服务。
private var gSingleLockFD: Int32 = -1
private func acquireSingleInstance() -> Bool {
    let path = "/tmp/rapookeys.single.lock"
    let fd = open(path, O_CREAT | O_RDWR, 0o666)
    guard fd >= 0 else { return true }  // 锁文件都建不了就放行，不至于起不来
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return false
    }
    gSingleLockFD = fd  // 持有 fd 直到进程退出，锁随之自动释放
    return true
}

private func runBar(forceSetup: Bool = false) {
    if !acquireSingleInstance() {
        print("[bar] 已有 MT760 菜单栏实例在运行，本实例退出（避免多进程抢事件 / 抢 0xBA 通道）")
        exit(0)
    }
    print("[bar] build=2026-11-18T2045 pid=\(getpid()) single-instance=on synthetic-tag=userData private-source=on hid-diag=on dynamic-devices=on")
    setvbuf(stdout, nil, _IONBF, 0)
    loadConfig(nil)

    // 首次运行：检测两项授权，缺任一项就弹引导窗口（可一键打开对应系统设置面板）
    gAXGranted = barAXGranted()
    gIMGranted = barIMGranted()
    if !gAXGranted || !gIMGranted {
        print("[bar] 检测到授权不完整：辅助功能=\(gAXGranted) 输入监控=\(gIMGranted)，稍后自动弹出设置引导")
    } else {
        print("[bar] 授权齐备（辅助功能 + 输入监控）")
    }
    if gCmdDevice == nil {
        print("[bar] 0xBA 通道暂不可用（输入监控授权后点菜单栏「授权设置」或「重新打开指令通道」）")
    }

    // 建立事件监听（服务关闭时只是禁用 tap，不销毁，避免反复触发 TCC 授权）
    // 键盘事件也纳入监听：用于诊断「鼠标按键被固件映射成键盘组合键」的情况
    var mask: CGEventMask = 0
    for t in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
              .otherMouseDown, .otherMouseUp, .keyDown, .keyUp] {
        mask |= CGEventMask(1 << t.rawValue)
    }
    let opts = CGEventTapOptions(rawValue: 0)!
    var tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: opts,
                                eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
    if tap == nil {
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: opts,
                                eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
    }
    if let t = tap {
        gTap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: t, enable: gBarServiceOn)
    } else {
        print("[bar] 警告：无法建立事件监听，中键双击不可用")
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // 无 Dock 图标，纯菜单栏组件
    let delegate = BarAppDelegate()
    app.delegate = delegate
    let dbl = gDoubleSwitchButtons.map { "button\($0.key)→ch\($0.value)" }.sorted().joined(separator: ",")
    let ctrlUp = gCtrlUpChannel.map { "双击 Ctrl+↑→ch\($0)" } ?? "(未启用)"
    print("[bar] 菜单栏组件已启动：服务默认开启；设备 \(describeDevices())；本机 \(gSelfChannel.map { "信道 \($0)" } ?? "未指定")")
    print("[bar] 触发器：双击 \(dbl.isEmpty ? "(无)" : dbl)；\(ctrlUp)")
    print("[bar] 菜单可停止/启动服务、手动切 A/B、授权设置；Ctrl+C 或菜单「退出」结束")

    // 延迟 1 秒弹出授权引导（等 run loop 与状态栏就绪，LSUIElement 才能正确 activate）
    if !gAXGranted || !gIMGranted || forceSetup {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            barShowSetup(keepOpen: forceSetup)
        }
    }
    app.run()
}

// 兼容旧 mode 名 ui：转到 bar
private func runUI() { runBar() }

// MARK: - main
setvbuf(stdout, nil, _IONBF, 0)
// 以 App 方式启动（无终端）时，把输出写到日志文件，方便 tail 查看
if isatty(STDOUT_FILENO) == 0 {
    let logPath = String(format: "/tmp/rapookeys-%d.log", getpid())
    freopen(logPath, "a", stdout)
    setvbuf(stdout, nil, _IONBF, 0)
}
let args = CommandLine.arguments
print("[debug] args: \(args)")
// open/LaunchServices 启动会附加 -psn 参数，扫描已知模式名而不是按位置取
let knownModes = ["sniff", "hid-probe", "hid-cmd", "bar", "ui", "setup"]
var mode = args.dropFirst().first(where: { knownModes.contains($0) }) ?? "sniff"
var fileArgs: [String] = []
// open 启动无法传参，通过模式文件下发：内容形如 "hid-cmd monitor" / "hid-probe --open --seize"
if mode == "sniff" {
    let modeFile = "/tmp/rapookeys.mode"
    if let s = try? String(contentsOfFile: modeFile, encoding: .utf8) {
        try? FileManager.default.removeItem(atPath: modeFile)
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).map(String.init)
        if let m = parts.first, knownModes.contains(m) {
            mode = m
            fileArgs = parts
        }
    }
}

if mode == "bar" || mode == "ui" {
    runBar(forceSetup: false)
    exit(0)
}
if mode == "setup" {
    runBar(forceSetup: true)
    exit(0)
}

if mode == "hid-probe" {
    let allArgs = args + fileArgs
    let openDevices = allArgs.contains("--open")
    gSeize = allArgs.contains("--seize")
    gPoke = allArgs.contains("--poke")
    print("[info] raw HID access needs Input Monitoring permission for this binary.")
    runHIDProbe(openDevices: openDevices)
    exit(0)
}

if mode == "hid-cmd" {
    let knownOps = ["devices", "info", "status", "release", "resync", "claim", "pull", "open-window", "handoff", "watch", "monitor", "lan-on", "lan-off", "reg", "jump", "version", "chan"]
    let op = fileArgs.dropFirst().first(where: { knownOps.contains($0) })
            ?? args.dropFirst(2).first(where: { knownOps.contains($0) })
            ?? "status"
    print("[cmd] op=\(op) (mode file: \(fileArgs))")
    runCommand(op)
}

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
if !trusted {
    print("[warn] Accessibility permission is off. Grant it in:")
    print("       系统设置 → 隐私与安全性 → 辅助功能 → + 选择本程序")
    print("       Then quit and run again.")
}

loadConfig(args.count > 2 ? args[2] : nil)

// 侧键切屏需要 0xBA 写入通道（需输入监控授权），在建立事件监听前先打开
if !gSwitchButtons.isEmpty || !gDoubleSwitchButtons.isEmpty {
    let clickDesc = gSwitchButtons.map { "单击button\($0.key)→ch\($0.value)" }.sorted().joined(separator: ", ")
    let dblDesc = gDoubleSwitchButtons.map { "双击button\($0.key)→ch\($0.value)" }.sorted().joined(separator: ", ")
    let desc = [clickDesc, dblDesc].filter { !$0.isEmpty }.joined(separator: " | ")
    gCmdDevice = findCmdDevice()
    if gCmdDevice != nil {
        print("[ok] 按键切屏就绪: \(desc)")
    } else {
        print("[warn] 无法打开 0xBA 通道，按键切屏不可用（检查输入监控授权）")
    }
}

var mask: CGEventMask = 0
for t in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
          .otherMouseDown, .otherMouseUp, .scrollWheel] {
    mask |= CGEventMask(1 << t.rawValue)
}

let tapOptions = CGEventTapOptions(rawValue: 0)!
var tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: tapOptions,
                            eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
if tap == nil {
    print("[info] kCGHIDEventTap unavailable, falling back to session tap")
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: tapOptions,
                            eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
}
guard let tap else {
    print("[error] CGEventTapCreate failed — check Accessibility permission / run as root")
    exit(1)
}
gTap = tap
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("[ok] listening. Press mouse buttons; Ctrl+C to quit.")
print("[tip] no mappings.json = sniff mode only (events are printed, not changed).")
RunLoop.current.run()

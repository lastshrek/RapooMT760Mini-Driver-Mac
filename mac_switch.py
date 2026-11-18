"""Rapoo MT760 Mini — Mac 端切换指令脚本（骨架）

用法：
  python3 mac_switch.py status          # 轮询鼠标状态
  python3 mac_switch.py release         # 释放当前连接（鼠标自由 ~2s 后回连）
  python3 mac_switch.py resync          # 跳转到本机接收器地址（强制重连）
  python3 mac_switch.py claim           # 驱动同款 swap 广播序列 af→ae×5→af
  python3 mac_switch.py pair            # 进入配对模式

依赖：pyusb 或 hidapi（mac 上建议 hidapi：pip install hidapi）
      接收器 mi_01 collection（Usage Page 0xFF00，Report ID 0xBA，32 字节）。

⚠ Mac 端传输层尚未实测：
  - 本脚本假设你能打开接收器的 0xFF00/32B 接口（Windows 上为 mi_01&col04）
  - 若 hidapi 枚举不到，改用 IOKit HIDSetReport（Output, reportID=0xBA）
  - 你项目里已验证的 0xFF01/29B 接口是另一个 collection，可作为备选通道测试
"""

import sys
import time

# ====== 传输层（按你的 Mac 驱动现有实现接入） ======
# 两个候选接口：
#   接口 A：Usage Page 0xFF00, IN/OUT 32 字节  ← Windows 驱动用的通道（推荐先试）
#   接口 B：Usage Page 0xFF01, IN/OUT 29 字节  ← 你已验证可写的通道
VENDOR_ID = 0x24AE
PRODUCT_ID = 0x1871          # 接收器
REPORT_ID = 0xBA
REPORT_SIZE = 32


def open_dongle():
    """打开接收器的 0xFF00 厂商接口，返回 handle 或 None。"""
    try:
        import hid  # pip install hidapi (Windows/Mac 通用 API)
    except ImportError:
        print("!! 需要 hidapi: pip install hidapi")
        return None
    for dev in hid.enumerate(VENDOR_ID, PRODUCT_ID):
        # 选择 usage_page=0xFF00 且 out report 32 字节的接口
        # hidapi 不直接暴露 usage page，可用路径特征或逐一尝试
        path = dev["path"]
        if b"mi_01" in path or b"col04" in path or True:
            h = hid.device()
            h.open_path(path)
            return h
    return None


def send(h, payload):
    """发送 32 字节 Output Report（Report ID 0xBA）。"""
    data = bytes(payload[:REPORT_SIZE])
    data += bytes(REPORT_SIZE - len(data))
    # hidapi: write() 的第一个字节是 report id
    return h.write(data) == REPORT_SIZE


def rep(head):
    b = bytes(head)
    return b + bytes(REPORT_SIZE - len(b))


# ====== 指令构造（字节序已验证，见 rapoo_protocol.md） ======
def cmd_status():
    return rep([0xBA, 0xA5, 0xA1, 0x01])


def cmd_window_open():
    return rep([0xBA, 0xA5, 0xAF])


def cmd_release():
    """释放鼠标（目标=空）。从当前持有方接收器发出。"""
    return rep([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0xFF, 0x00])


def cmd_hop(addr_le4):
    """命令鼠标跳转到 RF 地址（小端 4 字节）。"""
    return rep([0xBA, 0xA5, 0xAE] + list(addr_le4))


def cmd_reg(reg, val):
    return rep([0xBA, 0xA5, 0xA4, reg, val])


def cmd_commit():
    return rep([0xBA, 0xA5, 0xA3])


# ====== 高层动作 ======

# 本机接收器的 RF 地址（小端）。Mac 接收器的地址需在 Mac 端读出后填入：
# 读取方式：抓 Mac 端驱动/本脚本与接收器的握手流量，或从鼠标 RF 槽位表读出。
LOCAL_DONGLE_ADDR = bytes([0x00, 0x00, 0x00, 0x00])   # TODO: 填 Mac 接收器地址


def do_status(h):
    send(h, cmd_status())
    # 应答在 IN 端点，需要起一个读线程；此处仅示意
    print("status poll sent（应答需异步读取 IN report）")


def do_release(h, times=1, gap=1.0):
    """释放鼠标：发出后鼠标断开 ~2s，随后自动回连本接收器。"""
    for _ in range(times):
        send(h, rep([0xBA, 0xA5, 0xAF]))
        time.sleep(0.2)
        send(h, cmd_release())
        time.sleep(gap)
    send(h, rep([0xBA, 0xA5, 0xAF]))
    print("release done（鼠标会短暂掉线后回连）")


def do_resync(h):
    """跳转到本机接收器地址 = 强制重新握手。
    注意：af 开窗后需保持打开 1~2s，过早关窗会取消跳转。"""
    send(h, rep([0xBA, 0xA5, 0xAF]))
    time.sleep(0.2)
    send(h, cmd_hop(LOCAL_DONGLE_ADDR))
    time.sleep(2.0)
    send(h, rep([0xBA, 0xA5, 0xAF]))
    print("resync done")


def do_claim(h, times=5, gap=1.0):
    """驱动同款 swap 广播序列：af → ae×5 → af。
    单端执行时另一台电脑的驱动必须同步配合（见协议文档结论 4）。"""
    send(h, rep([0xBA, 0xA5, 0xAF]))
    for _ in range(times):
        send(h, cmd_release())
        time.sleep(gap)
    send(h, rep([0xBA, 0xA5, 0xAF]))
    print("claim sequence done")


def do_pair(h):
    """进入配对模式（窗口仅约 9 秒）。"""
    send(h, rep([0xBA, 0xA0, 0x81, 0x01, 0x01]
                + [0xFF] * 8 + [0xC8, 0x00] + [0x00] * 10 + [0xB0, 0x66, 0x95]))
    print("enter pair sent（9 秒窗口，请让鼠标绿灯频闪后执行）")


def main():
    op = sys.argv[1] if len(sys.argv) > 1 else "status"
    h = open_dongle()
    if not h:
        print("!! 打不开接收器厂商接口")
        return
    try:
        if op == "status":
            do_status(h)
        elif op == "release":
            do_release(h)
        elif op == "resync":
            do_resync(h)
        elif op == "claim":
            do_claim(h)
        elif op == "pair":
            do_pair(h)
        else:
            print(__doc__)
    finally:
        h.close()


if __name__ == "__main__":
    main()

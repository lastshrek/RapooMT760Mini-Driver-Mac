"""win_switch.py — Windows 端释放/认领鼠标（配合 Mac 端 hid-cmd claim 使用）

用法（在 Windows 上，接收器插好、驱动可开着可关着）：
  pip install hidapi   （如果还没装）
  python win_switch.py release    # 释放鼠标（持有方执行）
  python win_switch.py claim      # 认领鼠标（切换到 Windows 时用）

协议依据：rapoo_protocol.md（Report ID 0xBA，32 字节，通道字节 a5）
"""

import sys
import time

VENDOR_ID = 0x24AE
PRODUCT_ID = 0x1871

# Windows 接收器的 RF 地址（小端），来自鼠标槽位表 0x44B0076A
WIN_DONGLE_ADDR = [0x6A, 0x07, 0xB0, 0x44]


def open_dongle():
    import hid
    for dev in hid.enumerate(VENDOR_ID, PRODUCT_ID):
        h = hid.device()
        try:
            h.open_path(dev["path"])
            return h
        except Exception as e:
            print("open fail:", e)
    return None


def send(h, payload):
    data = bytes(payload) + bytes(32 - len(payload))
    return h.write(data)


def ba(head):
    return list(head)


def do_release(h):
    """持有方释放：af 开窗保持期间发 3 次 ae 空目标，再关窗"""
    send(h, ba([0xBA, 0xA5, 0xAF]))
    time.sleep(0.2)
    for i in range(3):
        send(h, ba([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0xFF, 0x00]))
        time.sleep(1.0)
    send(h, ba([0xBA, 0xA5, 0xAF]))
    print("release done — 鼠标应已离开本接收器")


def do_claim(h):
    """认领：开窗 20s，每 1s 跳转到本机地址（配合 Mac 端 release）"""
    print("claim 窗口开启 20 秒 — 请在 Mac 上执行 hid-cmd release！")
    send(h, ba([0xBA, 0xA5, 0xAF]))
    time.sleep(0.2)
    for i in range(18):
        send(h, ba([0xBA, 0xA5, 0xAE] + WIN_DONGLE_ADDR))
        time.sleep(1.0)
    send(h, ba([0xBA, 0xA5, 0xAF]))
    print("claim done")


if __name__ == "__main__":
    op = sys.argv[1] if len(sys.argv) > 1 else ""
    h = open_dongle()
    if not h:
        print("!! 打不开接收器（检查接收器是否插好、hidapi 是否安装）")
        sys.exit(1)
    if op == "release":
        do_release(h)
    elif op == "claim":
        do_claim(h)
    else:
        print(__doc__)
    h.close()

# -*- coding: utf-8 -*-
"""
MT760 mini 切屏 - Windows 系统托盘小工具
=========================================
B 机切到 Windows（Boot Camp）时运行本程序，托盘菜单即可把鼠标切到 A(macOS)
或切回本机。协议与 Mac 端完全一致：

    ba a5 ae 00 00 00 00 [信道] 00 ...   （32 字节，index 7 = 信道）
    信道号与设备名的对应关系写在 devices.json（默认 1=A、2=B、3=Windows）

用法：
    python mt760_tray.py             启动托盘（默认）
    python mt760_tray.py chan 1      命令行方式切到 A（不启动托盘）
    python mt760_tray.py selftest    枚举接收器接口并逐个试写，排查用

依赖（首次运行 install.bat 已装好）：
    pip install hidapi pystray Pillow
"""

import sys
import time
import json
import threading
from pathlib import Path

VID = 0x24AE
PID = 0x1871

BASE = Path(__file__).resolve().parent


# ---------- 设备清单 ----------
# 与 macOS 端共用同一份 devices.json：加设备只改这个文件，两台机器都会跟着变。
# 本机身份（这台 Windows 在哪个信道）单独放在 self.json，避免清单里混入"我是谁"。
def _read_json(p):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def load_devices():
    for p in (BASE / "devices.json", BASE.parent / "devices.json",
              BASE / "mappings.json", BASE.parent / "mappings.json"):
        data = _read_json(p)
        if not isinstance(data, dict):
            continue
        raw = data.get("devices")
        if not isinstance(raw, list):
            continue
        out = []
        for d in raw:
            try:
                ch = int(d.get("channel"))
            except Exception:
                continue
            if 1 <= ch <= 255 and d.get("name"):
                item = {"name": str(d["name"]), "channel": ch}
                if d.get("note"):
                    item["note"] = str(d["note"])
                out.append(item)
        if out:
            return sorted(out, key=lambda x: x["channel"])
    return [{"name": "A", "channel": 1}, {"name": "B", "channel": 2}]


def load_self_channel():
    for p in (BASE / "self.json", BASE / "mappings.json", BASE.parent / "mappings.json"):
        data = _read_json(p)
        if isinstance(data, dict) and isinstance(data.get("selfChannel"), int):
            return data["selfChannel"]
    return 3


# ---------- HID 通道 ----------
def _iter_devices():
    import hid
    for d in hid.enumerate(VID, PID):
        yield d


def _open_preferred():
    """优先打开 usagePage=1 / usage=6（0xBA 指令通道），失败再退回其它接口。"""
    import hid
    devs = list(_iter_devices())
    # 排序：usage=6 排最前
    devs.sort(key=lambda d: (0 if (d.get("usage_page") == 1 and d.get("usage") == 6) else 1))
    tried = []
    for d in devs:
        h = hid.device()
        try:
            h.open_path(d["path"])
            return h, d
        except Exception as e:
            tried.append("%s/%s:%s" % (d.get("usage_page"), d.get("usage"), e))
            try:
                h.close()
            except Exception:
                pass
    return None, tried


def send_channel(ch, times=3, gap=0.35, verbose=True):
    h, info = _open_preferred()
    if h is None:
        msg = "打不开接收器。检查：接收器是否插好、是否被雷柏官方驱动(A HUB)独占。"
        if verbose:
            print("[err] " + msg)
            print("[err] 尝试过的接口: " + ", ".join(info if isinstance(info, list) else []))
        return False, msg
    frame = bytes([0xBA, 0xA5, 0xAE, 0x00, 0x00, 0x00, 0x00, ch] + [0x00] * 24)
    try:
        for i in range(times):
            n = h.write(frame)
            if verbose:
                print("[tx] ch=%d #%d -> write=%d" % (ch, i + 1, n))
            if i < times - 1:
                time.sleep(gap)
        return True, "已发送切换到信道 %d" % ch
    except Exception as e:
        msg = "写入失败: %s" % e
        if verbose:
            print("[err] " + msg)
        return False, msg
    finally:
        h.close()


def selftest():
    print("=== MT760 接收器自检 ===")
    found = False
    for d in _iter_devices():
        found = True
        print("[dev] usagePage=0x%04x usage=%d path=%s" % (
            d.get("usage_page", -1), d.get("usage", -1),
            d.get("path", b"").decode("utf-8", "replace")[:90]))
    if not found:
        print("[err] 没有枚举到 VID=0x24AE PID=0x1871 的接收器")
        return
    for ch in (1, 2):
        ok, msg = send_channel(ch, times=1, verbose=True)
        print("[test] ch%d: %s" % (ch, "OK" if ok else "FAIL"))
    print("自检结束。若写入报错被占用，请退出雷柏官方驱动后重试。")


# ---------- 托盘 ----------
def run_tray():
    import pystray
    from PIL import Image, ImageDraw

    def make_image(active=True):
        img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        dr = ImageDraw.Draw(img)
        color = (200, 60, 60, 255) if active else (120, 120, 120, 255)
        dr.rounded_rectangle((6, 18, 58, 46), radius=8, fill=color)
        dr.ellipse((12, 24, 24, 36), fill=(255, 255, 255, 255))
        dr.ellipse((40, 24, 52, 36), fill=(255, 255, 255, 255))
        return img

    state = {"busy": False}

    def to_channel(ch):
        def cb(icon, item):
            if state["busy"]:
                return
            state["busy"] = True
            threading.Thread(target=lambda: (send_channel(ch),
                                             icon.notify("已发送切换到信道 %d" % ch, "MT760"),
                                             state.update(busy=False)),
                             daemon=True).start()
        return cb

    def on_quit(icon, item):
        icon.stop()

    devices = load_devices()
    self_ch = load_self_channel()
    print("[tray] 设备清单: %s（本机=信道 %d）" %
          (", ".join("%s=%d" % (d["name"], d["channel"]) for d in devices), self_ch))

    status = pystray.MenuItem(
        "MT760 切屏 · 本机 信道 %d" % self_ch, lambda *a: None, enabled=False)

    dev_items = []
    for d in devices:
        ch = d["channel"]
        note = (" · " + d["note"]) if d.get("note") else ""
        if ch == self_ch:
            dev_items.append(pystray.MenuItem(
                "%s（信道 %d）%s · 本机" % (d["name"], ch, note), lambda *a: None, enabled=False))
        else:
            dev_items.append(pystray.MenuItem(
                "切到 %s（信道 %d）%s" % (d["name"], ch, note), to_channel(ch)))

    menu = pystray.Menu(
        status,
        pystray.Menu.SEPARATOR,
        *dev_items,
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("任意信道（先试再登记）", pystray.Menu(*[
            pystray.MenuItem("切到信道 %d" % n, to_channel(n)) for n in range(1, 5)
        ])),
        pystray.MenuItem("自检并打印日志", lambda icon, item: selftest()),
        pystray.MenuItem("退出", on_quit),
    )
    icon = pystray.Icon("MT760", make_image(), "MT760 切屏", menu)
    print("[tray] 托盘图标已启动。右键/左键点击图标可切换。")
    icon.run()


def main():
    args = sys.argv[1:]
    if args and args[0] == "chan" and len(args) >= 2:
        send_channel(int(args[1]))
    elif args and args[0] == "selftest":
        selftest()
    else:
        run_tray()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 rapookeys 配置（设备清单与行为配置分离，互不干扰）

用法：
    python3 gen_config.py <self_channel> <target_channel>   > mappings.json
    python3 gen_config.py --devices-only                    > devices.json

- devices 清单统一从 devices.json 读取（单一来源），加设备只改那一份。
- mappings.json 只写「行为」：按键映射、本机身份、双击目标，不重复存放设备清单，
  这样已经配好的机器升级时，原有字段不会被改动。
- switchTarget 若能在 devices 里对上就写设备名，否则写信道号。
- 同时保留 doubleSwitchButtons / ctrlUpDoubleSwitch，兼容旧版本逻辑。
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEVICES_FILE = os.path.join(HERE, "devices.json")

# 默认不做任何按键重映射：侧键/DIP 等保持鼠标原生的前进、后退行为。
# 需要自定义时，在 mappings.json 的 buttons 里加 {"3": {"keyCode": 33, "flags": 1048576}} 即可。
BUTTONS = {}


def load_devices():
    try:
        with open(DEVICES_FILE, encoding="utf-8") as f:
            data = json.load(f)
        out = []
        for d in data.get("devices", []):
            try:
                ch = int(d.get("channel", 0))
            except Exception:
                continue
            if 1 <= ch <= 255 and d.get("name"):
                item = {"name": str(d["name"]), "channel": ch}
                if d.get("note"):
                    item["note"] = str(d["note"])
                out.append(item)
        return sorted(out, key=lambda x: x["channel"])
    except FileNotFoundError:
        return []
    except Exception as e:
        print("devices.json 解析失败: %s" % e, file=sys.stderr)
        return []


def main():
    args = sys.argv[1:]
    if args and args[0] == "--devices-only":
        json.dump({"devices": load_devices()}, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0

    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    self_ch, target_ch = int(args[0]), int(args[1])
    devices = load_devices()
    name = next((d["name"] for d in devices if d["channel"] == target_ch), str(target_ch))
    cfg = {
        "buttons": BUTTONS,
        "selfChannel": self_ch,
        "switchTarget": name,
        "doubleSwitchButtons": {"2": target_ch},
        "ctrlUpDoubleSwitch": target_ch,
    }
    json.dump(cfg, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

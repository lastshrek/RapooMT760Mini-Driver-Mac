#!/usr/bin/env python3
"""Dump all Rapoo (VID 0x24AE) HID devices and decode their report descriptors.

Usage: python3 hid_dump.py
Run before/after switching the mouse between Bluetooth / 2.4G / wired,
then compare the outputs to see what changes.
"""
import base64
import plistlib
import re
import subprocess

VENDOR_ID = 9390  # 0x24AE Rapoo

SIZES = {0: 0, 1: 1, 2: 2, 3: 4}


def decode_descriptor(data: bytes) -> str:
    lines = []
    usage_page = None
    i = 0
    while i < len(data):
        item = data[i]
        tag = (item >> 4) & 0xF
        typ = (item >> 2) & 0x3
        sz = SIZES[item & 0x3]
        val = int.from_bytes(data[i + 1:i + 1 + sz], "little") if sz else None
        type_names = {0: "Main", 1: "Global", 2: "Local"}
        tag_names = {
            (1, 0): "UsagePage", (1, 7): "ReportSize", (1, 8): "ReportID",
            (1, 9): "ReportCount",
            (2, 0): "Usage", (2, 1): "UsageMin", (2, 2): "UsageMax",
            (0, 8): "Input", (0, 9): "Output", (0, 10): "Feature",
            (0, 11): "Collection", (0, 12): "EndCollection",
        }
        nm = tag_names.get((typ, tag))
        extra = ""
        if nm == "UsagePage":
            usage_page = val
        elif nm in ("Usage", "UsageMin", "UsageMax"):
            if usage_page == 9:
                extra = f" Button{val}"
            elif usage_page == 1:
                extra = f" Generic:{val:#04x}"
            elif usage_page == 0xC:
                extra = f" Consumer:{val:#06x}"
            elif usage_page == 0x7:
                extra = f" Key:{val:#04x}"
            elif usage_page == 0xFF00:
                extra = " Vendor"
        if nm == "Input" and val is not None:
            extra += " (Data,Var)" if (val & 1) == 0 and (val & 4) else " (Const)"
        if nm:
            lines.append(f"  {nm:14}{'' if val is None else hex(val):>8}{extra}")
        i += 1 + sz
    return "\n".join(lines)


def usb_info() -> str:
    out = subprocess.run(["system_profiler", "SPUSBDataType", "-json"],
                         capture_output=True, text=True).stdout
    hits = []
    def walk(node):
        if isinstance(node, dict):
            if "Rapoo" in str(node.get("_name", "")) or node.get("vendor_id") == "0x24ae":
                hits.append(node)
            for child in node.get("_items", []) or []:
                walk(child)
    try:
        data = plistlib.loads(out.encode()) if False else None
    except Exception:
        pass
    # system_profiler -json outputs JSON, not plist
    import json
    try:
        root = json.loads(out)
    except Exception:
        return "(no USB info)"
    for v in root.values():
        if isinstance(v, list):
            for item in v:
                walk(item)
    lines = []
    for h in hits:
        lines.append(f"USB: {h.get('_name')}  product_id={h.get('product_id')} "
                     f"vendor_id={h.get('vendor_id')}  transport={h.get('transport','-')}")
    return "\n".join(lines) or "(no Rapoo USB device found)"


def main():
    print("== USB (2.4G receiver / wired) ==")
    print(usb_info())
    print()
    out = subprocess.run(["ioreg", "-a", "-l", "-w", "0", "-r", "-c", "IOHIDDevice"],
                         capture_output=True, text=True).stdout
    devices = plistlib.loads(out.encode())
    found = 0
    for dev in devices:
        if dev.get("VendorID") != VENDOR_ID:
            continue
        found += 1
        print(f"== HID: {dev.get('Product')}  PID={hex(dev.get('ProductID', 0))} "
              f"Transport={dev.get('Transport', '?')} ==")
        rd = dev.get("ReportDescriptor")
        if rd:
            print(decode_descriptor(rd))
        else:
            print("  (no report descriptor visible)")
        print()
    if not found:
        print("No Rapoo HID device found in IORegistry.")


if __name__ == "__main__":
    main()

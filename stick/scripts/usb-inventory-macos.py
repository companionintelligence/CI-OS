#!/usr/bin/env python3
"""Read-only inventory of the USB mass-storage devices attached to a Mac.

Maps each whole disk (BSD name) to its USB serial number, vendor:product, negotiated link
speed and the chain of hubs it hangs off, so a batch of Companion Sticks can be identified
by serial (which survives replugging) rather than by `diskN` (which does not).

It runs `ioreg -a -r -c IOUSBHostDevice -l` and only reads. It never opens a disk node, never
mounts, unmounts, partitions or formats anything. It is NOT a flashing selector: `ci-stick
flash --device` is Linux-only, and the safety rule for batches is an explicit serial
allow-list (docs/architecture/mass-flashing.md, section 8.7).

Usage:
    stick/scripts/usb-inventory-macos.py                      # table of every USB disk
    stick/scripts/usb-inventory-macos.py --vidpid 13fe:6700   # only that product
    stick/scripts/usb-inventory-macos.py --json
    stick/scripts/usb-inventory-macos.py --allow sticks.tsv   # flag devices not on the allow-list
    stick/scripts/usb-inventory-macos.py --deny 74573870      # never list these serials as OK

`sticks.tsv` is `serial<TAB>label` per line ('#' comments allowed).
"""
import argparse
import json
import plistlib
import subprocess
import sys

# ioreg "USBSpeed" values as observed on Apple silicon (xHCI): 3 = High-Speed, 4 = SuperSpeed.
# The numeric `Device Speed` property is the older IOUSB enumeration (2 = High-Speed, 3 = SuperSpeed).
SPEED_NAMES = {2: "480 Mb/s", 3: "5 Gb/s", 4: "5 Gb/s", 5: "10 Gb/s"}


def load_ioreg():
    out = subprocess.run(
        ["ioreg", "-a", "-r", "-c", "IOUSBHostDevice", "-l"],
        check=True,
        capture_output=True,
    ).stdout
    return plistlib.loads(out) if out.strip() else []


def link_speed(node):
    bps = node.get("UsbLinkSpeed")
    if isinstance(bps, int) and bps > 0:
        return f"{bps / 1e9:g} Gb/s" if bps >= 1e9 else f"{bps / 1e6:g} Mb/s"
    code = node.get("USBSpeed", node.get("Device Speed"))
    return SPEED_NAMES.get(code, f"speed code {code}")


def walk(node, chain, rows):
    """Depth-first walk of the registry; `chain` is the USB devices above this node."""
    cls = node.get("IOObjectClass")
    if cls == "IOUSBHostDevice":   # interfaces carry copies of idVendor/idProduct; only devices count
        chain = chain + [node]
    if cls == "IOMedia" and node.get("Whole") and chain:
        dev = chain[-1]
        hubs = [
            "%04x:%04x" % (h.get("idVendor", 0), h.get("idProduct", 0)) for h in chain[:-1]
        ]
        rows.append(
            {
                "bsd": node.get("BSD Name"),
                "size_bytes": node.get("Size"),
                "vendor_product": "%04x:%04x" % (dev.get("idVendor", 0), dev.get("idProduct", 0)),
                "name": dev.get("USB Product Name") or dev.get("kUSBProductString") or "",
                "serial": str(dev.get("USB Serial Number") or dev.get("kUSBSerialNumberString") or ""),
                "speed": link_speed(dev),
                "location_id": "0x%08x" % dev["locationID"] if dev.get("locationID") else "",
                "hub_chain": hubs,
            }
        )
    for child in node.get("IORegistryEntryChildren", []):
        walk(child, chain, rows)


def read_allow(path):
    allow = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            serial, _, label = line.partition("\t")
            allow[serial.strip()] = label.strip()
    return allow


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vidpid", help="only devices with this vendor:product, e.g. 13fe:6700")
    ap.add_argument("--allow", metavar="FILE", help="serial<TAB>label allow-list; others are flagged")
    ap.add_argument("--deny", action="append", default=[], metavar="SERIAL", help="serial that must never be OK")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if sys.platform != "darwin":
        sys.exit("this helper reads macOS ioreg; on Linux use lsusb -t and udevadm (mass-flashing.md, 10.2)")

    rows = []
    for root in load_ioreg():
        walk(root, [], rows)
    if args.vidpid:
        rows = [r for r in rows if r["vendor_product"] == args.vidpid.lower()]
    rows.sort(key=lambda r: (r["speed"], r["location_id"], r["bsd"] or ""))

    allow = read_allow(args.allow) if args.allow else None
    for r in rows:
        if r["serial"] in args.deny:
            r["status"] = "DENIED"
        elif allow is not None:
            r["status"] = "ok" if r["serial"] in allow else "NOT ON ALLOW-LIST"
            r["label"] = allow.get(r["serial"], "")
        else:
            r["status"] = ""
    rows.sort(key=lambda r: (r["bsd"] or ""))

    if args.json:
        json.dump(rows, sys.stdout, indent=2)
        print()
        return
    print(f"{'DISK':8} {'SIZE (bytes)':>16} {'VID:PID':9} {'SERIAL':18} {'LINK':9} {'HUBS (root -> device)':28} STATUS")
    for r in rows:
        hubs = " > ".join(r["hub_chain"]) or "-"
        print(
            f"{r['bsd'] or '?':8} {r['size_bytes'] or 0:>16,} {r['vendor_product']:9} {r['serial']:18} "
            f"{r['speed']:9} {hubs:28} {r['status']}"
        )
    slow = [r for r in rows if r["speed"].endswith("Mb/s")]
    if slow:
        print(
            f"\n{len(slow)} device(s) are on a 480 Mb/s link. A SuperSpeed stick behind any USB 2 hub, or on a "
            "USB-A port without SuperSpeed lanes, trains at High-Speed."
        )


if __name__ == "__main__":
    main()

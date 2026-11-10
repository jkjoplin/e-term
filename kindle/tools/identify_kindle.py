#!/usr/bin/env python3
"""Confirm the Kindle on USB is the model and firmware you chose a jailbreak for.

Run it before copying any jailbreak or filler files, so they never land on a
different Kindle:

    kindle/tools/identify_kindle.py --serial-prefix G001PX --firmware 5.16.7

The serial prefix is the first six characters of the serial (Settings > Device
Options > Device Info). It names the model: G001PX is a Paperwhite 5. The firmware
is the version on the same page.

Exit 0 when both match. Exit 2 when the volume is missing. Exit 3 when a different
Kindle is attached.
"""
import argparse
import subprocess
import sys
from pathlib import Path

KINDLE = Path("/Volumes/Kindle")
VERSION = KINDLE / "system" / "version.txt"


def usb_serial() -> str:
    try:
        out = subprocess.check_output(
            ["ioreg", "-p", "IOUSB", "-w", "0", "-l"],
            text=True,
            errors="replace",
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        return f"(ioreg failed: {exc})"
    for line in out.splitlines():
        if "USB Serial Number" in line and "=" in line:
            return line.split("=", 1)[1].strip().strip('"')
    return "(no USB serial)"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--serial-prefix", required=True, help="first characters of the serial, such as G001PX")
    parser.add_argument("--firmware", required=True, help="firmware version, such as 5.16.7")
    args = parser.parse_args()
    serial = usb_serial()
    print(f"usb_serial={serial}")
    if not KINDLE.is_dir():
        print("volume=/Volumes/Kindle missing")
        print("Plug the Kindle in with a data cable and unlock it so macOS mounts the disk.")
        return 2
    text = VERSION.read_text(errors="replace").strip() if VERSION.exists() else "(no version.txt)"
    print(f"version={text}")
    try:
        free = subprocess.check_output(["df", "-Pm", str(KINDLE)], text=True)
        print(free.strip().splitlines()[-1])
    except subprocess.CalledProcessError as exc:
        print(f"df failed: {exc}")
    ok_serial = serial.startswith(args.serial_prefix)
    ok_version = args.firmware in text
    if ok_serial and ok_version:
        print(f"identity={args.serial_prefix} firmware {args.firmware}")
        return 0
    print("identity=DIFFERENT DEVICE")
    print("Stop. Do not copy jailbreak files or filler onto this volume.")
    return 3


if __name__ == "__main__":
    sys.exit(main())

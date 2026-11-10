#!/usr/bin/env python3
"""Fill /Volumes/Kindle/fill_disk until about 70 MiB remain, then copy the SpiderCat book.

A full disk stops the Kindle from downloading a firmware update that would close the
jailbreak. Run it once, before the jailbreak, and never after:

    kindle/tools/fill_kindle.py --firmware 5.16.7

It refuses to run unless system/version.txt contains that firmware. It writes only
fill_disk/file_N and does not touch documents, audible, voice, or system. It resumes
if file_N already exist. The book comes from payloads/spidercat.azw3.

truncate() on the macOS msdos driver fully allocates: a 100 MiB truncate dropped df
available by 100 MiB when this was checked on 2026-09-26.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

KINDLE = Path("/Volumes/Kindle")
DEST = KINDLE / "fill_disk"
VERSION = KINDLE / "system" / "version.txt"
LEAVE_MB = 70
BOOK_SRC = Path(__file__).resolve().parents[2] / "payloads" / "spidercat.azw3"
BOOK_DST = KINDLE / "documents" / "SpiderCat.azw3"
STATUS = KINDLE / "e-term-status.txt"


def free_mb() -> int:
    out = subprocess.check_output(["df", "-Pm", str(KINDLE)], text=True)
    line = out.strip().splitlines()[-1]
    parts = line.split()
    return int(parts[3])


def next_index() -> int:
    nums = []
    if not DEST.exists():
        return 0
    for path in DEST.glob("file_*"):
        try:
            nums.append(int(path.name.split("_", 1)[1]))
        except (IndexError, ValueError):
            continue
    return (max(nums) + 1) if nums else 0


def chunk_for(fillable: int) -> int:
    if fillable >= 100:
        return 100
    if fillable >= 50:
        return 50
    if fillable >= 10:
        return 10
    return max(1, fillable)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--firmware", required=True, help="the firmware version.txt must contain, such as 5.16.7")
    args = parser.parse_args()
    if not KINDLE.is_dir():
        print("Kindle not mounted at /Volumes/Kindle", file=sys.stderr)
        return 1
    text = VERSION.read_text(errors="replace") if VERSION.exists() else ""
    if args.firmware not in text:
        print(f"Refusing to fill: version.txt is {text!r}, expected {args.firmware}", file=sys.stderr)
        return 2
    DEST.mkdir(exist_ok=True)
    print(f"start free_mb={free_mb()} next={next_index()}", flush=True)
    while True:
        free = free_mb()
        fillable = free - LEAVE_MB
        if fillable <= 0:
            print(f"target reached free_mb={free}", flush=True)
            break
        size_mb = chunk_for(fillable)
        index = next_index()
        path = DEST / f"file_{index}"
        subprocess.check_call(["/usr/bin/truncate", "-s", f"{size_mb}M", str(path)])
        actual = path.stat().st_size
        expect = size_mb * 1024 * 1024
        if actual < int(expect * 0.9):
            print(f"short write {path} actual={actual}", file=sys.stderr)
            return 3
        print(f"wrote {path.name} {size_mb}MB free_before={free}", flush=True)
        if index % 5 == 4:
            os.sync()
    os.sync()
    final = free_mb()
    print(f"final free_mb={final}", flush=True)
    if not (40 <= final <= 120):
        print(f"free space {final} MB outside 40-120, not copying SpiderCat", file=sys.stderr)
        return 4
    if not BOOK_SRC.is_file():
        print(f"missing {BOOK_SRC}", file=sys.stderr)
        return 5
    shutil.copy2(BOOK_SRC, BOOK_DST)
    os.sync()
    print(f"copied SpiderCat -> {BOOK_DST} size={BOOK_DST.stat().st_size}", flush=True)
    STATUS.write_text(
        "e-term prep on this Kindle\n"
        "\n"
        "fill_disk/ is dummy files so an automatic firmware update cannot download.\n"
        "It is safe to delete the whole fill_disk folder after the jailbreak\n"
        "has finished and update blocking is in place. Do not delete it before that.\n"
        "\n"
        "documents/SpiderCat.azw3 is the jailbreak book. Opening it on the Kindle,\n"
        "with Wi-Fi on, starts the jailbreak. Do not open it until you mean to.\n"
        "\n"
        f"Free space target after fill: about {LEAVE_MB} MB. Measured by df: {final} MB.\n"
    )
    os.sync()
    print(f"status written free_after_book={free_mb()}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

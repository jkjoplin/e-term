# Kindle setup

This guide takes a stock Kindle to a terminal that logs into your computers. It was written on a Paperwhite 5 (firmware 5.16.7) and also runs on a Scribe. The steps after the jailbreak are the same on any jailbroken Kindle with a hard-float ("kindlehf") userland, which covers firmware 5.16.3 and newer.

> **Risk.** A jailbreak can leave a Kindle unusable, and it voids the warranty. Do one jailbreak, once. Keep a recovery path working (step 8) before you try anything that touches Bluetooth or system files.

## What ends up where

When the Kindle is plugged into a Mac it mounts as `/Volumes/Kindle`. On the Kindle the same folder is `/mnt/us`. Paths below are written from the Kindle's side.

| From this repo | To the Kindle | Step |
| --- | --- | --- |
| kterm zip (download) | `/mnt/us/extensions/kterm/` | 4 |
| `kindle/kterm/bin/kterm.sh` | `/mnt/us/extensions/kterm/bin/kterm.sh` (replaces the stock wrapper) | 4 |
| `kindle/kterm/vte/terminfo/` | `/mnt/us/extensions/kterm/vte/terminfo/` (merge) | 4 |
| `kindle/documents/Terminal.sh` | `/mnt/us/documents/Terminal.sh` | 4 |
| `kindle/eterm/connect.sh` | `/mnt/us/eterm/connect.sh` | 5 |
| `kindle/eterm/hosts` (yours) | `/mnt/us/eterm/hosts` | 5 |
| `ssh/kindle_eterm.dropbear` (yours) | `/mnt/us/eterm/kindle_eterm` | 5 |
| `kindle/documents/computers/*.sh` (generated) | `/mnt/us/documents/` | 5 |
| Tailscale `tailscale`, `tailscaled` (download) | `/mnt/us/extensions/tailscale/bin/` | 6 |
| `kindle/tailscale/run-tailscale.sh` | `/mnt/us/extensions/tailscale/bin/run-tailscale.sh` | 6 |
| `kindle/tailscale/hostname` (yours) | `/mnt/us/extensions/tailscale/hostname` | 6 |
| `kindle/documents/Tailscale.sh` | `/mnt/us/documents/Tailscale.sh` | 6 |
| custom-screensaver package (download) | `/mnt/us/extensions/custom-screensaver/`, `/mnt/us/documents/` | 7 |
| `kindle/screensaver/start.sh`, `boot.conf` | `/mnt/us/extensions/custom-screensaver/` | 7 |
| `kindle/documents/Sleep-screen-on-boot.sh` | `/mnt/us/documents/` | 7 |

A `.sh` file in `documents/` shows up in the Kindle library as a book. Opening it runs the script. The `# Name:` line is the title. This is the Kindle Modding "scriptlet" convention.

## Downloads

Third-party packages are not in this repository. Download each into `payloads/` (gitignored). These are the versions this setup was built with; newer releases usually work.

| Package | Used | Where | Needed for |
| --- | --- | --- | --- |
| SpiderCat jailbreak book | `spidercat.azw3` | [kindlemodding.org/jailbreaking/SpiderCat](https://kindlemodding.org/jailbreaking/SpiderCat/) | Step 2, if the wizard picks SpiderCat |
| kterm, hard-float | `kterm-kindle-2.6-armhf.zip` | [github.com/bfabiszewski/kterm/releases](https://github.com/bfabiszewski/kterm/releases) | Step 4 |
| KOReader, hard-float | `koreader-kindlehf-v2026.07.1.zip` | KPM (step 3), or [github.com/koreader/koreader/releases](https://github.com/koreader/koreader/releases) | Step 3 |
| Tailscale, static ARM | `tailscale_1.102.4_arm.tgz` | [pkgs.tailscale.com/stable/#static](https://pkgs.tailscale.com/stable/#static) | Step 6 |
| USBNetLite, hard-float | `Update_usbnetlite_1.0.P_install_khf_11thgenplus.bin` | [github.com/notmarek/kindle-usbnetlite](https://github.com/notmarek/kindle-usbnetlite) | Step 8 (recovery) |
| custom-screensaver, kindlehf | `custom-screensaver-0.3.0-kindlehf.zip` | A community package (MIT license, bundles FBInk). Search its name. | Step 7 (optional) |
| kindle-hid-passthrough | installed through KPM | [github.com/zampierilucas/kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough) | Optional, see the end of this guide |

SHA-256 of the copies used here, if you want to compare:

| File | SHA-256 |
| --- | --- |
| `spidercat.azw3` | `0af591069a315ed9e239af1fcf52c8b8011b742b0ba344985353c53884b6857c` |
| `kterm-kindle-2.6-armhf.zip` | `d1ee896a919950bb12def6b68fd4e6d0ab7b6fc50c1e390bea3f316ff70be4ba` |
| `koreader-kindlehf-v2026.07.1.zip` | `3343a916d12f36c01b59df1f65bd83ff5616e6c2a4dfbe919e7fa1400b8b1bbb` |
| `tailscale_1.102.4_arm.tgz` | `b981a59cb85fb923ee6e1860ee6934772c83a840a6627f0dbfd7711ed690b869` |
| `Update_usbnetlite_1.0.P_install_khf_11thgenplus.bin` | `233f976018c6fbdd4094f43097b1ce013b5d1343c9b3bba858b9da62d8ff52c6` |
| `custom-screensaver-0.3.0-kindlehf.zip` | `b2518a189f7a8f0e7e83d8edb0a425c869326c661730be89e8e3bc0720686c9c` |

Hard-float matters. Firmware 5.16.3 and newer is hard-float. Soft-float builds (`kterm-kindle-2.6.zip`, `koreader-kindlepw2`, `koreader-kindle`, the old USBNetwork hack) do not run on it. [notes.md](notes.md#hard-float-packages) has the details.

## 1. Identify the Kindle

Find the serial (Settings → Device Options → Device Info). Its first six characters name the model; `G001PX` is a Paperwhite 5. The firmware version is on the same page.

Pick the jailbreak with the [Kindle Modding wizard](https://kindlemodding.org/jailbreak-wizard.html). It matches model and firmware against the current list of exploits, and the first match is the one to use. Jailbreak support changes every few months, so check the wizard on the day you start. [notes.md](notes.md#jailbreak-choice-for-a-paperwhite-5-on-5167) shows the comparison for a Paperwhite 5 on 5.16.7, where the answer was SpiderCat.

Plug the Kindle in with a data cable and unlock it, so macOS mounts it. Then confirm it is the Kindle you think it is:

```sh
kindle/tools/identify_kindle.py --serial-prefix G001PX --firmware 5.16.7
```

It exits 0 only when both match, and prints `identity=DIFFERENT DEVICE` otherwise. Use your own values.

## 2. Block updates, then jailbreak

Follow the wizard's page for your exploit. The notes here are for SpiderCat, which this setup used.

**Fill the storage first.** A Kindle with Wi-Fi on can download a firmware update that closes the exploit. A full disk stops the download. `fill_kindle.py` writes dummy files into `fill_disk/` until about 70 MiB are free, then copies the SpiderCat book into `documents/`:

```sh
kindle/tools/fill_kindle.py --firmware 5.16.7
```

It refuses to run unless `system/version.txt` contains the firmware you name. It never touches `documents/`, `audible/`, `voice/` or `system/`. Delete any `*.bin` update file in the Kindle's root too. The interactive upstream filler is [Kindle-Filler-Disk](https://github.com/iiroak/Kindle-Filler-Disk).

**Jailbreak.** Eject the Kindle. With Wi-Fi on, open the SpiderCat book from the library. A blank page for several seconds is normal, then text runs down from the top; ignore application-error popups. A "Restarting GUI" screen and a white screen for several minutes are normal too. If it is still stuck after 10 minutes, hold the power button and choose Restart.

Current jailbreaks install the hotfix, block OTA updates and leave the Kindle Package Manager (KPM) in place. Read [What's next](https://kindlemodding.org/jailbreaking/whats-next/) on Kindle Modding.

**Then free the space.** Delete `fill_disk/` only after the jailbreak has finished and its update block is in place. Empty the macOS trash on the volume (`.Trashes`) if the space does not come back, then restart the Kindle.

Never run a second jailbreak on top of one that worked, and never stack payloads.

## 3. KOReader, for its SSH client

The Kindle has no SSH client. KOReader ships Dropbear's `dbclient`, which is the one people use. With Wi-Fi on, type these into the Kindle's search bar, one at a time:

```text
;kpm update
;kpm install koreader
```

`kindle/eterm/connect.sh` expects the client at `/mnt/us/koreader/dbclient`, with KOReader's libraries in `/mnt/us/koreader/libs`. Some KPM versions install the tree under `/mnt/us/kmc/kpm/packages/koreader/koreader/` instead. From any shell on the Kindle, find it with:

```sh
find /mnt/us -name dbclient
```

If it is not at the default path, change `KO=` near the top of `connect.sh`. The manual fallback is the `koreader-kindlehf` zip from KOReader's releases.

## 4. kterm, the terminal

1. Unzip the armhf kterm zip into `extensions/`, so the Kindle has `/mnt/us/extensions/kterm/bin/kterm`.
2. Copy `kindle/kterm/bin/kterm.sh` over `/mnt/us/extensions/kterm/bin/kterm.sh`.
3. Copy the two folders in `kindle/kterm/vte/terminfo/` (`k/` and `6b/`) into `/mnt/us/extensions/kterm/vte/terminfo/`, next to the ones kterm ships.
4. Copy `kindle/documents/Terminal.sh` to `/mnt/us/documents/`.

The replacement wrapper starts kterm in landscape (`-o L`), in the dark scheme (`-c 1`), with the on-screen keyboard hidden (`-k 0`). It sets `TERM=kterm-256color` and points `TERMINFO` at the folder from step 3. While Terminal is open it keeps deferring the Kindle's deep sleep, which would drop Wi-Fi; the sleep screen can still appear. A two-finger tap opens kterm's menu, which can bring the on-screen keyboard back.

The `kterm-256color` description is `xterm-256color` without the sequences kterm's old VTE paints as stray text (cursor shape and color, clipboard, `XT`). [notes.md](notes.md#e-ink-tui-limits) explains why. Rebuild the compiled copies from `kindle/kterm/terminfo/kterm-256color.src` with:

```sh
tic -x -o kindle/kterm/vte/terminfo kindle/kterm/terminfo/kterm-256color.src
```

macOS writes the result under `6b/` (hex for `k`), and Linux under `k/`. Keep both, since the Kindle's ncurses looks in `k/`.

Open the **Terminal** book. Without the host menu from the next step, it opens a local shell.

## 5. The host menu (eterm)

`connect.sh` shows a numbered list of your computers and SSHes into the one you pick. Each computer row can run a remote command, which by default attaches the tmux session `eink` and lets Eink Focus move the Kindle to another computer ([how-it-works.md](how-it-works.md#moving-the-kindle-between-computers)).

**Make a key pair for the Kindle.** On your computer, from the repo:

```sh
mkdir -p ssh
ssh-keygen -t ed25519 -f ssh/kindle_eterm -N "" -C kindle-eterm
```

The key has no passphrase, because the Kindle logs in unattended. Give it no other job. Dropbear's `dbclient` has rejected OpenSSH-format private keys (`Exited: String too long`), so convert a copy to Dropbear's format:

```sh
brew install dropbear
dropbearconvert openssh dropbear ssh/kindle_eterm ssh/kindle_eterm.dropbear
```

`ssh/kindle_eterm` stays on your computer, for Eink Focus. `ssh/kindle_eterm.pub` goes into `~/.ssh/authorized_keys` on every computer ([computers.md](computers.md)). `ssh/kindle_eterm.dropbear` goes on the Kindle.

**Write the host list.**

```sh
cp kindle/eterm/hosts.example kindle/eterm/hosts
```

One line per computer: `id|user|host|port|label|remote command`. [configuration.md](configuration.md#the-kindles-host-list-kindleetermhosts) explains each field and the remote command. Leave `host` as `REPLACE` for a computer you have not set up yet; the menu shows the slot and refuses it.

**Copy to the Kindle:**

| From | To |
| --- | --- |
| `kindle/eterm/connect.sh` | `/mnt/us/eterm/connect.sh` |
| `kindle/eterm/hosts` | `/mnt/us/eterm/hosts` |
| `ssh/kindle_eterm.dropbear` | `/mnt/us/eterm/kindle_eterm` |

**Optional: one book per computer.** This writes a launcher for each row of the host list into `kindle/documents/computers/`. Opening one connects straight to that computer, skipping the menu:

```sh
kindle/tools/make-launchers.sh
```

Copy the generated files into `/mnt/us/documents/`.

Open **Terminal** and pick a computer. The first connection to each computer accepts its host key (`dbclient -y`). `q` at the menu opens a local shell on the Kindle.

## 6. Tailscale (optional)

Over plain Wi-Fi, the Kindle reaches computers on the same network by their LAN address, which can change. With Tailscale on the Kindle, it reaches every computer on your tailnet by its MagicDNS name, from any network.

The Kindle runs Tailscale in userspace-networking mode, so ordinary sockets have no route to the tailnet. `connect.sh` therefore dials any host that starts with `100.` or ends in `.ts.net` through `tailscale nc`, as a `dbclient -J` proxy.

1. Unpack the static ARM tarball and copy `tailscale` and `tailscaled` into `/mnt/us/extensions/tailscale/bin/`.
2. Copy `kindle/tailscale/run-tailscale.sh` into the same folder.
3. Name the Kindle on your tailnet: put one word, such as `kindle` or `scribe`, in `kindle/tailscale/hostname` and copy it to `/mnt/us/extensions/tailscale/hostname`. Each Kindle needs its own name. Eink Focus looks for Kindles by these names.
4. Copy `kindle/documents/Tailscale.sh` to `/mnt/us/documents/`.
5. With Wi-Fi on, open the **Tailscale** book. It starts Tailscale in the background and tells you to wait. After a minute, open the **Tailscale-status** document. The first time, it contains a `login.tailscale.com` link: open that link in a browser that is signed in to your tailnet.
6. In the Tailscale admin console, turn off key expiry for the Kindle, so it doesn't drop off the tailnet in a few months.

Open the Tailscale book again after each restart of the Kindle. `run-tailscale.sh` passes `--ssh`, which lets you SSH into the Kindle over Tailscale for maintenance (subject to your tailnet's SSH rules). Remove `--ssh` from both `tailscale up` lines if you don't want that.

If you change a Kindle's name after it has joined, `tailscale up` may refuse new settings until every non-default flag is repeated. Check `Tailscale-status` after a change.

## 7. Sleep screen (optional)

On this firmware the lock screen shows Amazon's ads or covers. The custom-screensaver package unloads the ad renderer and draws your own PNG instead.

1. Unzip the package onto the Kindle. It provides `extensions/custom-screensaver/` and a **Custom Screensaver** book. Put your PNGs where its readme says.
2. Copy `kindle/screensaver/start.sh` and `kindle/screensaver/boot.conf` into `/mnt/us/extensions/custom-screensaver/`.
3. Copy `kindle/documents/Sleep-screen-on-boot.sh` to `/mnt/us/documents/` and open it once. It copies `boot.conf` into `/etc/upstart/` (it remounts the root filesystem read-write for that one copy), so the sleep screen starts by itself after each boot. If the package is ever removed, the job exits; it never stops the Kindle from booting.

Do not install NiLuJe's older screensaver hack, and don't delete the Kindle's ad-cache folder. Both are the wrong tool on 5.16 firmware.

## 8. Recovery: USB networking

Install this before any Bluetooth experiment. A bad Bluetooth daemon can white-screen a Kindle, and these models have no serial pads, so USB networking is the way back in.

From the [USBNetLite](https://github.com/notmarek/kindle-usbnetlite) readme: put the hard-float install bin in `mrpackages/` and run `;log mrpi` from the search bar. The Kindle is then `192.168.15.244` (user `root`, password `kindle`). Give the computer `192.168.15.201/24` on the new USB interface, with no gateway. While USB networking is on, the Kindle is not a USB disk.

SpiderCat-era jailbreaks may not install MRPI. If `;log mrpi` does nothing, read the project's current install notes before trying anything else. macOS on Apple silicon often doesn't bind the RNDIS gadget at all; don't install the old HoRNDIS kernel extension. KOReader's own SSH server (port 2222) is another way in while KOReader is running.

## A keyboard on the Kindle itself (optional)

You don't need one: Eink Focus types into the Kindle's session from your computer's keyboard or your phone. To pair a Bluetooth keyboard directly to the Kindle, use [kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough), the userspace HID stack for exactly this:

```sh
kpm add-repo https://raw.githubusercontent.com/zampierilucas/kindle-hid-passthrough/main/kpm/repo.json
kpm install kindle-hid-passthrough
```

It takes over the Bluetooth radio (no Bluetooth audiobooks while it runs) and its autostart is off by default. Set up USB networking first.

## Everyday use

- Keep the Kindle on USB-C power at the desk. Wi-Fi plus a terminal drains the battery far faster than reading.
- Open **Terminal** (or a computer's own book), pick a computer, and you are in its `eink` tmux session.
- Type from Eink Focus on the Mac or the phone. Eink Focus can also move the Kindle to another computer and switch tmux sessions.
- A disconnect drops you back at the menu. tmux keeps the session running on the computer.

## Do not

- Run a second jailbreak, install a firmware update, or run the filler after the jailbreak.
- Delete books, `audible/`, dictionaries or voice files to make room.
- Install soft-float packages on hard-float firmware.

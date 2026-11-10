# Notes

Research behind the choices in this repo, from building it on a Paperwhite 5 in September 2026. Jailbreak support moves quickly, so check dates and re-check the Kindle Modding wizard before relying on anything time-sensitive here.

## Background

The shape comes from [Ryan Peterman's build](https://x.com/ryanlpeterman/status/2097406401068896283): a jailbroken Kindle runs a terminal, a keyboard types into it, and SSH lands on a computer where the real work happens, lit only by the Kindle's warm front light. His [typing test](https://x.com/ryanlpeterman/status/2097714292166439303) is the bar for latency. His [build summary](https://x.com/ryanlpeterman/status/2097657322600284597) used a Scribe, with a custom BLE GATT client against Amazon's ACE Bluetooth stack and keys injected through XTEST.

This repo takes a different route to the keyboard. Instead of pairing a keyboard to the Kindle, Eink Focus types into the Kindle's tmux session from the computer's own keyboard or from a phone. That needs no Bluetooth work on the Kindle at all, and it works on any Kindle that can run kterm and SSH.

The working shape, from the Kindle Modding docs and 2025–2026 writeups:

1. Jailbreak the exact model and firmware with the current Kindle Modding method.
2. Run [kterm](https://github.com/bfabiszewski/kterm) 2.6, hard-float build. It's a GTK VTE terminal, so ncurses TUIs get a real tty.
3. SSH out with Dropbear's `dbclient`. The Kindle OS has no SSH client; KOReader's build is the one people use.
4. Prefer Wi-Fi (or Tailscale over Wi-Fi) for the session. USB networking exists and is the recovery path.

The CLIs stay on the computer. The Kindle has a small ARM userland and is the wrong place to run them.

## Jailbreak choice for a Paperwhite 5 on 5.16.7

The official matcher, `https://kindlemodding.org/jailbreakFinder.js`, loads `models.json` and `jailbreaks.json`. Serial prefix `G001PX` maps to device code `1PX`, nickname `PW5`. The wizard's order is the array order, and the first match is the one it tells you to use. As matched on 2026-09-26:

| Method | PW5 on 5.16.7 | Why |
| --- | --- | --- |
| SpiderCat | Use this | Models include PW5. Firmware 5.16.3 through 5.19.5. No registration needed. First match. |
| Nosebleed | Fallback | PW5, 5.16.4 through 5.18.6. Mass-storage Kindles. |
| Sanctuary | Fallback | 5.16.4 through 5.18.3, except 5.16.5. Has an on-device browser check. |
| WinterBreak | Only if registered | Up to 5.18.0.2. Needs an Amazon registration. |
| Véra | No | PW5 support starts at 5.17.1. |
| WinterBreak2 | No | Max 5.16.3, plus an exception only for 5.16.5. |
| AdBreak | No | Needs ads and firmware 5.18.1 or newer. |
| SpringBreak | No | PW5 rule starts at 5.18.1. |

After a successful jailbreak, apps are scriptlets: a `.sh` file in `documents/` shows up as a book and runs when opened. Metadata lines are `# Name:` and `# Author:`; `# DontUseFBInk` stops the script's output from being drawn on the panel. KUAL is described as obsolete.

## Hard-float packages

Firmware 5.16.3 and newer uses a hard-float ABI. Soft-float binaries don't start.

| Need | Use | Avoid |
| --- | --- | --- |
| Terminal | `kterm-kindle-2.6-armhf.zip` | `kterm-kindle-2.6.zip` (soft-float) |
| KOReader, for `dbclient` | KPM package `koreader`, which picks the HF build; manual fallback `koreader-kindlehf` | `koreader-kindlepw2` and `koreader-kindle`. "pw2" is the old soft-float ABI, not a model check. |
| USB networking | `Update_usbnetlite_1.0.P_install_khf_11thgenplus.bin` | The generic `1.0.M` khf bin, and soft-float USBNetwork hacks |

kterm 2.6 armhf is a 32-bit ARM ELF with interpreter `/lib/ld-linux-armhf.so.3`. Its stock `kterm.sh` picks the 300 dpi keyboard layout above 290 dpi and forces `TERM=xterm`.

## SSH client

KOReader's Dropbear client is what the XDA "Kindle as an SSH terminal" writeup uses. KOReader's CMake puts it at `/mnt/us/koreader/dbclient`. A June 2026 KOReader bug sometimes installed the tree at `/mnt/us/kmc/kpm/packages/koreader/koreader/` instead. If the dynamic linker complains, point `LD_LIBRARY_PATH` at the KOReader `libs` folder next to the binary; `connect.sh` does this.

`dbclient -i` has rejected OpenSSH private keys with `Exited: String too long`. Convert the key with `dropbearconvert`, or generate one on the Kindle with `dropbearkey` and authorize that public key instead. Useful flags: `-y` accepts a host key on first connect, `-t` forces a tty, `-J` runs a proxy command.

KOReader's own SSH server (port 2222, user `root`) is for logging into the Kindle. It's an admin path, not the console path. See the [KOReader SSH wiki](https://github.com/koreader/koreader/wiki/SSH).

## Terminfo and locale

kterm 2.6 embeds VTE 0.28.2. VTE starts its child with `TERM=xterm` whatever `kterm.sh` exports, so `connect.sh` sets the TERM sent over SSH. It sends `kterm-256color`.

The `xterm-256color` description advertises `XT`, cursor shape (`Ss`/`Se`), cursor color (`Cr`/`Cs`), clipboard (`Ms`) and mouse (`kmous`). This VTE predates all of them. tmux forwards those sequences, and the panel shows them as stray text, especially when a TUI changes mode or tmux copies (OSC 52). `kterm-256color` is the same description with those capabilities removed.

The same VTE has no 24-bit color: it reads `38;2;r;g;b` as unrelated attributes, such as a background color, reverse or invisible text. If tmux has `terminal-features ",*:RGB"`, add `terminal-overrides ",kterm*:RGB@:Tc@:setrgbf@:setrgbb@"` so tmux converts colors to the 256-color palette for the Kindle ([computers.md](computers.md#4-install-the-kindles-terminfo-entry)).

tmux 3.7c prints tabs in `list-clients -F` output as `_` without a UTF-8 locale. An app started from Finder or at login has no `LANG`, and an SSH login gets `LC_CTYPE=C` unless the client sends `LC_*`. Both apps set `LC_CTYPE=en_US.UTF-8` on everything they run.

## Refresh rate

The jailbreak can make the panel update faster, by choosing the e-ink waveform and redrawing only the rectangle that changed. Amazon's reader uses a high-quality flashing update on purpose, because that keeps text sharp. E Ink's mode table, roughly, at room temperature:

| Mode | Looks like | Update time |
| --- | --- | --- |
| GC16 | 16 grays, flashing, the "real page" look | about 450 ms |
| DU | Black and white, little flashing, some ghosting | a few times faster than GC16 |
| A2 | Black-and-white animation mode | about 120 ms |

Those are controller numbers. A terminal still has to render text, ship the damage region through X, and wait for the controller. Screen-mirroring demos land around 4 frames a second. A grayscale TUI that repaints the whole screen stays closer to one update a second.

kterm has no refresh-rate switch. It draws through GTK and the Kindle's X server, which already uses partial updates for changed areas. That's the right behavior for a shell: a new line shouldn't flash the whole page. The Paperwhite 5's Carta 1200 is faster than older Paperwhites' panels. Cold rooms slow any panel down.

## E-ink TUI limits

- The panel is grayscale, so color themes become gray. kterm's dark scheme (`-c 1`) is the default here because a full white flash is harsh. If ghosting is worse in dark mode, switch the wrapper to `-c 0`.
- In landscape with kterm's default size-8 monospace, a Paperwhite 5 fits on the order of 100 columns by the high 30s in rows, with the on-screen keyboard hidden. That's enough for Claude Code. Change `font_size` in kterm's own `/mnt/us/extensions/kterm/bin/kterm.conf` on the Kindle if it's cramped or tiny.
- Full-screen redraws lag and ghosting builds up. It will never feel like an LCD. Run everything inside tmux on the computer, so a dropped connection doesn't kill the program.
- Every animation frame is a partial refresh. Spinners, shimmering status text and clocks keep their corner flickering. Turn them off for the Kindle's session ([computers.md](computers.md#6-calm-claude-code-down-on-e-ink-optional) has a Claude Code wrapper).
- Keep the Kindle on power while a session is up. Wi-Fi plus a terminal drains it far faster than reading. `kindle/kterm/bin/kterm.sh` defers the deep sleep that drops Wi-Fi while Terminal is open.

## The OTA filler

`kindle/tools/fill_kindle.py` is a non-interactive filler. The upstream interactive script is [Kindle-Filler-Disk](https://github.com/iiroak/Kindle-Filler-Disk) (Kindle Modding still links the old bastianmarin URL, which redirects there).

`truncate -s 100M` on the macOS msdos driver really allocates space on the Kindle's volume: a 100 MiB file dropped `df` available by 100 MiB. Delete `fill_disk/` only after the jailbreak has finished and its update block is in place; deleting it earlier lets the Kindle download an update and close the jailbreak window.

## Sources

- https://kindlemodding.org/jailbreaking/
- https://kindlemodding.org/jailbreak-wizard.html
- https://kindlemodding.org/jailbreaking/SpiderCat/
- https://kindlemodding.org/jailbreaking/prevent-auto-update/
- https://kindlemodding.org/jailbreaking/whats-next/getting-koreader/
- https://kindlemodding.org/kindle-dev/scriptlets.html
- https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices
- https://github.com/koreader/koreader/wiki/SSH
- https://github.com/bfabiszewski/kterm
- https://github.com/notmarek/kindle-usbnetlite
- https://github.com/zampierilucas/kindle-hid-passthrough
- https://github.com/Mounstroya/kindle-ssh-guide
- https://www.xda-developers.com/turned-kindle-into-things-amazon-never-intended-its-most-useful-device/

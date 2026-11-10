# Kindle files

Everything here either goes onto the Kindle or helps prepare it. [docs/kindle.md](../docs/kindle.md) is the step-by-step guide and has the full table of where each file goes.

| Path | On the Kindle | What it is |
| --- | --- | --- |
| `eterm/connect.sh` | `/mnt/us/eterm/` | The host menu. SSHes into the computer you pick, and follows Eink Focus's requests to move to another computer. |
| `eterm/hosts.example` | `/mnt/us/eterm/hosts` (your copy) | Template for the host list. |
| `kterm/bin/kterm.sh` | `/mnt/us/extensions/kterm/bin/` | Replacement kterm wrapper: landscape, dark, keyboard hidden, `TERM=kterm-256color`, stays awake while open. |
| `kterm/terminfo/kterm-256color.src` | (source) | The terminfo description for the Kindle's terminal. Install it on each computer with `tic -x`. |
| `kterm/vte/terminfo/` | `/mnt/us/extensions/kterm/vte/terminfo/` | The same description, compiled for the Kindle. |
| `documents/Terminal.sh` | `/mnt/us/documents/` | The Terminal book: opens kterm with the host menu. |
| `documents/Tailscale.sh` | `/mnt/us/documents/` | The Tailscale book: starts Tailscale and writes its status to a document. |
| `documents/Sleep-screen-on-boot.sh` | `/mnt/us/documents/` | Installs the boot job that starts the custom sleep screen. |
| `tailscale/run-tailscale.sh` | `/mnt/us/extensions/tailscale/bin/` | Starts `tailscaled` in userspace mode and signs in. Reads the Kindle's tailnet name from `../hostname`. |
| `screensaver/start.sh`, `boot.conf` | `/mnt/us/extensions/custom-screensaver/` | Start the custom-screensaver package at boot. |
| `tools/identify_kindle.py` | (runs on your computer) | Confirms the Kindle on USB is the model and firmware you expect. |
| `tools/fill_kindle.py` | (runs on your computer) | Fills the Kindle's storage so no firmware update can download before the jailbreak. |
| `tools/make-launchers.sh` | (runs on your computer) | Writes one library book per computer into `documents/computers/` (gitignored). |

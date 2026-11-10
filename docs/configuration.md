# Configuration

Every name, address and key lives in a gitignored file. Each has a template next to it. Copy the template, fill it in, and keep the copy out of git (`.gitignore` already does).

| File | Read by | Template |
| --- | --- | --- |
| `kindle/eterm/hosts` | The Kindle (`connect.sh`), Eink Focus for Mac, `android/provision.sh` | `kindle/eterm/hosts.example` |
| `config/eink-focus.json` | Eink Focus for Mac, `android/provision.sh` | `config/eink-focus.example.json` |
| `config/eink-focus-android.json` | Eink Focus for Android | written by `android/provision.sh` |
| `kindle/tailscale/hostname` | The Kindle (`run-tailscale.sh`) | one word |
| `ssh/kindle_eterm`, `.pub`, `.dropbear` | Everything that logs in | made with `ssh-keygen` ([kindle.md](kindle.md#5-the-host-menu-eterm)) |

## The Kindle's host list: `kindle/eterm/hosts`

One computer per line. Blank lines and lines starting with `#` are ignored.

```text
id|user|host|port|label|remote command
```

| Field | Meaning |
| --- | --- |
| `id` | A short name, such as `personal` or `mini`. Letters, digits, `-` and `_`. Launcher books and Eink Focus refer to computers by it. |
| `user` | The account to log into. |
| `host` | A LAN address, a Tailscale address (`100.x.y.z`) or a MagicDNS name (`name.tailnet.ts.net`). The last two are dialed through `tailscale nc`. `REPLACE` (or empty) marks a computer that isn't set up yet: it shows in the menu but can't be picked, and the apps skip it. |
| `port` | SSH port. Empty means 22. |
| `label` | What the menu, the launcher book and the Eink Focus card call this computer. |
| `remote command` | Optional. Runs instead of a login shell. Everything after the fifth `\|` belongs to it, so it may contain `\|`. |

The order matters: it's the order of the menu, the order Eink Focus steps through, and the numbering used to move the Kindle to a computer (see below).

### The remote command

The template's command does three things:

```sh
sh -c '
  # 1. Fall back to xterm-256color on a computer without the kterm-256color entry.
  case "$TERM" in kterm*) infocmp "$TERM" >/dev/null 2>&1 || TERM=xterm-256color;; esac
  # 2. Attach (or create) the tmux session "eink".
  TMUX=/opt/homebrew/bin/tmux; "$TMUX" new -As eink; s=$?
  # 3. If Eink Focus left a request in ~/.eterm-switch, exit with a code that tells
  #    connect.sh which computer to log into next.
  f="$HOME/.eterm-switch"
  if [ -f "$f" ]; then
    t=$(head -n 1 "$f" | tr -cd "a-z0-9"); rm -f "$f"
    case "$t" in
      ""|next) exit 40;;
      prev) exit 41;;
      [0-9]|[1-9][0-9]) n=$((50 + t)); if [ "$n" -le 80 ]; then exit "$n"; fi; exit 40;;
      *) exit 40;;
    esac
  fi
  exit $s'
```

In the file it is one line. Change the tmux path to match the computer (`command -v tmux`) and the session name if you want another. Keep the `eterm-switch` part: Eink Focus checks for that marker before it asks a login to switch computers.

| Exit code | `connect.sh` then logs into |
| --- | --- |
| 40 | The next ready computer, wrapping around |
| 41 | The previous ready computer |
| 50 + n (up to 80) | The n-th ready computer, counting from zero and skipping `REPLACE` rows |
| anything else | Nothing: back to the menu |

## Eink Focus for Mac: `config/eink-focus.json`

The app looks for its config in this order and uses the first file that exists:

1. The path in its `ConfigPath` default: `defaults write dev.eterm.einkfocus ConfigPath ~/somewhere/eink-focus.json`
2. `config/eink-focus.json` in the checkout the app was built from. `mac/build.sh` records that checkout's path in the app.
3. `~/Library/Application Support/Eink Focus/config.json`

The menu's **Open config** item shows the file in use in Finder. The app reads it again when you open the menu after an edit.

```json
{
  "tmux": "/opt/homebrew/bin/tmux",
  "tailscale": "/usr/local/bin/tailscale",
  "kindleHostnames": ["kindle", "scribe"],
  "kindleLabels": {"kindle": "Paperwhite", "scribe": "Scribe"},
  "identity": "ssh/kindle_eterm",
  "hosts": "kindle/eterm/hosts",
  "thisComputer": "personal",
  "remotes": [
    {"id": "mini", "label": "Mac mini", "user": "me", "host": "mini.example.ts.net", "port": 22, "tmux": "/opt/homebrew/bin/tmux"}
  ]
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `tmux` | `/opt/homebrew/bin/tmux` | tmux on this Mac, and the default for remotes. |
| `tailscale` | `/usr/local/bin/tailscale` | The Tailscale CLI. With the Mac App Store version, install the CLI from Tailscale's settings, or point this at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. |
| `kindleHostnames` | `["kindle"]` | The Kindles' names on your tailnet (their `hostname` file). A login from one of their Tailscale addresses counts as a Kindle. |
| `kindleHostname` | `"kindle"` | Older single-name form. It is added to `kindleHostnames`. |
| `kindleLabels` | none | Tailnet name → the name on the card. A Kindle without a label shows its tailnet name. When two Kindles show the same tmux session, the one receiving keys moves to a session of its own, named after its label in lowercase. |
| `identity` | none | The private key Eink Focus logs into remotes with: the Kindle's OpenSSH key. |
| `hosts` | `kindle/eterm/hosts` | The Kindle's host list. It sets the order of computers on the card. |
| `thisComputer` | `personal` | The `id` of this Mac's row in the host list. |
| `remotes` | none | Other computers to look for the Kindle on and type into. Use the same `id` as the computer's row in the host list. `port` defaults to 22 and `tmux` to the top-level `tmux`. |

Relative paths start at the checkout root when the file is in the checkout's `config/` folder, and at the file's own folder otherwise. `~` is expanded.

Without a host list, the card shows this Mac followed by the remotes.

## Eink Focus for Android: `config/eink-focus-android.json`

`android/provision.sh` writes this file and copies it into the app's private storage. You normally don't edit it by hand; change the host list or the Mac config and run `android/provision.sh --config` again.

```json
{
  "computers": [
    {"id": "personal", "label": "MacBook Pro", "user": "me", "host": "laptop.example.ts.net", "port": 22, "tmux": "/opt/homebrew/bin/tmux"}
  ],
  "kindles": {"kindle": "100.64.0.11"},
  "labels": {"kindle": "Paperwhite"}
}
```

| Key | Comes from | Meaning |
| --- | --- | --- |
| `computers` | The host list, in its order | Every computer the phone can reach. `REPLACE` rows stay in the list but can't be picked, as on the Kindle. `tmux` comes from the Mac config's `remotes` entry with the same `host`, else its top-level `tmux`. |
| `kindles` | `tailscale status` on the Mac, for the names in `kindleHostnames` | Tailscale address → tailnet name. A login from one of these addresses counts as a Kindle. If it's empty, any `100.x` login does. |
| `labels` | `kindleLabels` in the Mac config | Tailnet name → the name on the card. |

The phone reaches each computer by `host`, so the phone needs Tailscale too when the hosts are tailnet names.

## The Kindle's tailnet name: `kindle/tailscale/hostname`

One word, such as `kindle`. Copied to `/mnt/us/extensions/tailscale/hostname` on the Kindle, where `run-tailscale.sh` passes it to `tailscale up --hostname`. Give each Kindle its own name and list every name in `kindleHostnames`.

## Keys: `ssh/`

| File | Where it goes |
| --- | --- |
| `ssh/kindle_eterm` | Stays on your computer. Eink Focus logs in with it (`identity`), and `provision.sh` copies it into the phone app's private storage. |
| `ssh/kindle_eterm.pub` | `~/.ssh/authorized_keys` on every computer in the host list. |
| `ssh/kindle_eterm.dropbear` | The Kindle, as `/mnt/us/eterm/kindle_eterm`. |

The key has no passphrase, because the Kindle and the apps log in unattended. It can log into every account in your host list, so treat any copy of it as that access, and use it for nothing else. To revoke it, remove its line from each `authorized_keys`.

# How it works

Nothing runs on the computers except `sshd` and tmux, and nothing new listens on the network. The Kindle is an SSH client. Both Eink Focus apps are SSH clients too, using the same key. Everything else is tmux commands and one small file.

## The Kindle's side

`kterm` starts `kindle/eterm/connect.sh`. It reads the host list, shows a menu (or takes an `id` argument from a launcher book), and runs Dropbear's `dbclient` with the Kindle's key. For a Tailscale host it adds `-J "tailscale nc <host> <port>"`, because the Kindle's Tailscale runs in userspace mode and has no network route of its own.

On the computer, the host list's remote command attaches the tmux session `eink`. When the SSH session ends, `connect.sh` looks at the exit code to decide whether to log into another computer or return to the menu.

## Finding the Kindle

Both apps ask each computer the same question in one SSH command:

```sh
who; echo ---; tmux list-clients -F '#{client_tty}<TAB>#{client_name}<TAB>#{session_name}'
```

`who` lists logins with their source address in parentheses. A login from one of the Kindles' Tailscale addresses is a Kindle; the apps learn those addresses from `tailscale status`, by the names in `kindleHostnames`. The tmux client on that login's tty is the Kindle's view, and its session is where keys go.

On the Mac it runs on, the Mac app does the same thing locally. The apps check every computer in parallel every second or two and follow the Kindle when it moves.

tmux prints those tabs as `_` when its locale is not UTF-8, which would hide the Kindle. Every command the apps run starts with `LC_CTYPE=en_US.UTF-8`.

## Typing

Each app keeps one SSH session open to the computer the Kindle is on, running a small loop under `/bin/sh`:

```sh
while IFS= read -r line; do
  case "${line%% *}" in
    K) tmux send-keys -t "$S" "${line#* }" ;;    # a named key: Enter, BSpace, C-c, Up...
    H) tmux send-keys -t "$S" -H ${line#* } ;;   # text, as hex bytes, 48 per line
  esac
done
```

Text goes as hex so any UTF-8 byte and any quote survives. The loop runs under `/bin/sh` on purpose: macOS logins use zsh, which doesn't split `${line#* }` into separate arguments, so the hex bytes would arrive as one word and nothing would be typed. Holding one session open keeps latency at one network round trip per keystroke, with no new process per key.

## Switching tmux sessions

"Next session" lists the sessions on the computer the Kindle is on and runs `tmux switch-client -c <the Kindle's client> -t <next session>`. Only the Kindle's view changes. Other clients stay where they are.

## Moving the Kindle between computers

The Kindle owns its SSH session, so an app can't move it directly. It asks the Kindle to move:

1. Over SSH to the computer the Kindle is on, it checks that the Kindle's login is running the remote command with the `eterm-switch` marker (an older login answers "old", and the apps say so instead of detaching it).
2. It writes a token to `~/.eterm-switch`: `next`, `prev`, or the number of the target computer among the ready rows of the host list.
3. It detaches the Kindle's tmux client.
4. tmux returns on the Kindle's login. The remote command reads the file, deletes it, and exits 40 (next), 41 (previous) or 50 + n (computer n).
5. `connect.sh` sees the code and logs into that computer. The apps find the Kindle there on their next check.

The session on the old computer keeps running; only the Kindle's view leaves.

## Two Kindles

With two Kindles logged in, the apps show both and send keys to one at a time; a key or shortcut picks the other. If both are viewing the same tmux session, the Mac app gives the one receiving keys a session of its own, named after its label, so you don't type into both.

## The phone

Eink Focus for Android uses the same commands as the Mac app over [JSch](https://github.com/mwiede/jsch), with Bouncy Castle providing Ed25519 and X25519 on Android. Its differences:

- **Key and host list.** `android/provision.sh` copies the Kindle's OpenSSH key and a generated host list into the app's private storage over `adb run-as`. They're never in the APK, and app data is excluded from Android backups.
- **Host keys.** The first connection to each computer pins its host key in the app's `known_hosts`. A changed key is refused, like OpenSSH's `StrictHostKeyChecking=accept-new`.
- **Terminal mode and text mode.** In terminal mode the phone keyboard is told it's editing a visible-password field, so it sends exact keystrokes with no autocorrect. Keyboards turn voice typing off for such fields, so text mode presents a normal text field instead. The app keeps a copy of the line, lets the keyboard edit that copy (autocorrect, swipe, voice corrections), and sends each change as backspaces plus the retyped part. A spoken new line becomes a space, so voice never presses Return.

## Security notes

- The Kindle's key has no passphrase and can log into every account in your host list. It sits on the Kindle, on each computer that runs Eink Focus, and in the phone app's private storage. Remove its line from `authorized_keys` to revoke it.
- The remote command and the key loop run with that account's full rights. tmux `send-keys` types into whatever the session is running.
- `connect.sh` accepts a computer's host key on first connect (`dbclient -y`).
- `run-tailscale.sh` turns on Tailscale SSH for the Kindle (`--ssh`), which your tailnet's policy decides who may use. Remove the flag if you don't want it.

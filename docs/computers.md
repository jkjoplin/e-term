# Computer setup

Do this on every computer the Kindle logs into. The guide is written for macOS, since that's where Eink Focus runs, but the Kindle side only needs `sshd`, a POSIX `sh` and tmux, so a Linux box works as a target too.

## 1. Turn on SSH

On macOS: System Settings → General → Sharing → **Remote Login**. That starts `sshd` for the accounts you allow.

If the Kindle reaches this computer over Tailscale, install Tailscale here too and note the computer's MagicDNS name (`tailscale status`). That name, not a LAN address, goes in the Kindle's host list.

## 2. Authorize the Kindle's key

Append the public key from [kindle.md](kindle.md#5-the-host-menu-eterm) to the account the Kindle logs into:

```sh
cat ssh/kindle_eterm.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

For a computer you reach over SSH:

```sh
ssh-copy-id -i ssh/kindle_eterm.pub user@other-computer
```

Eink Focus logs in with the same key, so this also lets the Mac app and the phone reach this computer.

## 3. Install tmux

```sh
brew install tmux
```

Note where it is (`command -v tmux`). Homebrew on Apple silicon puts it in `/opt/homebrew/bin/tmux`, on Intel in `/usr/local/bin/tmux`. The remote command in the Kindle's host list and both Eink Focus configs name this path, because a non-interactive SSH command doesn't load your shell's `PATH`.

## 4. Install the Kindle's terminfo entry

The Kindle connects with `TERM=kterm-256color`. Install the description so tmux and TUIs on this computer know what the Kindle can draw:

```sh
tic -x kindle/kterm/terminfo/kterm-256color.src
```

That writes it into `~/.terminfo`. Eink Focus for Mac does this on the Mac it runs on when the entry is missing. A computer without the entry still works, because the default remote command falls back to `xterm-256color`, but then tmux sends cursor-shape and clipboard sequences that kterm paints as stray characters.

Tell tmux the Kindle client has 256 colors, and no 24-bit color, in `~/.tmux.conf`:

```tmux
set -as terminal-features ",kterm*:256"
set -as terminal-overrides ",kterm*:RGB@:Tc@:setrgbf@:setrgbb@"
```

The second line matters if your config turns on 24-bit color for every client (`terminal-features ",*:RGB"`). kterm's VTE reads 24-bit color sequences as unrelated attributes, such as reverse or invisible text. With the override, tmux converts colors to the 256-color palette for the Kindle only.

## 5. Use UTF-8 for SSH logins

tmux 3.7 prints tab characters as `_` in `list-clients -F` output when its locale is not UTF-8. Eink Focus reads that output to find the Kindle. Both apps set `LC_CTYPE=en_US.UTF-8` on the commands they run, so this works out of the box with macOS's default `sshd`, which accepts `LC_*` from the client. If you changed `AcceptEnv` in `/etc/ssh/sshd_config`, keep `LANG LC_*` in it.

## 6. Calm Claude Code down on e-ink (optional)

Every animation frame is a partial e-ink refresh. Claude Code's thinking spinner and status shimmer keep one line of the Kindle flickering and ghosting for as long as Claude works. Its `prefersReducedMotion` setting stops them. This wrapper in `~/.zshrc` turns it on only for a Claude started inside the Kindle's tmux session (`eink`):

```zsh
# Claude Code started inside the Kindle's tmux session runs without animation.
claude() {
  local tmux_bin=${commands[tmux]:-/opt/homebrew/bin/tmux}
  if [[ -n $TMUX && $($tmux_bin display -p -t "$TMUX_PANE" '#S' 2>/dev/null) == eink ]]; then
    command claude --settings '{"prefersReducedMotion":true}' "$@"
  else
    command claude "$@"
  fi
}
```

The setting belongs to the Claude process, not the screen: a Claude started in another session keeps animating if the Kindle moves there. A status line or tmux clock that changes on a timer repaints its corner the same way, so consider turning those off in the `eink` session too.

## 7. Check it

From the Kindle, open Terminal and pick this computer. You should land in tmux session `eink`. On the computer:

```sh
tmux list-clients -F '#{client_tty} #{client_termname} #{session_name}'
```

The Kindle's client shows `kterm-256color` and `eink`. `who` shows its login, with the Kindle's address in parentheses. That's how Eink Focus recognizes it.

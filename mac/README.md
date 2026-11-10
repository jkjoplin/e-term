# Eink Focus for Mac

A menu-bar app that sends your Mac's keyboard to the Kindle. Press **⌃⌥⌘K** and everything you type goes into the tmux session the Kindle is showing, whether that session is on this Mac or on another computer in your host list. A small desk card shows which Kindle is listening, which computer and session it's on, and the line you're typing. Press **⌃⌥⌘K** again (or **Esc**) to get your keyboard back.

It's a single Swift file with no dependencies. It needs macOS 13 or newer.

## Build and install

```sh
mac/build.sh --install
```

This compiles `EinkFocus.swift` with the Xcode command line tools (`xcode-select --install`), bundles the app into `mac/build/`, signs it ad hoc, copies it to `/Applications`, and starts it. Without `--install` it only builds.

The build records this checkout's path in the app, so the app reads `config/eink-focus.json` from here. Copy `config/eink-focus.example.json` to that name first and fill it in ([configuration.md](../docs/configuration.md#eink-focus-for-mac-configeink-focusjson)). The Kindle's host list (`kindle/eterm/hosts`) sets the order of computers on the card.

To start it at login, add it in System Settings → General → Login Items, or install a launch agent:

```sh
cp mac/dev.eterm.einkfocus.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/dev.eterm.einkfocus.plist
```

The first dictation asks for Microphone and Speech Recognition permission. Each rebuild is a new ad-hoc signature, so macOS may ask again after an update.

## Shortcuts

These work from any app:

| Keys | Does |
| --- | --- |
| ⌃⌥⌘K | Send keys to the Kindle, or give the keyboard back |
| ⌃⌥⌘D | Dictate to the Kindle. The phrase shows on the card in a second color while it forms, then types itself. Dictation never presses Return. |
| ⌃⌥⌘S | Next tmux session on the computer the Kindle is on |
| ⌃⌥⌘[ and ⌃⌥⌘] | Move the Kindle to the previous or next computer. ⌃⌥⌘H also moves to the next one. |
| ⌃⌥⌘J | With two Kindles connected, choose which one receives keys |
| ⌃⌥⌘− and ⌃⌥⌘= | Make the card more or less transparent |
| ⌃⌥⌘P | Pin the card, so it stays up when you switch apps |

While keys are going to the Kindle:

| Keys | Sends |
| --- | --- |
| Esc | Gives the keyboard back (stops dictation first, if it's running) |
| ⇧Esc | Esc, to the Kindle |
| ⇧Tab | Moves the Kindle to the next computer |
| ⌃⇧Tab | Switches to the other Kindle |
| ⌥ | Meta. ⌥← and ⌥→ move by word, ⌥⌫ deletes a word |
| ⌘← and ⌘→ | Start and end of the line (`C-a`, `C-e`) |
| ⌘↑ and ⌘↓ | Page Up and Page Down |
| ⌘⌫ and ⌘⌦ | Delete to the start or end of the line (`C-u`, `C-k`) |
| ⌘K | Clear the screen (`C-l`) |
| ⌘Z | Undo (`C-_`) |
| ⌘C | Copy the Kindle's screen to the Mac clipboard, or the tmux selection when the pane is in copy mode |
| ⌘V | Paste the Mac clipboard |

The card's arrows and computer names can be clicked too. Drag the card to park it; it remembers the spot. **Reset card position** in the menu puts it back.

## The menu

The menu shows whether the Kindle is attached to this Mac, the Kindle's Tailscale state, and whether each remote in the config is online. It has the same actions as the shortcuts, plus **Open config**, which shows the config file in Finder. Edits take effect the next time you open the menu.

## What it does on this Mac

- Runs `tmux`, `who`, `tailscale status` and `ssh` (with the key in `identity`) to find the Kindle and type into its session ([how-it-works.md](../docs/how-it-works.md)).
- Installs the `kterm-256color` terminfo entry into `~/.terminfo` if it's missing, and adds `kterm*:256` to the local tmux server's `terminal-features`.
- Sets `LC_CTYPE=en_US.UTF-8` on every command it runs when no UTF-8 locale is set, because tmux hides the Kindle from a non-UTF-8 client.

It doesn't listen on the network, doesn't need Accessibility access, and only reads the keyboard while it's sending keys to the Kindle.

## Troubleshooting

- **The card says NO KINDLE.** Check that the Kindle is logged in: `who` on the computer should show a login from the Kindle's address, and `tmux list-clients` its client. For a remote computer, check that `ssh -i ssh/kindle_eterm user@host true` works from this Mac without a prompt. The Kindle's tailnet name must be in `kindleHostnames`.
- **A remote never shows as online.** The menu lists each remote. Make sure the key in `identity` is authorized there and the host is reachable.
- **"This login can't switch yet."** The Kindle logged in with a remote command that lacks the `eterm-switch` part. Update the host list on the Kindle ([configuration.md](../docs/configuration.md#the-remote-command)) and log in again.

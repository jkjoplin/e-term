# Eink Focus for Android

The phone becomes the Kindle's keyboard. Type or dictate on the phone, and the text goes into the tmux session the Kindle is showing, on whichever computer that is. It's the keyboard half of [Eink Focus for Mac](../mac/README.md), for when you're away from the Mac's keyboard or the Kindle is logged into a computer you're not sitting at.

It needs Android 12 or newer, and network access to your computers. With hosts on a tailnet, that means Tailscale on the phone too.

## Install

You need the toolchain once. With Homebrew:

```sh
brew install openjdk@21
brew install --cask android-commandlinetools android-platform-tools
sdkmanager "platforms;android-37.0" "build-tools;37.0.0"
```

Installing the command line tools means accepting Google's Android SDK license.

Then:

1. On the phone, turn on Developer options → **USB debugging**, plug the phone into your computer, and accept the prompt on the phone.
2. Make sure `kindle/eterm/hosts`, `config/eink-focus.json` and `ssh/kindle_eterm` exist ([configuration.md](../docs/configuration.md)).
3. Run:

```sh
android/provision.sh
```

It builds the app, installs it, and copies two files into the app's private storage: the Kindle's OpenSSH key, and a host list generated from `kindle/eterm/hosts`, the Mac config and `tailscale status`. It checks that both arrived intact, then starts the app. Neither file goes into the APK or git.

After you change the host list or the Mac config, push only the new host list:

```sh
android/provision.sh --config
```

`provision.sh` uses `JAVA_HOME` and `ANDROID_HOME` if they're set, and otherwise the Homebrew locations above. With more than one device attached, pick one with `ANDROID_SERIAL=<serial>`. The app is a debug build; `provision.sh` relies on that to write into the app's storage with `adb run-as`.

## Use

The card works like the Mac's:

- The header shows the Kindle receiving keys, and the computer and tmux session it's on. With two Kindles connected, tap the Kindle's name to switch.
- The row of computer names follows the host list. Tap one, or the ‹ › arrows, to move the Kindle there. Computers that aren't set up yet (`REPLACE`) are dimmed. When no Kindle is found, the reason each computer gave is listed under the row.
- The paper panel shows the line you're typing. Tap it to bring the keyboard back.
- The key row sends esc, tab, a sticky ctrl (lit while armed; the next letter becomes Ctrl-letter), the arrows and Return.
- The bottom row sends ^C, switches to the next tmux session, toggles **text** mode, and starts **dictate**.

A Bluetooth keyboard paired to the phone works too. Shift-Tab moves the Kindle to the next computer.

### Terminal mode and text mode

By default the phone keyboard sends exact keystrokes: no autocorrect, no auto-capitals, no suggestions. That's right for commands, but it also makes most keyboards turn off their voice typing.

Tap **text** to switch the keyboard to a normal text field. The keyboard's own voice typing, autocorrect and swipe come back. The app keeps a copy of the line and sends each change to the Kindle as backspaces plus retyping, so corrections the keyboard makes, by hand or by voice, show up on the Kindle too. A spoken "new line" becomes a space. Only the ⏎ key presses Return. Any other key (esc, arrows, ^C, ⏎) starts a fresh line. The app remembers which mode you chose.

### Dictate

**dictate** uses Android's speech recognizer, on-device when the phone has it. It listens continuously, shows the phrase as it forms, and types each settled phrase with a space before it. It never presses Return. Tap **● done** to stop. The first time, it asks for the microphone.

## Security

- The key and host list are in the app's private storage, readable only by the app. App data is excluded from cloud backup and device transfer.
- The first connection to each computer pins its host key (`files/known_hosts`). A changed key is refused. To trust a computer's new key, clear the app's storage and provision again.
- Anyone who can unlock the phone can type into your Kindle's sessions with the app.

## Develop

```sh
cd android
./gradlew testDebugUnitTest
```

The unit tests cover the probe parser, the shell commands, the config, the line diff behind text mode, and the host key store. `LiveSshTest` also runs against a real computer when you point it at one; it reads the Kindle's session and types only into a scratch session it creates and deletes:

```sh
EF_LIVE_HOST=mac.example.ts.net EF_LIVE_USER=me EF_LIVE_KEY=../ssh/kindle_eterm ./gradlew testDebugUnitTest
```

`adb shell setprop log.tag.EinkFocusIME DEBUG` logs every call the keyboard makes in text mode to `adb logcat -s EinkFocusIME`. The log includes what you type.

| Path | What it is |
| --- | --- |
| `app/src/main/java/dev/eterm/focus/core/` | The engine: SSH, the probe and key loop commands, config parsing. No Android dependencies, so it runs in JVM tests. |
| `app/src/main/java/dev/eterm/focus/KeyCaptureView.kt` | The invisible view that owns the phone keyboard, in both modes |
| `app/src/main/java/dev/eterm/focus/Dictation.kt` | Continuous speech recognition |
| `app/src/main/java/dev/eterm/focus/ui/FocusScreen.kt` | The card, in Compose |
| `provision.sh` | Build, install, and copy the key and host list |

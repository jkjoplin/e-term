#!/bin/sh
# Installs Eink Focus on the phone plugged into this Mac and gives it the Kindle's SSH key
# and a host list. The key and the host list go into the app's private files, never into
# the APK or git.
#
# Usage: android/provision.sh            build, install, push key and config, launch
#        android/provision.sh --config   only regenerate and push the config
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PKG=dev.eterm.focus
KEY="$ROOT/ssh/kindle_eterm"
HOSTS="$ROOT/kindle/eterm/hosts"
MAC_CONFIG="$ROOT/config/eink-focus.json"
OUT="$ROOT/config/eink-focus-android.json"
TAILSCALE="${TAILSCALE:-/usr/local/bin/tailscale}"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"

command -v adb >/dev/null || { echo "adb is missing. brew install --cask android-platform-tools"; exit 1; }
[ -f "$KEY" ] || { echo "No key at $KEY"; exit 1; }
[ -f "$HOSTS" ] || { echo "No host list at $HOSTS"; exit 1; }

devices=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
count=$(printf '%s\n' "$devices" | grep -c . || true)
if [ "$count" -eq 0 ]; then
  echo "No phone is connected. Turn on USB debugging and plug it in, or pair Wireless debugging with adb pair."
  exit 1
fi
if [ "$count" -gt 1 ] && [ -z "${ANDROID_SERIAL:-}" ]; then
  echo "More than one device. Pick one with ANDROID_SERIAL=<serial>:"
  printf '%s\n' "$devices"
  exit 1
fi

# The phone's host list: the Kindle's hosts file, in its order, with the tmux path and the
# Kindle labels from the Mac app's config, and the Kindles' Tailscale addresses from this
# Mac's tailnet.
python3 - "$HOSTS" "$MAC_CONFIG" "$TAILSCALE" "$OUT" <<'PY'
import json, os, subprocess, sys
hosts, mac_config, tailscale, out = sys.argv[1:5]
mac = {}
if os.path.exists(mac_config):
    with open(mac_config) as f:
        mac = json.load(f)
default_tmux = mac.get("tmux", "/opt/homebrew/bin/tmux")
remote_tmux = {r.get("host"): r.get("tmux", default_tmux) for r in mac.get("remotes", [])}
computers = []
with open(hosts) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) < 5:
            continue
        cid, user, host, port, label = parts[:5]
        computers.append({
            "id": cid, "label": label, "user": user, "host": host,
            "port": int(port or 22), "tmux": remote_tmux.get(host, default_tmux),
        })
names = mac.get("kindleHostnames") or [mac.get("kindleHostname", "kindle")]
kindles = {}
try:
    status = json.loads(subprocess.run([tailscale, "status", "--json"], capture_output=True, text=True, timeout=5).stdout)
    for peer in (status.get("Peer") or {}).values():
        if peer.get("HostName") in names and peer.get("TailscaleIPs"):
            ip4 = [ip for ip in peer["TailscaleIPs"] if "." in ip]
            if ip4:
                kindles[peer["HostName"]] = ip4[0]
except Exception as e:
    print("tailscale status failed (%s); the phone will accept any 100.x login as a Kindle" % e)
labels = {k: v for k, v in (mac.get("kindleLabels") or {}).items() if k and v}
with open(out, "w") as f:
    json.dump({"computers": computers, "kindles": kindles, "labels": labels}, f, indent=2)
    f.write("\n")
print("config: %d computers, kindles %s" % (len(computers), ", ".join("%s=%s" % kv for kv in kindles.items()) or "none"))
PY

if [ "${1:-}" != "--config" ]; then
  (cd "$HERE" && ./gradlew --console=plain -q :app:assembleDebug)
  adb install -r "$HERE/app/build/outputs/apk/debug/app-debug.apk"
fi

# run-as works because this is a debug build. exec-in keeps the bytes intact. The device
# command is one string so the redirect runs inside run-as, as the app's own user.
# exec-in can return before the phone has finished writing, and anything chained after cat
# may never run. So write a temporary file, wait until its hash matches, then lock it down
# and move it into place in a separate command.
push() {
  part="files/.$2.part"
  want=$(shasum -a 256 "$1" | cut -d' ' -f1)
  adb exec-in "run-as $PKG sh -c 'umask 077; mkdir -p files && cat > $part'" < "$1"
  have=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    have=$(adb exec-out "run-as $PKG sha256sum $part" 2>/dev/null | cut -d' ' -f1)
    [ "$have" = "$want" ] && break
    sleep 0.5
  done
  if [ "$want" != "$have" ]; then
    adb exec-out "run-as $PKG rm -f $part" >/dev/null 2>&1 || true
    echo "files/$2 did not arrive intact on the phone (want $want, have ${have:-nothing})."
    exit 1
  fi
  adb exec-out "run-as $PKG sh -c 'chmod 700 files && chmod 600 $part && mv -f $part files/$2'"
  echo "files/$2 copied and checked."
}
push "$OUT" config.json
if [ "${1:-}" != "--config" ]; then
  push "$KEY" id_ed25519
fi

adb shell am force-stop "$PKG"
adb shell am start -n "$PKG/.MainActivity" >/dev/null
echo "Eink Focus is running on the phone."

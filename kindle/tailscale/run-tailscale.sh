#!/bin/sh
# Started in its own session so it keeps running after the Tailscale book closes.
# The node name on the tailnet comes from /mnt/us/extensions/tailscale/hostname, one
# word such as "kindle" or "scribe". Give each Kindle its own name. Without the file,
# Tailscale picks the name itself.
BIN=/mnt/us/extensions/tailscale/bin
NAME_FILE=/mnt/us/extensions/tailscale/hostname
NAME=""
if [ -s "$NAME_FILE" ]; then
  NAME=$(head -n 1 "$NAME_FILE" | tr -cd 'A-Za-z0-9-')
fi
STATUS=/mnt/us/documents/Tailscale-status.txt
UPLOG=$BIN/up.log

pkill tailscaled 2>/dev/null || true
sleep 1
mkdir -p /var/run/tailscale
rm -f /var/run/tailscale/tailscaled.sock

"$BIN/tailscaled" --statedir="$BIN/" -tun userspace-networking >> "$BIN/tailscaled.log" 2>&1 &
sleep 3

if [ -n "$NAME" ]; then
  "$BIN/tailscale" up --ssh --hostname="$NAME" --timeout=60s > "$UPLOG" 2>&1 || true
else
  "$BIN/tailscale" up --ssh --timeout=60s > "$UPLOG" 2>&1 || true
fi

{
  echo "Tailscale"
  echo
  echo "If a login.tailscale.com link is below, open it in a browser"
  echo "on a computer that is already signed in to Tailscale."
  echo
  echo "---- sign-in ----"
  cat "$UPLOG" 2>/dev/null
  echo
  echo "---- status ----"
  "$BIN/tailscale" status 2>&1 || true
  echo
  echo "---- this Kindle ----"
  "$BIN/tailscale" ip -4 2>&1 || true
} > "$STATUS"
sync

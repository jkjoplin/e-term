#!/bin/sh
# Name: Tailscale
# Author: e-term
BIN=/mnt/us/extensions/tailscale/bin
STATUS=/mnt/us/documents/Tailscale-status.txt

if [ ! -x "$BIN/tailscaled" ]; then
  echo "Tailscale program is missing."
  exit 1
fi

# Already signed in: show the result and leave the book quickly.
if "$BIN/tailscale" status > /tmp/ts-status.txt 2>&1; then
  {
    echo "Tailscale is running."
    echo
    cat /tmp/ts-status.txt
    echo
    echo "This Kindle:"
    "$BIN/tailscale" ip -4 2>&1 || true
  } | tee "$STATUS"
  exit 0
fi

# The login can take a minute. Do it outside this book so the
# Kindle does not close the page and kill the program with it.
if command -v setsid >/dev/null 2>&1; then
  setsid "$BIN/run-tailscale.sh" </dev/null >/dev/null 2>&1 &
else
  nohup "$BIN/run-tailscale.sh" </dev/null >/dev/null 2>&1 &
fi

echo "Tailscale is starting in the background."
echo "Wi-Fi has to be on, and the screen should stay awake."
echo
echo "Wait about a minute, then open the document named"
echo "Tailscale-status."
echo
echo "A login.tailscale.com link in that document is the sign-in page."
echo "Open it in any browser that is signed in to your Tailscale account."

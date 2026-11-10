#!/bin/sh
# Name: Terminal
# Author: e-term
# Opens kterm. If the SSH helper is present, the session starts in it.
EXTENSION=/mnt/us/extensions/kterm
if [ ! -x "$EXTENSION/bin/kterm" ]; then
  echo "kterm is not installed at $EXTENSION"
  exit 1
fi
if [ -f /mnt/us/eterm/connect.sh ]; then
  exec "$EXTENSION/bin/kterm.sh" -e /mnt/us/eterm/connect.sh
fi
exec "$EXTENSION/bin/kterm.sh"

#!/bin/sh
# Start the custom sleep screen if it is not already running.
# Safe to run at boot: a second run does not turn it off.
BASE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PIDFILE=/tmp/custom_ss_daemon.pid

if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi
fi

exec /bin/sh "$BASE/toggle.sh"

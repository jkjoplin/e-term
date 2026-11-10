#!/bin/sh
# Replacement for the kterm 2.6 armhf wrapper. The DPI and keyboard-layout lines are
# kterm's own, from https://github.com/bfabiszewski/kterm (GPL); see its license.
# Starts landscape, with a 256-color terminal and the on-screen keyboard hidden.
# A two-finger tap still opens Toggle keyboard for this session.
EXTENSION=/mnt/us/extensions/kterm
DPI=`cat /var/log/Xorg.0.log | grep DPI | sed -n 's/.*(\([0-9]\+\), [0-9]\+).*/\1/p'`
if [ ${DPI} -gt 290 ]; then
  PARAM="-l ${EXTENSION}/layouts/keyboard-300dpi.xml"
elif [ ${DPI} -gt 200 ]; then
  PARAM="-l ${EXTENSION}/layouts/keyboard-200dpi.xml"
fi
# kterm hands its child TERM=xterm whatever is exported here, so the TERM
# the computer sees is set in eterm/connect.sh. This export only covers
# a shell started without connect.sh. The compiled description lives in
# vte/terminfo, under both k/ and 6b/.
export TERM=kterm-256color
export TERMINFO=${EXTENSION}/vte/terminfo

# The sleep screen can still come up. This only postpones the deep sleep
# that drops Wi-Fi, and only while Terminal is open.
stay_awake() {
  while true; do
    if [ ! -x /usr/bin/lipc-wait-event ]; then
      sleep 60
      continue
    fi
    /usr/bin/lipc-wait-event -s 30 com.lab126.powerd readyToSuspend >/dev/null 2>&1
    /usr/bin/lipc-set-prop -i com.lab126.powerd deferSuspend 3600 >/dev/null 2>&1
  done
}
stay_awake &
awake_pid=$!

${EXTENSION}/bin/kterm ${PARAM} -c 1 -o L -k 0 "$@"
status=$?

kill "$awake_pid" 2>/dev/null
wait "$awake_pid" 2>/dev/null
exit $status

#!/bin/sh
# Pick a computer from /mnt/us/eterm/hosts and SSH to it.
# The key at /mnt/us/eterm/kindle_eterm must be Dropbear format.
# Usage: connect.sh            menu
#        connect.sh personal   connect straight to that id
# This is the TERM the computer sees. kterm starts this script with
# TERM=xterm, whatever kterm.sh exports. kterm-256color leaves out the
# cursor-shape, cursor-color and clipboard sequences that kterm's VTE 0.28
# paints as stray text. A computer without that terminfo entry falls back
# to xterm-256color in the remote command in hosts.
export TERM=kterm-256color
KO=/mnt/us/koreader
HOSTS=/mnt/us/eterm/hosts
KEY=/mnt/us/eterm/kindle_eterm
MENU=/tmp/eterm-menu
if [ -d "$KO/libs" ]; then
  export LD_LIBRARY_PATH="$KO/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
DB="$KO/dbclient"
if [ ! -x "$DB" ]; then
  echo "dbclient is missing at $DB"
  echo "Dropping to a local shell."
  exec /bin/sh
fi

lookup() {
  id="$1"
  while IFS= read -r line; do
    case "$line" in
      ""|\#*) continue ;;
    esac
    line_id=$(printf '%s' "$line" | cut -d'|' -f1)
    if [ "$line_id" = "$id" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$HOSTS"
  return 1
}

# Set by connect_line when the computer asks the Kindle to move on.
switch_to=""

next_ready_id() {
  current="$1"
  found=""
  first=""
  while IFS= read -r line; do
    case "$line" in
      ""|\#*) continue ;;
    esac
    id=$(printf '%s' "$line" | cut -d'|' -f1)
    host=$(printf '%s' "$line" | cut -d'|' -f3)
    case "$host" in
      ""|REPLACE|REPLACE_ME) continue ;;
    esac
    if [ -z "$first" ]; then
      first=$id
    fi
    if [ -n "$found" ]; then
      printf '%s\n' "$id"
      return 0
    fi
    if [ "$id" = "$current" ]; then
      found=1
    fi
  done < "$HOSTS"
  if [ -n "$found" ] && [ -n "$first" ] && [ "$first" != "$current" ]; then
    printf '%s\n' "$first"
    return 0
  fi
  return 1
}

# The ready host before current, wrapping around to the last.
prev_ready_id() {
  current="$1"
  found=""
  last=""
  while IFS= read -r line; do
    case "$line" in
      ""|\#*) continue ;;
    esac
    id=$(printf '%s' "$line" | cut -d'|' -f1)
    host=$(printf '%s' "$line" | cut -d'|' -f3)
    case "$host" in
      ""|REPLACE|REPLACE_ME) continue ;;
    esac
    if [ "$id" = "$current" ]; then
      if [ -n "$last" ]; then
        printf '%s\n' "$last"
        return 0
      fi
      found=1
    fi
    last=$id
  done < "$HOSTS"
  if [ -n "$found" ] && [ -n "$last" ] && [ "$last" != "$current" ]; then
    printf '%s\n' "$last"
    return 0
  fi
  return 1
}

# Ready hosts counted from zero, skipping empty and REPLACE rows.
id_at_index() {
  want="$1"
  n=0
  while IFS= read -r line; do
    case "$line" in
      ""|\#*) continue ;;
    esac
    id=$(printf '%s' "$line" | cut -d'|' -f1)
    host=$(printf '%s' "$line" | cut -d'|' -f3)
    case "$host" in
      ""|REPLACE|REPLACE_ME) continue ;;
    esac
    if [ "$n" -eq "$want" ]; then
      printf '%s\n' "$id"
      return 0
    fi
    n=$((n + 1))
  done < "$HOSTS"
  return 1
}

connect_line() {
  line="$1"
  id=$(printf '%s' "$line" | cut -d'|' -f1)
  user=$(printf '%s' "$line" | cut -d'|' -f2)
  host=$(printf '%s' "$line" | cut -d'|' -f3)
  port=$(printf '%s' "$line" | cut -d'|' -f4)
  label=$(printf '%s' "$line" | cut -d'|' -f5)
  remote=$(printf '%s' "$line" | cut -d'|' -f6-)
  if [ -z "$port" ]; then
    port=22
  fi
  case "$host" in
    ""|REPLACE|REPLACE_ME)
      echo "$label has no address yet."
      echo "Edit eterm/hosts on the Kindle from the Mac."
      return 1
      ;;
  esac
  echo "Connecting to $label ($user@$host)."
  echo "That computer needs Remote Login, and this key in authorized_keys."
  proxy=""
  # Userspace Tailscale has no route for ordinary sockets.
  # 100. addresses and MagicDNS names are dialed by tailscale nc.
  case "$host" in
    100.*|*.ts.net)
      proxy="/mnt/us/extensions/tailscale/bin/tailscale nc $host $port"
      echo "This address is on Tailscale. The Kindle has to be signed in."
      ;;
  esac
  if [ -n "$proxy" ] && [ -n "$remote" ]; then
    "$DB" -y -t -i "$KEY" -J "$proxy" "$user@$host" "$remote"
  elif [ -n "$proxy" ]; then
    "$DB" -y -t -i "$KEY" -J "$proxy" "$user@$host"
  elif [ -n "$remote" ]; then
    "$DB" -y -t -p "$port" -i "$KEY" "$user@$host" "$remote"
  else
    "$DB" -y -t -p "$port" -i "$KEY" "$user@$host"
  fi
  status=$?
  echo
  # The login script removes ~/.eterm-switch, then exits:
  #   40     next ready host
  #   41     previous ready host
  #   50+n   n-th ready host, counting from zero, through 80
  # Anything else is a normal disconnect. An old script only uses 40.
  if [ "$status" -eq 40 ]; then
    switch_to=$(next_ready_id "$id") || switch_to=""
    if [ -n "$switch_to" ]; then
      echo "Switching to the next computer."
      return 0
    fi
  elif [ "$status" -eq 41 ]; then
    switch_to=$(prev_ready_id "$id") || switch_to=""
    if [ -n "$switch_to" ]; then
      echo "Switching to the previous computer."
      return 0
    fi
  elif [ "$status" -ge 50 ] && [ "$status" -le 80 ]; then
    switch_to=$(id_at_index $((status - 50))) || switch_to=""
    if [ -n "$switch_to" ]; then
      echo "Switching computers."
      return 0
    fi
  fi
  echo "Disconnected from $label."
}

menu() {
  echo
  echo "Where should this Kindle connect?"
  echo
  n=0
  : > "$MENU"
  while IFS= read -r line; do
    case "$line" in
      ""|\#*) continue ;;
    esac
    n=$((n + 1))
    id=$(printf '%s' "$line" | cut -d'|' -f1)
    user=$(printf '%s' "$line" | cut -d'|' -f2)
    host=$(printf '%s' "$line" | cut -d'|' -f3)
    label=$(printf '%s' "$line" | cut -d'|' -f5)
    printf '%s %s\n' "$n" "$id" >> "$MENU"
    case "$host" in
      ""|REPLACE|REPLACE_ME)
        echo "$n  $label  (no address yet)"
        ;;
      *)
        echo "$n  $label  ($user@$host)"
        ;;
    esac
  done < "$HOSTS"
  echo
  echo "q  Local shell, no SSH"
  echo
  printf 'Choice: '
  read choice
  case "$choice" in
    q|Q) exec /bin/sh ;;
    "") return 0 ;;
  esac
  id=$(grep "^${choice} " "$MENU" | cut -d' ' -f2)
  if [ -z "$id" ]; then
    echo "No such choice."
    return 0
  fi
  line=$(lookup "$id") || {
    echo "No such host."
    return 0
  }
  connect_line "$line"
}

if [ ! -f "$HOSTS" ]; then
  echo "No host list at $HOSTS"
  exec /bin/sh
fi

if [ -n "$1" ]; then
  line=$(lookup "$1") || {
    echo "No host named $1"
    exec /bin/sh
  }
  connect_line "$line"
  if [ -z "$switch_to" ]; then
    echo "Back to the menu. q exits."
  fi
fi

while true; do
  if [ -n "$switch_to" ]; then
    id=$switch_to
    switch_to=""
    line=$(lookup "$id") || continue
    connect_line "$line"
  else
    menu
  fi
done

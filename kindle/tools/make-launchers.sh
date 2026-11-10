#!/bin/sh
# Writes one Kindle library "book" per computer in the host list. Opening the book on the
# Kindle starts Terminal and connects straight to that computer, skipping the menu.
#
# Usage: kindle/tools/make-launchers.sh [hosts file] [output folder]
#   defaults: kindle/eterm/hosts and kindle/documents/computers/
#
# Copy the output files into documents/ on the Kindle. The output folder is gitignored,
# because the labels name your computers.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
KINDLE_DIR="$(dirname "$HERE")"
HOSTS="${1:-$KINDLE_DIR/eterm/hosts}"
OUT="${2:-$KINDLE_DIR/documents/computers}"

[ -f "$HOSTS" ] || { echo "No host list at $HOSTS. Copy kindle/eterm/hosts.example to it first."; exit 1; }
mkdir -p "$OUT"

count=0
while IFS= read -r line; do
  case "$line" in
    ""|\#*) continue ;;
  esac
  id=$(printf '%s' "$line" | cut -d'|' -f1)
  label=$(printf '%s' "$line" | cut -d'|' -f5)
  # The id becomes a file name and an argument, so keep it to safe characters.
  case "$id" in
    *[!A-Za-z0-9_-]*|"") echo "Skipping id '$id': use letters, digits, - and _ only."; continue ;;
  esac
  [ -n "$label" ] || label=$id
  file="$OUT/$id.sh"
  {
    echo "#!/bin/sh"
    echo "# Name: $label"
    echo "# Author: e-term"
    echo "EXTENSION=/mnt/us/extensions/kterm"
    echo "exec \"\$EXTENSION/bin/kterm.sh\" -e \"/mnt/us/eterm/connect.sh $id\""
  } > "$file"
  echo "Wrote $file ($label)"
  count=$((count + 1))
done < "$HOSTS"

echo "$count launcher(s). Copy them to documents/ on the Kindle."

#!/bin/zsh
# Captures the main window's tabs and the menu bar panel from a Debug build in demo mode,
# so the images show made-up projects. Usage: scripts/screenshots.sh [light|dark]
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/dd/Build/Products/Debug/MacUnclog.app
MODE="${1:-dark}"
LOOK=(-MUAppearance "$MODE")
SUFFIX=$([[ "$MODE" == light ]] && echo "-light" || echo "")

capture() {
  local title=$1 file=$2
  shift 2
  pkill -x MacUnclog || true
  sleep 1
  open -n "$APP" --args -MUDemo YES -AppleLanguages '(en-GB)' -AppleLocale en_GB "${LOOK[@]}" "$@"
  local id=""
  for _ in {1..20}; do
    sleep 1
    id=$(swift scripts/window-id.swift MacUnclog | awk -v t="$title" '$0 ~ t {print $1; exit}')
    [[ -n "$id" ]] && break
  done
  open "$APP"   # brings the running instance to the front, so the window is active
  sleep 3
  for attempt in {1..5}; do
    screencapture -o -x -l "$id" "docs/screenshots/$file$SUFFIX.png" 2>/dev/null && break
    (( attempt == 5 )) && { echo "could not capture $file$SUFFIX" >&2; exit 1; }
    sleep 2
  done
  echo "captured $file$SUFFIX"
}

capture Overview overview -MUTab overview
capture Agents agents -MUTab agents
capture Processes processes -MUTab processes
capture Storage storage -MUTab disk
capture History history -MUTab history
capture "Menu bar" menubar -MUOpen menubar
pkill -x MacUnclog || true

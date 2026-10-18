#!/bin/bash
# Live log viewer for modded BTD6. Opened by the launcher in debug mode (_modkit/debug).
cd "$(dirname "$0")/.." || exit 1
printf '\033]0;BTD6 MelonLoader live log\007'
echo "Watching logs (close this window any time; it doesn't affect the game)"
echo
touch melonfix.log MelonLoader/Latest.log
tail -n +1 -F melonfix.log MelonLoader/Latest.log 2>/dev/null | grep --line-buffered -vE "^(==> .* <==)?$"

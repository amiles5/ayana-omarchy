#!/usr/bin/env bash
# Auto wallpaper changer, cycling sequentially through ~/Pictures/wallpapers
# (the same directory used for this on the ayana-cachyos install, via
# Noctalia's `[wallpaper] directory` there - this install doesn't use
# Noctalia, so this mirrors that behavior with a systemd timer +
# omarchy-theme-bg-set instead). Not scoped to the current Omarchy theme's
# own backgrounds/ folder (unlike `omarchy theme bg next`), so it survives a
# theme switch without needing a symlink update per theme.
#
# Same find/sort/wrap-around logic as the stock omarchy-theme-bg-next.
set -u

WALLPAPERS_DIR="$HOME/Pictures/wallpapers"
CURRENT_BACKGROUND_LINK="$HOME/.local/state/omarchy/current/background"

mapfile -d '' -t BACKGROUNDS < <(
  find -L "$WALLPAPERS_DIR" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) \
    -print0 2>/dev/null | sort -z
)
TOTAL=${#BACKGROUNDS[@]}

if (( TOTAL == 0 )); then
  omarchy-notification-send "No wallpapers found in $WALLPAPERS_DIR" -t 2000
  exit 1
fi

CURRENT_BACKGROUND=""
if [[ -L $CURRENT_BACKGROUND_LINK ]]; then
  CURRENT_BACKGROUND=$(readlink -f "$CURRENT_BACKGROUND_LINK")
fi

INDEX=-1
for i in "${!BACKGROUNDS[@]}"; do
  if [[ ${BACKGROUNDS[$i]} == "$CURRENT_BACKGROUND" ]]; then
    INDEX=$i
    break
  fi
done

if (( INDEX == -1 )); then
  NEW_BACKGROUND="${BACKGROUNDS[0]}"
else
  NEXT_INDEX=$(((INDEX + 1) % TOTAL))
  NEW_BACKGROUND="${BACKGROUNDS[$NEXT_INDEX]}"
fi

omarchy-theme-bg-set "$NEW_BACKGROUND"

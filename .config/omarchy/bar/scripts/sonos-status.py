#!/usr/bin/env python3
"""omarchy.bar `command` module for the `sonos` widget: prints Waybar-style
JSON showing whether any Sonos group is currently playing. Polled by the
bar every `interval` seconds (see ~/.config/omarchy/shell.json). Pairs with
sonos-toggle.py as `onClick`.

Icons match the built-in omarchy.audio widget's mute glyphs for visual
consistency (volume-high / volume-mute).
"""

import json
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.config/hypr/scripts"))
import sonos_lib  # noqa: E402


def main():
    playing_names = []
    for coord in sonos_lib.discover_coordinators():
        if sonos_lib.get_transport_state(coord["ip"]) == "PLAYING":
            playing_names.append(coord["name"])

    if playing_names:
        print(json.dumps({
            "text": "\U000F057E",
            "tooltip": "Sonos playing: " + ", ".join(playing_names) + " (click to pause)",
            "class": "active",
        }, ensure_ascii=False))
    else:
        print(json.dumps({
            "text": "\U000F075F",
            "tooltip": "Sonos paused (click to resume)",
            "class": "",
        }, ensure_ascii=False))


if __name__ == "__main__":
    main()

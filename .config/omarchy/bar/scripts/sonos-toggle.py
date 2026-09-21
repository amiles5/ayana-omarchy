#!/usr/bin/env python3
"""omarchy.bar `onClick` handler for the `sonos` widget: a simple house-wide
active/mute switch. If any Sonos group is currently playing, pauses all of
them ("mute"); otherwise resumes all of them ("active"). Pairs with
sonos-status.py, which the bar re-polls afterwards to reflect the new
state.

This is a manual, all-or-nothing switch - not a "restore exactly what was
playing before" toggle like sonos-ducking.sh's auto-ducking (which only
ever resumes a group it itself paused). Clicking "resume" here will start
playback on every group that has something cued, even if it had been
paused for an unrelated reason.
"""

import os
import sys

sys.path.insert(0, os.path.expanduser("~/.config/hypr/scripts"))
import sonos_lib  # noqa: E402


def main():
    coordinators = sonos_lib.discover_coordinators()
    states = {c["ip"]: sonos_lib.get_transport_state(c["ip"]) for c in coordinators}

    if any(s == "PLAYING" for s in states.values()):
        for coord in coordinators:
            if states.get(coord["ip"]) == "PLAYING":
                sonos_lib.pause(coord["ip"])
    else:
        for coord in coordinators:
            sonos_lib.play(coord["ip"])


if __name__ == "__main__":
    main()

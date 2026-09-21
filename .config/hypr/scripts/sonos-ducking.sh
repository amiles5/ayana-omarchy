#!/usr/bin/env python3
"""Auto-pause Sonos when the Studio Display's own speakers start making
sound (a call, a video, a notification), and resume it once the host goes
quiet again - so the two don't overlap in the same physical room.

Standalone port of the ducking logic from amiles5/ayana-cachyos's
sonos-control Noctalia plugin (service.luau), without the rest of that
plugin (no bar widget, no room-grouping UI, no Favourites) - the bar now
has its own minimal `sonos` command-module widget instead (see
~/.config/omarchy/bar/scripts/), sharing the SOAP/topology helpers in
sonos_lib.py rather than duplicating them.

Unlike ayana-cachyos's version - which tracked a single UI-selected "active
room" and a static per-room table - this one has no UI to select a room
from, and a live test on this household's actual speakers (2026-09-21)
showed all four are currently one Sonos group. Non-coordinator group
members reject direct Pause/Play with an HTTP 500 (UPnP requires transport
commands go to the group's coordinator), so pausing "whichever named room
is PLAYING" doesn't work when rooms are grouped. This version resolves
actual group coordinators via ZoneGroupTopology's GetZoneGroupState on
every check instead of a static ROOMS/coordinator table, and only ever
sends Pause/Play to a coordinator's own IP. That also sidesteps a real bug
already hit once in ayana-cachyos, where a speaker got renamed in the
Sonos app and the hardcoded room name in service.luau went stale - here
room/group names are only ever read live off the topology, never
hardcoded.

Runs under systemd --user as sonos-ducking.service.
"""

import logging
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sonos_lib  # noqa: E402

HOST_SINK = "alsa_output.usb-Apple_Inc._Studio_Display_00008030-001324E63E40A02E-02.analog-stereo"
POLL_INTERVAL_SECONDS = 5

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s sonos-ducking: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("sonos-ducking")


def host_sink_running():
    try:
        out = subprocess.run(
            ["pactl", "list", "sinks", "short"],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        ).stdout
    except (subprocess.SubprocessError, OSError) as e:
        log.warning("pactl list sinks short failed: %s", e)
        return None
    for line in out.splitlines():
        if HOST_SINK in line:
            return "RUNNING" in line
    return None


def on_host_audio_start():
    paused = []
    for coord in sonos_lib.discover_coordinators():
        state = sonos_lib.get_transport_state(coord["ip"])
        if state == "PLAYING":
            log.info("Pausing %s (%s, was PLAYING)", coord["name"], coord["ip"])
            sonos_lib.pause(coord["ip"])
            paused.append(coord)
    return paused


def on_host_audio_stop(paused_coordinators):
    for coord in paused_coordinators:
        # Pausing a live stream (radio, etc.) often reports STOPPED rather
        # than PAUSED_PLAYBACK, so both count as "we paused it, safe to
        # resume". Anything else means something already changed its
        # transport while the host was making noise - leave it alone.
        state = sonos_lib.get_transport_state(coord["ip"])
        if state in ("PAUSED_PLAYBACK", "STOPPED"):
            log.info("Resuming %s (%s, was %s)", coord["name"], coord["ip"], state)
            sonos_lib.play(coord["ip"])
        else:
            log.info(
                "Not resuming %s (%s, now %s, something else changed it)",
                coord["name"],
                coord["ip"],
                state,
            )


def main():
    host_audio_active = False
    auto_paused_coordinators = []

    log.info("Watching sink %s every %ds", HOST_SINK, POLL_INTERVAL_SECONDS)

    while True:
        running = host_sink_running()
        if running is None:
            log.warning("Sink %s not found in pactl output (not authorized/connected yet?)", HOST_SINK)
        elif running and not host_audio_active:
            host_audio_active = True
            auto_paused_coordinators = on_host_audio_start()
        elif not running and host_audio_active:
            host_audio_active = False
            on_host_audio_stop(auto_paused_coordinators)
            auto_paused_coordinators = []

        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()

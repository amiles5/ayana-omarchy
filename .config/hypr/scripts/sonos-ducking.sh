#!/usr/bin/env python3
"""Auto-pause Sonos when the Studio Display's own speakers start making
sound (a call, a video, a notification), and resume it once the host goes
quiet again - so the two don't overlap in the same physical room.

Standalone port of the ducking logic from amiles5/ayana-cachyos's
sonos-control Noctalia plugin (service.luau), without the rest of that
plugin (no bar widget, no room-grouping UI, no Favourites).

Unlike that version - which tracked a single UI-selected "active room" and
a static per-room table - this one has no UI to select a room from, and a
live test on this household's actual speakers (2026-09-21) showed all four
are currently one Sonos group. Non-coordinator group members reject direct
Pause/Play with an HTTP 500 (UPnP requires transport commands go to the
group's coordinator), so pausing "whichever named room is PLAYING" doesn't
work when rooms are grouped. This version resolves actual group
coordinators via ZoneGroupTopology's GetZoneGroupState on every check
instead of a static ROOMS/coordinator table, and only ever sends Pause/Play
to a coordinator's own IP. That also sidesteps a real bug already hit once
in ayana-cachyos, where a speaker got renamed in the Sonos app and the
hardcoded room name in service.luau went stale - here room/group names are
only ever read live off the topology, never hardcoded.

BOOTSTRAP_IPS below are just known-reachable speakers to query the
topology from (any one responding is enough) - not a source of truth for
grouping or naming. If every bootstrap IP goes stale (a speaker replaced,
DHCP reassignment), rediscover with `avahi-browse -a -t | grep _sonos`.

Runs under systemd --user as sonos-ducking.service.
"""

import html
import logging
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOST_SINK = "alsa_output.usb-Apple_Inc._Studio_Display_00008030-001324E63E40A02E-02.analog-stereo"
POLL_INTERVAL_SECONDS = 5

BOOTSTRAP_IPS = [
    "192.168.1.181",
    "192.168.1.194",
    "192.168.1.204",
    "192.168.1.227",
]

TRANSPORT_STATE_RE = re.compile(r"<CurrentTransportState>(.*?)</CurrentTransportState>")
ZONE_GROUP_STATE_RE = re.compile(r"<ZoneGroupState>(.*?)</ZoneGroupState>", re.S)
ZONE_GROUP_RE = re.compile(r'<ZoneGroup Coordinator="([^"]+)"[^>]*>(.*?)</ZoneGroup>', re.S)
ZONE_MEMBER_RE = re.compile(
    r'<ZoneGroupMember UUID="([^"]+)"[^>]*Location="([^"]+)"[^>]*ZoneName="([^"]+)"'
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s sonos-ducking: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("sonos-ducking")


def http_post(ip, path, service, action, body, timeout=3):
    envelope = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:{action} xmlns:u="urn:schemas-upnp-org:service:{service}:1">'
        "{body}"
        "</u:{action}></s:Body></s:Envelope>"
    ).format(action=action, service=service, body=body)

    req = urllib.request.Request(
        url="http://{}:1400{}".format(ip, path),
        data=envelope.encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPAction": '"urn:schemas-upnp-org:service:{}:1#{}"'.format(service, action),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, OSError) as e:
        log.warning("SOAP %s to %s failed: %s", action, ip, e)
        return None


def av_transport(ip, action, body):
    return http_post(ip, "/MediaRenderer/AVTransport/Control", "AVTransport", action, body)


def get_transport_state(ip):
    body = av_transport(ip, "GetTransportInfo", "<InstanceID>0</InstanceID>")
    if body is None:
        return None
    m = TRANSPORT_STATE_RE.search(body)
    return m.group(1) if m else None


def pause(ip):
    av_transport(ip, "Pause", "<InstanceID>0</InstanceID>")


def play(ip):
    av_transport(ip, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")


def discover_coordinators():
    """Query any reachable speaker for the household's current Sonos
    topology and return one {ip, name} per group coordinator (i.e. one
    entry per independently-controllable group/standalone player right
    now)."""
    for ip in BOOTSTRAP_IPS:
        body = http_post(
            ip,
            "/ZoneGroupTopology/Control",
            "ZoneGroupTopology",
            "GetZoneGroupState",
            "",
            timeout=3,
        )
        if body is None:
            continue
        m = ZONE_GROUP_STATE_RE.search(body)
        if not m:
            continue
        state = html.unescape(m.group(1))

        coordinators = []
        for group_m in ZONE_GROUP_RE.finditer(state):
            coordinator_uuid, members_xml = group_m.group(1), group_m.group(2)
            for member_m in ZONE_MEMBER_RE.finditer(members_xml):
                uuid, location, name = member_m.groups()
                if uuid == coordinator_uuid:
                    member_ip = location.split("//")[1].split(":")[0]
                    coordinators.append({"ip": member_ip, "name": name})
                    break
        if coordinators:
            return coordinators

        log.warning("Got a ZoneGroupState from %s but couldn't parse any groups out of it", ip)

    log.warning("Couldn't reach any bootstrap speaker (%s) to discover the current topology", BOOTSTRAP_IPS)
    return []


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
    for coord in discover_coordinators():
        state = get_transport_state(coord["ip"])
        if state == "PLAYING":
            log.info("Pausing %s (%s, was PLAYING)", coord["name"], coord["ip"])
            pause(coord["ip"])
            paused.append(coord)
    return paused


def on_host_audio_stop(paused_coordinators):
    for coord in paused_coordinators:
        # Pausing a live stream (radio, etc.) often reports STOPPED rather
        # than PAUSED_PLAYBACK, so both count as "we paused it, safe to
        # resume". Anything else means something already changed its
        # transport while the host was making noise - leave it alone.
        state = get_transport_state(coord["ip"])
        if state in ("PAUSED_PLAYBACK", "STOPPED"):
            log.info("Resuming %s (%s, was %s)", coord["name"], coord["ip"], state)
            play(coord["ip"])
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

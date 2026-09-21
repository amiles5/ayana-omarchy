"""Shared Sonos UPnP/SOAP helpers - group coordinator discovery, transport
state, play/pause. Used by sonos-ducking.sh (systemd service) and the
omarchy.bar `sonos` command-module scripts under
~/.config/omarchy/bar/scripts/.

See sonos-ducking.sh's module docstring for why this resolves group
coordinators live via ZoneGroupTopology on every call instead of a static
per-room table.
"""

import html
import logging
import re
import urllib.error
import urllib.request

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

log = logging.getLogger("sonos_lib")


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

#!/usr/bin/env python3
"""omarchy.bar `command` module: mouse + keyboard battery, read from
`solaar show all` (the standard Linux tool for Logitech's HID++ protocol -
these percentages aren't exposed via UPower or any generic USB descriptor on
this system, confirmed via `upower -e` showing no HID++ devices).

Polled by the bar every `interval` seconds (see ~/.config/omarchy/shell.json;
120s here, not the 5s used by the Sonos widgets - see below).
`solaar show` has no machine-readable output mode, so this parses its plain
text - matched by "Kind" (mouse/keyboard) rather than device name, so a
future device swap doesn't need a code change. A second, currently-idle Bolt
receiver on this machine lists the same two devices again as "Device is
offline." - skipped, first (connected) reading for each kind wins.

`solaar show` has no persistent daemon to query - each CLI invocation
re-walks the full HID++ feature set from scratch, live over the radio. Timed
at ~6s for one device, ~14s for `all` (2 devices + probing the second,
currently-empty Bolt receiver). Not a fit for a short poll interval; 120s is
plenty for something that only changes over hours.
"""

import json
import re
import subprocess

# Two-space indent exactly: top-level "N: Device Name" lines under a
# receiver. Deeper HID++ feature lines are indented much further, so this
# doesn't collide with them.
DEVICE_HEADER_RE = re.compile(r"^  \d+: (.+)$")
KIND_RE = re.compile(r"^\s+Kind\s*:\s*(\S+)")
BATTERY_RE = re.compile(r"Battery:\s*(\d+)%,\s*BatteryStatus\.(\S+?)\.?\s*$")
OFFLINE_RE = re.compile(r"Device is offline\.")

ICONS = {"mouse": "\U000F037D", "keyboard": "\U000F030C"}


def read_devices():
    try:
        out = subprocess.run(
            ["solaar", "show", "all"],
            capture_output=True,
            text=True,
            timeout=25,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return {}

    devices = {}
    name = None
    kind = None
    for line in out.splitlines():
        header = DEVICE_HEADER_RE.match(line)
        if header:
            name, kind = header.group(1).strip(), None
            continue
        if name is None:
            continue
        kind_m = KIND_RE.match(line)
        if kind_m:
            kind = kind_m.group(1)
            continue
        if OFFLINE_RE.search(line):
            name = None
            continue
        battery_m = BATTERY_RE.search(line)
        if battery_m and kind in ("mouse", "keyboard") and kind not in devices:
            devices[kind] = {
                "name": name,
                "battery": int(battery_m.group(1)),
                "status": battery_m.group(2),
            }
            name = None
    return devices


def main():
    devices = read_devices()

    if not devices:
        print(json.dumps({
            "text": ICONS["mouse"] + " ?",
            "tooltip": "No Logitech devices found (solaar show all returned nothing)",
            "class": "",
        }, ensure_ascii=False))
        return

    parts = []
    tooltip_lines = []
    for kind in ("mouse", "keyboard"):
        dev = devices.get(kind)
        if dev:
            parts.append("{} {}%".format(ICONS[kind], dev["battery"]))
            tooltip_lines.append("{}: {}% ({})".format(dev["name"], dev["battery"], dev["status"].title()))
        else:
            parts.append("{} ?".format(ICONS[kind]))
            tooltip_lines.append("{}: not connected".format(kind.title()))

    print(json.dumps({
        "text": "  ".join(parts),
        "tooltip": "\n".join(tooltip_lines),
        "class": "",
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()

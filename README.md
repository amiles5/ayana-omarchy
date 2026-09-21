# ayana-omarchy

Notes on `ayana`, the same physical machine documented in
[`amiles5/ayana-cachyos`](https://github.com/amiles5/ayana-cachyos), now running a fresh
**Omarchy 4** install (separate SSD/config, not a migration of the CachyOS dotfiles).

## Audio — Apple Studio Display over Thunderbolt (2026-09-21)

**Symptom:** fresh Omarchy 4 install. Studio Display video worked immediately, but no audio
output — `wpctl status` showed only a `Dummy Output` sink, no real sink at all (not even the
onboard Ryzen analog codec had a working playback sink).

**Investigation:**

- `wpctl status` / `pactl list cards` showed both ALSA cards (Radeon HDMI/DP audio controller,
  Ryzen onboard codec) present but sitting on profile `off`, ports all "not available".
  Root cause of *that* symptom: current WirePlumber ships `api.acp.auto-profile = false` and
  `api.acp.auto-port = false` by default (`/usr/share/wireplumber/scripts/monitors/alsa.lua`),
  so nothing auto-selects a profile on first boot — a red herring for this specific issue,
  though worth knowing in general.
- `/proc/asound/card0/eld#*` showed `monitor_present 0` / `eld_valid 0` on every HDMI/DP pin
  on the Radeon controller, even after manually forcing an `output:hdmi-stereo` profile —
  despite `hyprctl monitors` and `/sys/class/drm/card0-DP-2/status` both confirming the
  Studio Display connected and driving video on `DP-2`.
- This matched the same root cause already documented in `ayana-cachyos`: **the Studio
  Display's speakers/mic/camera are tunnelled over USB inside the Thunderbolt/USB4 link, not
  over standard DisplayPort audio.** Video rides the DP-alt-mode path and works independently;
  audio/mic/webcam only appear once the Thunderbolt device itself is authorized.
- `boltctl list` confirmed it: the Studio Display showed `status: connected` but
  `stored: no` — `bolt` (already installed and running on Omarchy by default) had never been
  told to authorize it. `/sys/bus/thunderbolt/devices/0-2/authorized` was `0`.

**Fix:**

```
sudo boltctl enroll --policy auto ba010000-0082-8c0e-8304-1e03d721e809
```

Authorizes the display immediately and stores an `auto` policy so it self-authorizes on every
future boot/reconnect — no manual step needed again. Same fix as `ayana-cachyos`, just never
applied yet on this install since it's a separate `bolt` device database.

**Verified live:**

- `wpctl status` → `Studio Display Analog Stereo` sink (auto-selected as default), `Studio
  Display Mono` source (auto-selected as default mic), `Studio Display` V4L2 device (webcam)
  all appeared within seconds of authorization, no reboot required.
- Real ALSA sink name:
  `alsa_output.usb-Apple_Inc._Studio_Display_00008030-001324E63E40A02E-02.analog-stereo`
  (a genuine `snd_usb_audio` device, not the Radeon HDMI/DP ALSA card).
- Confirmed audible with `speaker-test -D pipewire -c 2 -t sine -f 440 -l 1`, user confirmed
  hearing the tone.
- Reverted the earlier diagnostic HDMI-profile change on the Radeon card
  (`pactl set-card-profile alsa_card.pci-0000_35_00.1 off`) — it's unused now that the real
  audio path is the USB tunnel, left as found.

### Known related risk (not yet seen on Omarchy, watch for it)

`ayana-cachyos` documents an intermittent **boot-time DP tunnel race**: even with `bolt`
auto-policy enrolled, the Studio Display's DP tunnel occasionally fails to activate if it's
requested before the machine's own USB4 retimer has finished initializing — video-only
symptom, not audio. Fixed there with a user systemd service
(`studio-display-tunnel-fix.sh`) that polls for the display via `hyprctl monitors` after
login and, if it doesn't show up within ~10s, deauthorizes/reauthorizes the Thunderbolt
device to force a fresh tunnel-activation attempt. Not ported here yet — this install hasn't
exhibited the race. Port it over if it does.

`ayana-cachyos` also documents a **resume-from-suspend** variant where the HDMI/DP audio ELD
goes stale after a DPIA AUX hiccup on wake (fixed there with a root `system-sleep` hook that
retriggers `amdgpu`'s `trigger_hotplug` debugfs file and restarts PipeWire). Not relevant to
today's fix (this was a cold-boot issue, not suspend/resume) and not yet verified as
applicable to Omarchy's PipeWire/kernel versions — revisit if the same symptom shows up after
a suspend/resume cycle on this install.

## Sonos ducking (`.config/hypr/scripts/sonos-ducking.sh`, systemd user service)

Ported the "auto-pause Sonos when the Studio Display's own speakers make noise" feature from
`ayana-cachyos`'s `sonos-control` Noctalia plugin — but standalone, not the full plugin.
That plugin (bar widget, play/pause, room grouping UI, Favourites) doesn't exist on this
install and porting all of it wasn't in scope here; just the ducking behaviour, as its own
script + systemd user service.

- **What it does:** polls `pactl list sinks short` every 5s for the Studio Display's sink
  going `RUNNING` (a call, a video, a notification). On the idle→running edge, pauses
  whatever's currently playing on Sonos; on running→idle, resumes it — same logic as
  `ayana-cachyos`'s version, down to treating `STOPPED` as resumable alongside
  `PAUSED_PLAYBACK` (pausing a live-radio stream usually reports `STOPPED`, since most
  streams can't be truly paused), and only resuming if nothing else changed the transport
  while the host was making noise.
- **Diverges from `ayana-cachyos` on grouping, and this mattered immediately:** that version
  tracked one UI-selected "active room" against a static `ROOMS` table. This one has no UI to
  select a room from, so it originally just paused whichever of the four known speakers
  reported `PLAYING`. A live test (2026-09-21) showed all four are currently one Sonos group
  coordinated by Dining — sending `Pause` straight to a non-coordinator member's own IP is
  rejected with an HTTP 500 (Sonos/UPnP requires transport commands go to the group
  coordinator), so 3 of 4 pause attempts silently failed. Rewrote it to call
  `GetZoneGroupState` (ZoneGroupTopology) live on every check and resolve actual group
  coordinators dynamically, rather than hardcoding room→coordinator relationships — this also
  means it can't go stale the way `ayana-cachyos` did once already (a speaker got renamed in
  the Sonos app and its hardcoded room name in `service.luau` went stale until caught and
  fixed by hand). `BOOTSTRAP_IPS` in the script is just known-reachable speakers to query the
  topology from — not a source of truth for names or grouping.
- **Verified live** against the real household speakers both before and after the grouping
  fix: broken version left 3 of 4 speakers still playing after a "duck" (500s, never actually
  paused — but the resume-side safety check correctly declined to touch them since their
  state was never `PAUSED_PLAYBACK`/`STOPPED`, so no incorrect action was taken either way);
  fixed version cleanly paused the one actual coordinator (Dining) and resumed it a few
  seconds later, no errors.
- Enabled via `systemctl --user enable --now sonos-ducking.service`
  (`WantedBy=graphical-session.target`, `Restart=always`), same
  `graphical-session.target`-based user-service pattern `ayana-cachyos` uses for
  `studio-display-tunnel-fix.service` (not itself ported here — see above).

## Default browser — Firefox (`.config/mimeapps.list`)

Switched the default browser to Firefox via `omarchy default browser firefox`, which sets it
through `xdg-settings` (Omarchy's XDG handler wrapper, not a Hyprland/shell config file).
Tracked here as `.config/mimeapps.list` since it's the actual file that command writes to —
`text/html`, `http`/`https`/`about`/`unknown` scheme handlers all point to `firefox.desktop`.
`mailto` stays on `HEY.desktop` and `claude-cli` on `claude-code-url-handler.desktop`,
untouched by the browser switch.

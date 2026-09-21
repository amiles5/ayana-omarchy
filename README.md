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

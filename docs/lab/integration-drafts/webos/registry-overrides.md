# Registry / SPA override draft — Palm/HP webOS

Prep only. Apply after the preserved OVA hardware is inventoried and boots under QEMU.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `Palm webOS` or `HP webOS` matching the final appliance |
| `museum.year` | `2009` for phone-era webOS; `2011` for TouchPad image |
| `museum.lineage` | `Palm OS → webOS` |
| `museum.arch` | `x86 SDK emulator image (device UI emulates Palm/HP hardware)` |
| `museum.era` | `2000s` or `2010s` matching final image |
| `spa.archetypeId` | `touch-phone` |
| `spa.eraLabel` | `2009 · Palm webOS` provisional |
| `ui` | `mobile` |
| accent | proposed `#d85d70` |

## Proposed software fields

- `eraSoftware`: Luna, Card view, Launcher, Universal Search
- `iconicApps`: Card view, Launcher
- `periodBrowser`: webOS Browser if usable in preserved image
- blurb: `Palm rebuilt its handheld platform around gestures and visible multitasking — applications become cards you can switch, stack and throw away.`

## Interaction/runtime intent

- pointer: absolute USB tablet/touch equivalent
- keyboard: Home/End/Left/Right/Esc hardware-event mapping should be exposed cleanly
- audio: off unless the SDK image proves it
- reset: loadvm golden or pristine converted disk copy, whichever proves stable

## Intended rest scene

Card view with two cards open and Launcher/quick-launch immediately accessible.

## MEASURE before promotion

- exact webOS appliance/version/device type
- OVF RAM/CPU/controller/NIC/display
- QEMU machine/device set
- pointer behavior
- golden vs disk-copy reset path

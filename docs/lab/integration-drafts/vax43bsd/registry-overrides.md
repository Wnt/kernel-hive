# Registry / SPA override draft — 4.3BSD on VAX-11/780

Prep only. Apply after SIMH + DZ terminal reaches multiuser login.

## Proposed identity

| Field | Proposed value |
|---|---|
| `museum.displayName` | `4.3BSD on VAX-11/780` |
| `museum.year` | `1986` |
| `museum.lineage` | `Research Unix → BSD → 4.3BSD` |
| `museum.arch` | `DEC VAX-11/780` |
| `museum.era` | `1980s` |
| `spa.archetypeId` | `mono-terminal` |
| `spa.eraLabel` | `1986 · 4.3BSD / VAX` |
| `ui` | `text-console` |
| accent | proposed DEC blue-grey `#67828f` |

## Proposed software fields

- `eraSoftware`: shell, sockets/TCP-IP tools, vi, man, compiler toolchain
- `iconicApps`: `netstat`, `vi`, shell
- `periodBrowser`: none
- blurb: `Berkeley Unix on the VAX — the university environment in which sockets and the BSD TCP/IP stack became part of ordinary Unix programming.`

## Interaction/runtime intent

- published surface: DZ/telnet user line, never SIMH console
- pointer: none
- keyboard: terminal input
- reset: pristine RA81 seed copy + SIMH relaunch

## Intended rest scene

Multiuser login or root shell showing `uname`, `who`, and optionally `netstat`.

## MEASURE before promotion

- SIMH commit/version
- RAM/disk/controller config
- DZ port and terminal emulation
- boot-to-login time
- optional Ethernet configuration

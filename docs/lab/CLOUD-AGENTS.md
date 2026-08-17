# Cloud coding agents in the lab (Google Jules, Claude cloud sessions)

Cloud agents run their editor and their shell in someone else's datacentre. That
is fine for `spa/` and for docs, and useless for everything this repo is
actually about: a change to a station launcher, a daemon knob, or a guest agent is
only real once it has been driven against labhost and verified on a framebuffer.

So the cloud agent needs `ssh lab`. This doc is how it gets it — and the
constraints that shaped the design:

- **No inbound port on the home WAN.** labhost dials OUT; nothing on the home
  router is opened or forwarded.
- **The public door is not the LAN door.** What the internet can reach is a
  second, purpose-built sshd that accepts exactly one key and nothing else.
- **One-file revocation.** Cutting every cloud agent off is truncating one
  `authorized_keys` and restarting one unit. It never disturbs how you, or
  anything on the LAN, reach labhost.

## Shape

```
   Jules VM / Claude cloud session            (Google/Anthropic cloud)
     $ ssh lab  ──►  tunnel.example.com:10022
                        │  public TCP port, opened by the forwarder
   ┌────────────────────┼─ vm-control (small public VPS, Wnt/forwarder) ─────┐
   │  forwarder-server  ─┘   nftables already allows tcp/10000-19999          │
   └────────────────────▲────────────────────────────────────────────────────┘
                        │ ONE persistent wss, dialled OUT (NAT-friendly)
   ┌────────────────────┼─ labhost, the lab box (home LAN, no open ports) ───┐
   │  forwarder-agent.service ──► 127.0.0.1:2222                              │
   │  sshd-cloud-agent.service   loopback-only sshd, key-only, 1 key          │
   │      └─ root shell ─► labctl / stations / streamhost / QEMU              │
   │  ssh.service (:22)          the LAN door — untouched by any of this      │
   └──────────────────────────────────────────────────────────────────────────┘
```

The tunnel is [Wnt/forwarder](https://github.com/Wnt/forwarder), already
deployed on `vm-control` for other guests; this reuses its raw-TCP mode
(`FORWARDER_TCP_PORT_RANGE=10000-19999`) and its existing shared agent token.
Nothing about the forwarder deployment had to change.

`sshd-cloud-agent` binds `127.0.0.1` only. It is unreachable from the LAN, from
the Proxmox bridge, from a guest VM — the tunnel is the *only* path to it. It
serves labhost's normal ed25519 host key, so one `known_hosts` line is valid for
both doors.

## Facts

| Thing | Value |
|---|---|
| Public endpoint | `tunnel.example.com:10022` |
| Loopback sshd | `127.0.0.1:2222`, unit `sshd-cloud-agent.service` |
| Tunnel unit | `forwarder-agent.service` (`DynamicUser`, dial-out only) |
| Config / keys | `/etc/cloud-agent-ssh/{sshd_config,authorized_keys}` |
| Tunnel env | `/etc/forwarder-agent/agent.env` (0600; forwarder shared token) |
| Agent identity | ed25519, comment `cloud-agent@osgallery-lab (jules)` |
| Login | `root` (labhost is driven as root — `labctl`, QMP sockets, systemd) |

## CT950, `/data`, and `labrun`

`ssh lab` lands you on labhost, not in CT950 — CT950 is a separate container
(`ssh lab 'pct exec 950 -- <cmd>'`). Since 2026-08-17 CT950 has `/data/vms`,
`/data/kernel-hive`, `/data/gallery-guests`, `/data/isos` and
`/data/media-archive` bind-mounted (`pct` mountpoints, survive restarts), so a
session running inside CT950 reads/edits box files directly with local tools
— no `scp`, no heredoc round trip for a probe. **Process control is still a
labhost-only door**: `systemctl`, `qm`, `pct`, `clone-guard`, `chroot-guard`
and any kill act on guests only via `ssh lab` from CT950 (or the cloud-agent
tunnel above), never by reaching into `/data` and touching a live process's
files directly.

For anything past a one-liner, use `scripts/dev/labrun <<'EOF' … EOF` (or
`labrun file.sh args`) instead of a hand-quoted `ssh lab 'bash -s' <<EOF`
heredoc: it ships the script by stdin with no local quoting, runs it under
`set -euo pipefail` with `$KH_SESSION` forwarded, uses `ssh -n` so a loop of
calls cannot eat the outer script's stdin, and keeps the exact script on
labhost under `/run/kh-labrun/<session>/` on failure (`--keep`) for a replay.
Never nest `ssh lab` inside `ssh lab`. `~/.ssh/config` on CT950 sets
`ControlMaster auto` / `ControlPersist` for `Host lab`, so a warm connection
is ~14 ms instead of ~0.4 s per hop — the same win applies to a cloud agent's
tunnelled `ssh lab` once it is configured the same way.

## Install / re-run

Everything is idempotent; re-run after a key rotation, a port change, or a
rebuild.

```bash
ssh-keygen -t ed25519 -C 'cloud-agent@osgallery-lab' -f ~/.ssh/lab_cloudagent
scripts/cloud-agents/install-box-endpoint.sh --pubkey ~/.ssh/lab_cloudagent.pub
scripts/cloud-agents/check-tunnel.sh --key ~/.ssh/lab_cloudagent
```

`install-box-endpoint.sh` ships the `forwarder-agent` binary (from the
Wnt/forwarder CI artifact) and reads the shared token off the VPS — the token is
never printed and never enters this repo. `check-tunnel.sh` proves the path from
outside: labhost units up, public port open, and a real login that runs `labctl ls`.

## Configuring Jules

Jules → repo → **Environment**. Three fields matter.

**Setup script:**

```bash
bash scripts/cloud-agents/jules-setup.sh
```

**Network access: ON.** Without it the agent has network during setup only, and
`ssh lab` dies the moment real work starts.

**Environment variables:**

| Key | Value | Notes |
|---|---|---|
| `LAB_SSH_KEY` | `base64 -w0 ~/.ssh/lab_cloudagent` | The one real secret. Base64 so a multi-line PEM survives the web form. |
| `LAB_SSH_HOSTKEY` | `awk '{print $1, $2}' /etc/ssh/ssh_host_ed25519_key.pub` from the box | Pins the host key, so the agent never faces a prompt and a MITM fails closed. |
| `LAB_SSH_HOST` | `tunnel.example.com` | Optional; it is the built-in default. |
| `LAB_SSH_PORT` | `10022` | Optional; ditto. |

`jules-setup.sh` writes `~/.ssh/lab_cloudagent`, a pinned `known_hosts`, and a
`Host lab` block, then proves the hop by printing the box's hostname and uptime.
It also installs the quality-gate tooling (shellcheck, shfmt, ruff, `npm ci`),
because a branch that cannot run the gate cannot land
(`docs/lab/AGENT-CI-EXIT-RULE.md`).

Press **Run and snapshot** after saving the variables: the snapshot is what
later sessions boot from. Jules `unset`s the `LAB_SSH_*` variables at the end of
setup before exporting the image, so the snapshot carries the *result* —
`~/.ssh/lab_cloudagent`, `known_hosts`, the `Host lab` block — rather than the
secret. If a session ever starts without `ssh lab` wired up, re-running
`bash scripts/cloud-agents/jules-setup.sh` rebuilds it from the per-session
variables.

## Revoking

Fastest, total, and safe for the LAN:

```bash
ssh lab 'systemctl stop forwarder-agent sshd-cloud-agent'
```

The public port disappears from the VPS the moment the agent disconnects.
To keep the endpoint but drop one identity, remove its line from
`/etc/cloud-agent-ssh/authorized_keys` (or re-run the installer with the new key
set — it *replaces* the file rather than appending, so upstream removal is a
real revocation) and `systemctl reload sshd-cloud-agent`.

Rotate by generating a new keypair, re-running `install-box-endpoint.sh`, and
updating `LAB_SSH_KEY` in the Jules config. The old key stops working at the
moment of the re-run.

## What you are actually trusting

Be clear-eyed: **`LAB_SSH_KEY` is a root key to the lab box, and it is stored in
a third party's environment-variable store.** Jules' own UI says environment
variables are exposed to the agent unless disabled per session. The design
limits the blast radius, it does not eliminate it:

- The key opens exactly one hardened sshd. Passwords and keyboard-interactive
  are off, so the public port cannot be brute-forced; only the private key works.
- That sshd gives **root on labhost**, which is the whole lab. There is no
  meaningful "less privileged" tier here — `labctl`, QMP sockets and systemd all
  need root, and labhost holds no personal data, only guest images and the
  gallery. The lab is a museum, not a home directory.
- The rest of the LAN is not in scope of the tunnel, but *is* in scope of a
  compromised labhost.
- The forwarder VPS sees ciphertext only; it cannot read the SSH session.

If that trade stops being acceptable, the revocation above is one command, and
nothing else in the lab depends on this path.

## Troubleshooting

| Symptom | Look at |
|---|---|
| `ssh lab` times out in the Jules VM | Network access toggle OFF; or `ssh root@tunnel.example.com 'curl -s localhost:7001/status'` shows `"tcp_ports":[]` → the labhost agent is not connected. |
| `Permission denied (publickey)` | `LAB_SSH_KEY` truncated/CRLF-mangled by the form (use base64), or labhost's `authorized_keys` holds a different key: `ssh lab 'ssh-keygen -lf /etc/cloud-agent-ssh/authorized_keys'`. |
| Host key verification failed | `LAB_SSH_HOSTKEY` is stale — labhost's ed25519 host key changed (rebuild). Re-copy it. |
| Tunnel dead after a labhost reboot | Both units are `enable`d; check `journalctl -u forwarder-agent -n 50`. A changed forwarder token needs `install-box-endpoint.sh` re-run. |
| Port shows open but login hangs | `ssh lab 'systemctl status sshd-cloud-agent'` — a bad `sshd_config` edit fails `sshd -t` on install, so this usually means the unit is stopped. |

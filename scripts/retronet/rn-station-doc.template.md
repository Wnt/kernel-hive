<!-- >>> template-only (rn-onboard.sh strips this block when it renders)
rn-station-doc.template.md — rendered by scripts/retronet/rn-onboard.sh into
docs/lab/retronet/STATION-<id>.md. Tokens: @ID@ @IDUPPER@ @TAP@ @CHAIN@
@ADDRESS@ @MAC@ @ADDRESSING@ @UIN@ @PLANES@ @DATE@.

This is a CHECKLIST the wave fills in as it proves things, not a template to
leave as-is: every "TODO" below is a claim nobody has made yet. A station doc
that still has TODOs has not landed.
<<< template-only -->
# @ID@ on the retronet — @PLANES@ (as built)

**Status: BRING-UP, nothing proven yet.** Replace this paragraph with what is
true, in one sentence, the moment the first plane has a frame: which client
renders/signs in, which UIN, where the golden is staged, and whether the
station is live or waiting on a landing window.

Parents: [`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md) (the web plane and the
addressing ledger), [`ICQ-CLIENTS.md`](ICQ-CLIENTS.md) (which IM client this era
can run, and how to drive it), [`GATEWAY.md`](GATEWAY.md) (the server).

## Allocation — written by `wave.sh alloc`, not by hand

| | |
|---|---|
| retronet address | `@ADDRESS@`, **@ADDRESSING@** |
| MAC | fleet scheme `52:54:00:52:4e:<last IP octet>`. Real value box-local in gitignored `registry/local.env` as `RN_@IDUPPER@_MAC`; the committed launcher and `rn-tapnet.sh` carry the scrubbed placeholder `@MAC@` and read the one line at boot. **It lives in the golden's device vmstate, so changing it needs a cold re-bake** |
| tap / bridge | `@TAP@` on `vmbr-rn`, persistent, created + guarded by `streamhost/stations/@ID@/rn-tapnet.sh up` from the launcher on every start |
| guard chain | `@CHAIN@` — ESTABLISHED,RELATED RETURN, everything the guest opens toward labhost DROP, hooked into `INPUT` on both the guest IP and the guest MAC |
| ICQ | UIN `@UIN@`, nickname `@ID@`, password in `registry/local.env` as `RETRONET_ICQ_@IDUPPER@_PASS` |
| joined | @DATE@ |

The address is reserved in `RETRONET_DHCP_RESERVATIONS` **whether or not the
guest speaks DHCP** — that file is the plane's uniqueness ledger, and a static
station missing from it is an address the next agent will hand to somebody else.

## The device set

| | |
|---|---|
| NIC (retronet) | TODO — `-netdev tap,id=rn0,ifname=@TAP@,script=no,downscript=no -device <model>,netdev=rn0,mac="$RN_@IDUPPER@_MAC"`. Say which model and why (NE2000 is 16-bit PIO and costs a VM exit per word under KVM; `rtl8139` is the fleet's proven DMA-capable choice; two IDENTICAL cards make the guest's interface numbering a coin toss a `loadvm` cannot re-litigate) |
| NIC (pointer) | TODO — the pre-existing slirp NIC, if this station has x11warp, with **`restrict=on`**. It carries the hostfwd'd X port and nothing else. `restrict=on` is containment, not tidiness: without it slirp hands the guest a default route via 10.0.2.2 |
| Guest interface | TODO — what the guest names it, measured in the guest, not guessed |
| Guest IP | TODO — the exact file the address is written into |
| DNS | TODO — `/etc/resolv.conf` (or the guest's equivalent) → `10.99.0.2` |
| Default route | **none over the tap** (containment Lock 1). Confirm it in the guest |

**Everything above is one device set, and the golden is one combination with
it.** Adding this NIC invalidates `loadvm` on the old golden, so the golden is
re-baked by a COLD boot on the final launcher — including `restrict=on`, which
is a backend option rather than a device but is still baked with the exact args.

## Web plane

TODO — which browser, which door, and the proof frame.

- Which door: a browser that predates the `Host:` header CANNOT use the `:80`
  origin (it is answered `400`) and must use the `:3128` proxy. Check the
  browser's HTTP version before assuming this station can go seamless.
- Proof frame: `<path>` — the AltaVista-styled `http://search.retronet/`
  rendered in the guest, on the FINAL device set.

## ICQ plane

TODO — which client, from where, and the proof frame.

- Client + route: see [`ICQ-CLIENTS.md`](ICQ-CLIENTS.md); add a row there if this
  station's client is new to the plane.
- Server-side: `rn-tool.py user-set @UIN@ <pass>` + `user-open @UIN@` +
  `nick @UIN@ @ID@` + `ssi-seed @UIN@ 10000=HiveBot` (all done by
  `rn-onboard.sh --apply`).
- Proof frame 1 — **signed in**: `<path>`, the client with **HiveBot** by name in
  the contact list. The gateway journal alone is not the proof (rule 9).
- Proof frame 2 — **signed in AFTER a restore**: `<path>`. This is a SEPARATE
  proof and it is the one that decides whether the exhibit works, because every
  visitor arrives through `loadvm golden`, not a cold boot. **A restored socket
  is stale**: the client resumes holding a TCP connection the gateway forgot
  hours ago, so unless it notices and redials, the visitor is shown a signed-OUT
  client. Prove it the same way every time:

  ```sh
  ssh lab 'labctl reset @ID@'      # loadvm golden
  python3 scripts/dev/fb-wait.py --settle …   # awake, then ~90 s for the redial
  ssh lab 'labctl shot @ID@'
  ```

  Record which of the three this client is (`ICQ-CLIENTS.md` carries the
  fleet-wide column): **heals itself**, **needs a watchdog wrapper**, or **signs
  off and stays off** — the last is a defect, not a footnote, and the station
  does not land on it.

## Containment — measured from inside the guest

| From the guest | Expected | Measured |
|---|---|---|
| `ping 10.99.0.2` (gateway CT) | replies | TODO |
| fetch `http://search.retronet/` | the corpus | TODO |
| connect `10.99.0.2:5190` (OSCAR) | open | TODO |
| connect `10.99.0.1:8443` (the gallery) | **BLOCKED** by `@CHAIN@` | TODO |
| connect `10.99.0.1:22` (labhost sshd) | **BLOCKED** | TODO |
| `ping 1.1.1.1` | no route / unreachable | TODO |
| default routes in the table | **0** | TODO |

Host `ping` toward the guest is NOT a check — containment means labhost-initiated
traffic is exactly the traffic that is allowed.

## The golden

TODO — path, snapshot name, VM_SIZE, VM_CLOCK, sha256, and the restore proof on
a FRESH emulator process under the production launcher args. The pre-retronet
golden is kept as the rollback and named here.

## Landing

1. `rn-verify.sh @ID@` on the box (tap UP on vmbr-rn, unit active, the tap named
   in the launcher/env, the reservation rendered in CT 951, MAC on the fdb).
2. Flip `onboarded` to `true` in `scripts/retronet/icq/roster.json` **only** with
   a signed-in frame, then the coordinator's one fleet-wide
   `seed_contacts.py ssi --apply`.
3. Re-home every claim (tap, chain, rnip, slot/port/vmid) from the wave session
   to the station session.

## Open

TODO — what the next pass must finish, each item with the frame or command that
would close it. An empty list here is a claim; make it a true one.

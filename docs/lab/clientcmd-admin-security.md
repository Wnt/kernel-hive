# Client-command plane: what is open, what is box-side

The HTTPS server's public listener is reached through the edge-VM tunnel, which
terminates on loopback. Python therefore sees **every** public-listener request
as `127.0.0.1`, whoever sent it. `client_address` is logging data on that
listener, never identity — and `_peer_is_loopback()` refuses to answer at all
when `self.public` is set, so the peer check can never be misread there.

## The plane is split by direction

**`POST /clientlog` — telemetry sink. Open to every session.** On the public
listener the visitor's own sign-in authorizes it; on LAN it is simply open. No
token, no operator setup. This is deliberate and it is the point: the visitor
whose stream just failed is the one whose telemetry matters most, so nothing
about recording it may depend on being an operator.

**`GET /clientcmd` — the poll. Any authenticated session.** Every visitor tab
registers and is therefore reachable for debugging, always. Polling confers no
authority: it READS the operator's queue, and a tab executes a command only when
that command is addressed to it (station, and optionally `args.sessionId`). The
poller belongs to the TAB — it starts when the SPA boots and keeps running after
a station closes, so a visitor stuck on a blank grid is reachable too.

**`POST /clientcmd/admin` — the enqueue. Box-side only.** This is the half that
ISSUES commands, including arbitrary-JS `eval`. It is listed in
`gate.BLOCKED_PREFIXES`, so the public listener returns a flat 404; on the LAN
listener it requires a **loopback peer AND** a valid `X-Admin-Token`. There is
no path from any UI session, holding any credential, to command the server.
`clientcmd.sh` posts to `https://127.0.0.1:8443` on the box and is unaffected.

This gives up issuing commands *from* a phone. It does not give up **debugging**
a phone: a phone session is the TARGET — it polls, receives the command, reports
back — so touch and stylus bugs are more reachable than before, because every
session now polls rather than only an admin's own tab.

## eval needs no second switch

`OSG_ADMIN_EVAL` used to be a default-off opt-in guarding a browser-reachable
enqueue. With no such path it protects nothing, while costing a server restart
at exactly the moment a live broken session needs inspecting — and it did not
survive a reboot, so the cost recurred. It is now **on by default and an
explicit DISABLE**: set `OSG_ADMIN_EVAL=0` to shut eval off. A disabled server
refuses the enqueue with 403 *and* filters already-queued eval commands out of
its poll.

## Audit trail

Every accepted command is appended to `CLIENTCMD_AUDIT`
(`clientcmd-audit.jsonl`, beside the telemetry log) **before** it is queued:
`srvTs`, `seq`, `cmd`, `tile`, target `sessionId`, the `eval` code (capped at
2048 chars), `issuedBy`, `peer`, `listener`, and a `broadcast` flag when a
command with no `sessionId` targets `*`. The operator token is never written —
only that a valid one was presented. Read it with `clientcmd.sh audit [n]`.

It is deliberately a separate file from `clientlog.jsonl`: that log is a rolling
window pruned by age, and an audit trail that deletes itself is not one.

## Deployment

Copy changed `scripts/serve/` sync-pair files to `/data/vms/streamhost/serve/`,
verify byte identity, and restart only the HTTPS server. See
`scripts/serve/README.md`. `/restore/<osId>` is unchanged: untokened, LAN-gated
and non-destructive, reached from the StreamView prompt or
`clientcmd.sh restore <osId>`.

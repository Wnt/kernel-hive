# Client-command admin security

The HTTPS server's public listener is also reached through the edge-VM tunnel.
That tunnel can present an Internet visitor to Python as an RFC1918 peer (for
example `192.0.2.2`), so `client_address` is logging data, not identity.

`POST /clientlog`, `GET /clientcmd`, `POST /clientcmd/admin`, and
`POST /restore/<osId>` now fail closed unless `X-Admin-Token` matches the
gitignored token file. The UI, assets, health, signaling, WebRTC offer proxy,
and station WebTransport path remain public. An operator browser tab receives the
token only through an interactive prompt and keeps it in tab-scoped
`sessionStorage`; it is never bundled or placed in a URL.

Arbitrary JavaScript commands have two independent gates: the admin token and
`OSG_ADMIN_EVAL=1`. The environment switch defaults off, disabled enqueue
requests return 403, and polling filters eval commands left by an earlier opt-in
run. `clientcmd.sh eval` and `evallog` also require the explicit environment
switch. Restart with the switch unset to end the debug window.

`/restore/<osId>` remains available through the authenticated StreamView prompt
or `clientcmd.sh restore <osId>`. The reset script and manifest allowlist remain
unchanged.

Deployment must copy changed `scripts/serve/` sync-pair files to
`/data/vms/streamhost/serve/`, verify byte identity, and restart only the HTTPS
server. See `scripts/serve/README.md` for the operator workflow.

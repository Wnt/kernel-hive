#!/usr/bin/env bash
# gen-local-ca.sh
# ---------------------------------------------------------------------------
# Mint an mkcert-style LOCAL CA + a leaf server cert that the user's Chrome
# will accept (once the CA root is trusted, see TRUST below). ONE CA + ONE leaf
# cover:
#   * the HTTPS SPA origin   https://192.0.2.10:8443
# so the browser trusts everything after a single one-time root install.
#
# This is INDEPENDENT of the streamhost WebTransport cert (that one is a
# self-signed P-256 pinned via serverCertificateHashes and needs no CA trust).
#
# Idempotent: regenerates the leaf only if it is missing or expires < 30 days.
# Carry rootCA.key (mode 600) together with rootCA.pem in the gitignored
# scripts/serve/pki/ directory across host rebuilds so already-trusted clients keep
# working. Never deploy the private key to clients; only rootCA.pem (public) is copied
# to the Mac and trusted.
#
# Run ON the host (root@192.0.2.10). Output dir: $PKI (default below).
#
# TRUST (on the Mac, one time):
#   sudo security add-trusted-cert -d -r trustRoot \
#     -k /Library/Keychains/System.keychain rootCA.pem
# Chrome uses the macOS System keychain, so this trusts the SPA certificate.
# ---------------------------------------------------------------------------
set -euo pipefail

PKI="${PKI:-/data/vms/streamhost/serve/pki}"
LAN_IP="${LAN_IP:-${SH_HOST_IP:-192.0.2.10}}"
DAYS_LEAF="${DAYS_LEAF:-365}" # normal one-year lifetime for a user-trusted local leaf
DAYS_CA="${DAYS_CA:-3650}"
ALT_DNS="${ALT_DNS:-osgallery.lab}" # optional friendly hostname (add to /etc/hosts)

mkdir -p "$PKI"
cd "$PKI"
umask 077

msg() { echo "[gen-local-ca] $*"; }

# --- 1. Root CA (create once, reuse forever) --------------------------------
if [ ! -f rootCA.key ] || [ ! -f rootCA.pem ]; then
  msg "creating local root CA"
  openssl ecparam -name prime256v1 -genkey -noout -out rootCA.key
  openssl req -x509 -new -nodes -key rootCA.key -sha256 -days "$DAYS_CA" \
    -subj "/O=KernelHive Local CA/CN=KernelHive Local CA" \
    -out rootCA.pem
else
  msg "reusing existing root CA (rootCA.pem)"
fi

# --- 2. Leaf server cert (regen if missing/expiring) ------------------------
regen=0
if [ ! -f leaf.crt ] || [ ! -f leaf.key ]; then
  regen=1
elif ! openssl x509 -checkend $((30 * 24 * 3600)) -noout -in leaf.crt >/dev/null 2>&1; then
  msg "leaf expires < 30 days -> regenerating"
  regen=1
fi

if [ "$regen" = 1 ]; then
  msg "issuing leaf cert (SAN: IP:$LAN_IP, DNS:localhost, DNS:$ALT_DNS)"
  cat >leaf.ext <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]
IP.1  = $LAN_IP
DNS.1 = localhost
DNS.2 = $ALT_DNS
IP.2  = 127.0.0.1
EOF
  openssl ecparam -name prime256v1 -genkey -noout -out leaf.key
  openssl req -new -key leaf.key \
    -subj "/O=KernelHive/CN=$LAN_IP" -out leaf.csr
  openssl x509 -req -in leaf.csr -CA rootCA.pem -CAkey rootCA.key \
    -CAcreateserial -days "$DAYS_LEAF" -sha256 \
    -extfile leaf.ext -out leaf.crt
  # websockify wants a single cert file that also contains the key-signing chain;
  # build a fullchain (leaf + CA) for servers that present a chain.
  cat leaf.crt rootCA.pem >fullchain.crt
  rm -f leaf.csr
  msg "leaf issued, valid $DAYS_LEAF days"
else
  msg "leaf still valid (>30 days) -> keeping"
fi

msg "PKI ready in $PKI"
msg "  rootCA.pem   -> copy to Mac + trust (see header)"
msg "  leaf.crt/key -> used by HTTPS SPA + wss bridge"
openssl x509 -noout -enddate -subject -ext subjectAltName -in leaf.crt | sed 's/^/[gen-local-ca]   /'

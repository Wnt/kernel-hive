// ============================================================================
//  session_ticket — optional HMAC gate on the WebTransport session path.
//  ---------------------------------------------------------------------------
//  streamhost's QUIC listener answers whoever reaches its UDP port. On the LAN
//  that IS the security model, and this module stays inert (SH_SESSION_KEY
//  unset => today's behaviour, every session accepted). The moment a station's port
//  is published to the internet it stops being enough: a WebTransport session
//  carries the guest's INPUT plane as well as its video, so an unauthenticated
//  session is a stranger typing into the exhibit — the UI's login would be
//  decorative if the media port were open.
//
//  So the authenticated gateway mints a short-lived ticket per connect and hands
//  it to the browser in the signaling doc's existing `path` field, and this
//  verifies it before `req.accept()`. One shared HMAC secret keeps streamhost
//  free of any user/session model: it never learns who the visitor is, only that
//  the gateway vouched for them moments ago.
//
//  Wire form:  path  = /wt/<exp>.<nonce>.<sig>
//              signed = v1|<tile>|<exp>|<nonce>
//              sig    = base64url-nopad HMAC-SHA256(key, signed)
//
//  The station is signed in, so a ticket minted for one exhibit cannot be replayed
//  against another. Replay WITHIN the ticket's lifetime by whoever already holds
//  it is deliberately not addressed: it travels inside the visitor's own TLS
//  session, and the short expiry is the bound.
// ============================================================================

use base64::Engine;
use sha2::{Digest, Sha256};

/// Refuse a ticket whose expiry is further out than this, however well signed.
/// The gateway picks the real TTL (minutes); this only bounds the blast radius
/// of a gateway bug or a stolen ticket to something survivable.
const MAX_TTL_SECS: u64 = 3600;

const BLOCK: usize = 64;

fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let mut k = [0u8; BLOCK];
    if key.len() > BLOCK {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; BLOCK];
    let mut opad = [0x5cu8; BLOCK];
    for i in 0..BLOCK {
        ipad[i] ^= k[i];
        opad[i] ^= k[i];
    }
    let mut inner = Sha256::new();
    inner.update(ipad);
    inner.update(msg);
    let inner = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner);
    let mut out = [0u8; 32];
    out.copy_from_slice(&outer.finalize());
    out
}

/// Constant-time string compare. Length is allowed to leak (both sides are
/// fixed-width base64 in practice); the CONTENT is not, so a wrong signature
/// cannot be walked byte by byte with a timer.
fn ct_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn sign(key: &[u8], tile: &str, exp: u64, nonce: &str) -> String {
    let msg = format!("v1|{tile}|{exp}|{nonce}");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(hmac_sha256(key, msg.as_bytes()))
}

/// The gate as the transport sees it: `Ok(())` to accept this session.
///
/// Inert when the station has no session key — that is every LAN station, and it is
/// the behaviour streamhost has always had. `Err` carries a short reason for the
/// log and NEVER the ticket, which is a bearer token.
pub fn admit(cfg: &crate::config::Config, path: &str) -> Result<(), &'static str> {
    let Some(key) = cfg.session_key.as_deref() else {
        return Ok(());
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    verify(path, &cfg.tile, key, now)
}

/// Verify the `:path` of an incoming WebTransport session. `Err` carries a
/// short reason for the log — never the ticket itself, which is a bearer token.
pub fn verify(path: &str, tile: &str, key: &[u8], now_unix: u64) -> Result<(), &'static str> {
    // A query string is not part of the ticket (nothing mints one today, but a
    // cache-buster appended by some middlebox must not invalidate the session).
    let path = path.split('?').next().unwrap_or(path);
    let ticket = path.strip_prefix("/wt/").ok_or("no ticket in path")?;

    let mut parts = ticket.split('.');
    let (exp, nonce, sig) = match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(e), Some(n), Some(s), None) => (e, n, s),
        _ => return Err("malformed ticket"),
    };

    let exp: u64 = exp.parse().map_err(|_| "malformed expiry")?;
    if now_unix > exp {
        return Err("expired");
    }
    if exp > now_unix.saturating_add(MAX_TTL_SECS) {
        return Err("expiry too far out");
    }

    if nonce.is_empty()
        || nonce.len() > 64
        || !nonce
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err("malformed nonce");
    }

    if ct_eq(&sign(key, tile, exp, nonce), sig) {
        Ok(())
    } else {
        Err("bad signature")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &[u8] = b"a-shared-secret-between-gateway-and-streamhost";

    fn mint(tile: &str, exp: u64, nonce: &str) -> String {
        format!("/wt/{exp}.{nonce}.{}", sign(KEY, tile, exp, nonce))
    }

    // RFC 4231 test case 2, so the hand-rolled HMAC is checked against the
    // standard's own vector rather than against itself.
    #[test]
    fn hmac_matches_rfc4231() {
        let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        assert_eq!(
            hex(&mac),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    // A key longer than the 64-byte block takes the hashed-key branch: RFC 4231
    // case 4 exercises it (131-byte key).
    #[test]
    fn hmac_matches_rfc4231_long_key() {
        let mac = hmac_sha256(
            &[0xaa; 131],
            b"Test Using Larger Than Block-Size Key - Hash Key First",
        );
        assert_eq!(
            hex(&mac),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        );
    }

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn accepts_a_fresh_ticket() {
        assert!(verify(
            &mint("win95", 1_800_000_100, "abc123"),
            "win95",
            KEY,
            1_800_000_000
        )
        .is_ok());
    }

    #[test]
    fn accepts_a_ticket_with_a_query_string() {
        let p = format!("{}?cb=1", mint("win95", 1_800_000_100, "abc123"));
        assert!(verify(&p, "win95", KEY, 1_800_000_000).is_ok());
    }

    #[test]
    fn rejects_the_bare_legacy_path() {
        assert_eq!(
            verify("/wt", "win95", KEY, 1_800_000_000),
            Err("no ticket in path")
        );
    }

    #[test]
    fn rejects_an_expired_ticket() {
        assert_eq!(
            verify(
                &mint("win95", 1_800_000_000, "abc"),
                "win95",
                KEY,
                1_800_000_001
            ),
            Err("expired")
        );
    }

    #[test]
    fn rejects_an_absurd_expiry() {
        assert_eq!(
            verify(
                &mint("win95", 9_999_999_999, "abc"),
                "win95",
                KEY,
                1_800_000_000
            ),
            Err("expiry too far out")
        );
    }

    // The whole point of signing the station in: a viewer's ticket for one exhibit
    // must not open a session on the station next to it.
    #[test]
    fn rejects_a_ticket_minted_for_another_tile() {
        assert_eq!(
            verify(
                &mint("win95", 1_800_000_100, "abc"),
                "solariscde",
                KEY,
                1_800_000_000
            ),
            Err("bad signature")
        );
    }

    #[test]
    fn rejects_a_forged_signature() {
        assert_eq!(
            verify(
                "/wt/1800000100.abc.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "win95",
                KEY,
                1_800_000_000
            ),
            Err("bad signature")
        );
    }

    #[test]
    fn rejects_a_wrong_key() {
        assert_eq!(
            verify(
                &mint("win95", 1_800_000_100, "abc"),
                "win95",
                b"not-the-key",
                1_800_000_000
            ),
            Err("bad signature")
        );
    }

    #[test]
    fn rejects_structural_junk() {
        for p in [
            "/wt/",
            "/wt/a.b",
            "/wt/a.b.c.d",
            "/other/1.a.b",
            "/wt/x.abc.sig",
        ] {
            assert!(
                verify(p, "win95", KEY, 1_800_000_000).is_err(),
                "accepted {p}"
            );
        }
    }

    #[test]
    fn rejects_a_nonce_outside_the_charset() {
        // Signed correctly, but the nonce carries a character the minter would
        // never emit — reject on shape before spending an HMAC on it.
        let exp = 1_800_000_100;
        let nonce = "ab/cd";
        let p = format!("/wt/{exp}.{nonce}.{}", sign(KEY, "win95", exp, nonce));
        assert_eq!(
            verify(&p, "win95", KEY, 1_800_000_000),
            Err("malformed nonce")
        );
    }
}

//! Sampled per-input trace context — the wire suffix, and the key-class
//! vocabulary it lets a span name without naming a key.
//!
//! THE DECISION IS THE BROWSER'S (`docs/lab/TRACE-CONTEXT.md` §5,
//! `scripts/serve/tracing.py`'s "SAMPLING IS THE BROWSER'S DECISION"). This
//! daemon never samples independently: it only recognises a context the
//! browser already minted and attached, and it never fabricates one when the
//! suffix is absent. The input plane has no headers (it is raw WebTransport
//! records, not HTTP — contract §3), so the only place left to carry a
//! `traceparent`-equivalent is inside the record itself, on the ~1-in-N
//! records the browser chose to sample.
//!
//! WIRE FORMAT. Appended AFTER a record's normal fixed fields, present only on
//! a sampled edge:
//!
//! ```text
//!   [ ...normal record bytes... ][ 0xC5 | trace-id (16 BE) | span-id (8 BE) ]
//!                                  ^^^^ SUFFIX_MARKER          25 bytes total
//! ```
//!
//! `input.rs`'s match arms all guard on `rec.len() >= N`, not `== N` — a
//! record with unrecognised trailing bytes is already handled as "ignore
//! them", which is exactly backward compatibility for free:
//!   * an OLD browser -> a NEW daemon sends records at their historic exact
//!     length; `strip` finds no suffix (the length doesn't match ANY known
//!     `base + SUFFIX_LEN`) and returns the record untouched with `None` —
//!     byte-identical to today.
//!   * a NEW browser -> an OLD daemon sends the longer record; the old
//!     `input::handle` never heard of this module, reads its fixed fields off
//!     the FRONT exactly as before and ignores the tail — the click or
//!     keystroke still lands, just untraced.
//!
//! Both directions are exercised in `input_trace_tests.rs`.
//!
//! WHY A MARKER BYTE AND NOT JUST A LENGTH CHECK. Two record shapes exist for
//! type 2 (the bare 3-byte button edge and the carried-position 11-byte one —
//! `input.rs`'s `sendButtonImpl` comment explains why), so `base + SUFFIX_LEN`
//! is not always unique against stray padding. The marker turns "the length
//! matches" into "the length matches AND the byte where a suffix would start
//! is the one only this code writes there" — a coincidence has to clear both.
//! A record that clears the length check but not the marker is treated as NO
//! suffix (never a hard error — contract §1's "malformed starts a new trace,
//! never refuses the work", applied to the one wire format this contract does
//! not already cover).
//!
//! COST WHEN NOT SAMPLED (9 records in 10 at the default N=10): `strip` is a
//! match on `rec[0]`, one or two length comparisons and (only when the length
//! already matches) one byte compare. No allocation, no formatting — the same
//! budget `probes.rs` and `trace_session.rs`'s `once()` hold themselves to.
//! `input_trace_suffix_strip_cost` in the test module measures it.

use crate::trace::Ctx;

/// Leads the 24-byte context payload when present. Arbitrary; chosen only to
/// be unlikely to collide with a coincidental trailing byte pattern.
pub const SUFFIX_MARKER: u8 = 0xC5;
/// `trace-id (16) + span-id (8)`, matching the 32-hex/16-hex halves of a
/// `traceparent` — no flags byte: presence of the suffix at all already means
/// "sampled", so encoding a redundant `01` would only be one more thing that
/// could disagree with itself.
const CTX_LEN: usize = 16 + 8;
/// The whole appended tail: marker + context.
pub const SUFFIX_LEN: usize = 1 + CTX_LEN;

/// Base (pre-suffix) lengths this daemon ever sends/receives for a wire
/// record TYPE, matching `input.rs`'s header table exactly. Only key (3) and
/// button (2) records ever carry a suffix — pointer motion (types 1/4) is
/// unreliable-datagram, out of scope by design (~250 samples/sec would blow
/// the whole point of sampling), and wheel/touch are not wired for it either.
fn base_lens(rec_type: u8) -> &'static [usize] {
    match rec_type {
        3 => &[4],     // key: u8 type, u8 down, u16 qemu_keycode
        2 => &[3, 11], // button: bare edge, or edge + carried position + cseq
        _ => &[],
    }
}

/// Split a possible trace suffix off the tail of `rec`. Returns the record
/// with the suffix removed (identical to `rec` when none was found) and the
/// context it carried, if any and if it parsed to a non-zero trace/span id
/// (an all-zero id is the same "invalid" spelling `trace/context.rs` already
/// rejects for the header form).
pub fn strip(rec: &[u8]) -> (&[u8], Option<Ctx>) {
    let Some(&rec_type) = rec.first() else {
        return (rec, None);
    };
    for &base in base_lens(rec_type) {
        if rec.len() != base + SUFFIX_LEN {
            continue;
        }
        if rec[base] != SUFFIX_MARKER {
            continue;
        }
        let trace_bytes: [u8; 16] = rec[base + 1..base + 17].try_into().unwrap();
        let span_bytes: [u8; 8] = rec[base + 17..base + 25].try_into().unwrap();
        let trace = u128::from_be_bytes(trace_bytes);
        let span = u64::from_be_bytes(span_bytes);
        if trace == 0 || span == 0 {
            return (&rec[..base], None);
        }
        return (
            &rec[..base],
            Some(Ctx {
                trace,
                span,
                sampled: true,
            }),
        );
    }
    (rec, None)
}

/// Encode a suffix for `ctx` — the daemon never sends one today (only the
/// browser mints sampled contexts), but the test module round-trips through
/// this to prove `strip` is its exact inverse rather than merely "looks
/// right".
#[cfg(test)]
pub fn encode(ctx: Ctx) -> [u8; SUFFIX_LEN] {
    let mut out = [0u8; SUFFIX_LEN];
    out[0] = SUFFIX_MARKER;
    out[1..17].copy_from_slice(&ctx.trace.to_be_bytes());
    out[17..25].copy_from_slice(&ctx.span.to_be_bytes());
    out
}

/// `kh.input.class` — the coarse WIRE class, never the payload.
pub fn input_class(rec_type: u8) -> &'static str {
    match rec_type {
        2 => "click",
        3 => "key",
        _ => "other",
    }
}

/// `kh.key.class` — a small, deliberately coarse vocabulary computed from the
/// XT set-1 wire scancode (`input.rs`'s type=3 payload — the SAME code
/// `key()` already injects into the guest, already necessary for the feature
/// to work at all). This is a BUCKET, not the key: two different keys sharing
/// a bucket produce the identical string, and nothing here can be inverted
/// back to which key was pressed. Extended keys ride as `0xE0xx` on the wire
/// (`key_quirks.rs`'s `key_qnum` doc comment); the bucket checks the base
/// byte, which is why the bare-keypad and enhanced-extended forms of the same
/// physical key land in the same class.
pub fn key_class(qemu_keycode: u16) -> &'static str {
    let base = (qemu_keycode & 0x00FF) as u8;
    let extended = (qemu_keycode >> 8) == 0xE0;
    if base == 0x1C {
        return "enter"; // main Return, and extended 0xE01C numpad Enter
    }
    let modifier = if extended {
        matches!(base, 0x1D | 0x38 | 0x5B | 0x5C | 0x5D) // RCtrl/RAlt/LWin/RWin/Menu
    } else {
        matches!(base, 0x1D | 0x2A | 0x36 | 0x38 | 0x3A | 0x45 | 0x46)
    };
    if modifier {
        return "modifier";
    }
    // Tab plus the bare-keypad/enhanced navigation cluster — both encodings
    // share these base bytes (see the module doc), so extended is irrelevant.
    if matches!(
        base,
        0x0F | 0x47 | 0x48 | 0x49 | 0x4B | 0x4D | 0x4F | 0x50 | 0x51 | 0x52 | 0x53
    ) {
        return "navigation";
    }
    if !extended && (0x3B..=0x44).contains(&base) || base == 0x57 || base == 0x58 {
        return "function";
    }
    "printable"
}

#[cfg(test)]
#[path = "input_trace_tests.rs"]
mod tests;

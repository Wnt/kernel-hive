// ============================================================================
//  config/parse — value parsers for the SH_* environment knobs.
//  ---------------------------------------------------------------------------
//  Split out of config/mod.rs, which is the Config struct plus one long
//  from_args(): these are small, pure string->value functions with their own
//  documented fall-back behaviour, and they are the part of the module worth
//  reading on its own. Behaviour is unchanged — the bodies are lifted verbatim.
//
//  env_flag() deliberately stays in the parent: it is the module's one PUBLIC
//  helper (capture.rs uses it through the lib surface).
// ============================================================================

/// SH_INPUT_TELEMETRY: unset/0/off/false => 0; 1/on/true => 1; 2+ => 2 (clamped); garbage => 0.
pub(super) fn parse_telemetry_level(s: &str) -> u8 {
    match s.trim().to_ascii_lowercase().as_str() {
        "" | "0" | "off" | "false" => 0,
        "1" | "on" | "true" => 1,
        other => other.parse::<u8>().map(|n| n.min(2)).unwrap_or(0),
    }
}

/// SH_ENC_NICE / --enc-nice value: "off" or empty = None (inherit); otherwise
/// an integer nice clamped -20..=19 (unparsable = 0, matching env_or style).
pub(super) fn parse_enc_nice(s: &str) -> Option<i32> {
    let s = s.trim();
    if s.is_empty() || s.eq_ignore_ascii_case("off") {
        None
    } else {
        Some(s.parse::<i32>().unwrap_or(0).clamp(-20, 19))
    }
}

pub(super) fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

/// SH_CC value -> BBR? Only an explicit "cubic" selects quinn's loss-based
/// default; anything else — including the default "bbr" and garbage — selects
/// BBR, matching the env_or fall-back-to-default style.
pub(super) fn parse_cc(s: &str) -> bool {
    !s.trim().eq_ignore_ascii_case("cubic")
}

/// The descriptive per-station name is the public contract. Keep SH_PRESET as a
/// compatibility fallback for hand-managed test fixtures created before the
/// registry grew an explicit encoder-preset field.
pub(super) fn encoder_preset_env() -> String {
    std::env::var("SH_ENCODER_PRESET")
        .or_else(|_| std::env::var("SH_PRESET"))
        .unwrap_or_else(|_| "ultrafast".to_string())
}

pub(super) fn normalize_encoder_preset(preset: &str) -> String {
    match preset.to_ascii_lowercase().as_str() {
        p @ ("ultrafast" | "superfast" | "veryfast" | "faster" | "fast" | "medium" | "slow"
        | "slower" | "veryslow") => p,
        // Fall back to the same value an unset SH_ENCODER_PRESET gives, so a
        // typo cannot quietly put one station on a different preset from the fleet.
        _ => "ultrafast",
    }
    .to_string()
}

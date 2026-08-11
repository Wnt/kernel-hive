// Self-signed ECDSA P-256 certificate + signaling publication.
//
// Chrome refuses a serverCertificateHashes cert whose validity exceeds ~14 days,
// so we mint a fresh cert (validity now-1h .. now+13d) on every server (re)start
// and, per the rotation timer in transport.rs, every ~10 days. There is NO
// hardcoded pin: the client always fetches the live hash from signaling.json at
// connect time.
//
// On each (re)generation we atomically publish two artifacts:
//   * hash_file       — bare base64 SHA-256 of the cert DER (prototype back-compat)
//   * signaling_json  — the full per-station contract the SERVE agent serves same-origin

use anyhow::Result;
use base64::Engine;
use sha2::{Digest, Sha256};
use wtransport::tls::{Certificate, CertificateChain, PrivateKey};
use wtransport::Identity;

use crate::config::Config;

pub struct CertBundle {
    pub identity: Identity,
    pub hash_b64: String,
    pub hash_hex: String,
    pub not_after_rfc3339: String,
}

pub fn generate(cfg: &Config) -> Result<CertBundle> {
    let key_pair = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)?;

    let ip = cfg.host_ip;
    let mut params = rcgen::CertificateParams::new(vec![ip.to_string(), "localhost".to_string()])?;
    let mut sans = vec![rcgen::SanType::DnsName("localhost".try_into()?)];
    sans.push(rcgen::SanType::IpAddress(ip));
    // If the advertised host is a DNS name (not the bare IP), pin it too.
    if cfg.advertise_host != ip.to_string() {
        if let Ok(dns) = cfg.advertise_host.as_str().try_into() {
            sans.push(rcgen::SanType::DnsName(dns));
        }
    }
    params.subject_alt_names = sans;

    let now = time::OffsetDateTime::now_utc();
    params.not_before = now - time::Duration::hours(1);
    let not_after = now + time::Duration::days(13);
    params.not_after = not_after;

    let cert = params.self_signed(&key_pair)?;
    let cert_der = cert.der().to_vec();
    let key_der = key_pair.serialize_der();

    let hash = Sha256::digest(&cert_der);
    let hash_b64 = base64::engine::general_purpose::STANDARD.encode(hash);
    let hash_hex = hash
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<String>();

    let identity = Identity::new(
        CertificateChain::single(Certificate::from_der(cert_der)?),
        PrivateKey::from_der_pkcs8(key_der),
    );

    let not_after_rfc3339 = not_after
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default();

    Ok(CertBundle {
        identity,
        hash_b64,
        hash_hex,
        not_after_rfc3339,
    })
}

fn write_atomic(path: &str, contents: &str) -> Result<()> {
    if let Some(dir) = std::path::Path::new(path).parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = format!("{path}.tmp.{}", std::process::id());
    std::fs::write(&tmp, contents)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Write the bare-hash file and the signaling.json contract atomically.
pub fn publish(cfg: &Config, b: &CertBundle) -> Result<()> {
    write_atomic(&cfg.hash_file, &b.hash_b64)?;

    let now = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default();

    // Connect-time video defaults (SECTION 3.3). The AUTHORITATIVE codec string is
    // pushed at runtime over KIND_PARAMS subtype 1 (from the emitted SPS); this is
    // the fallback an old/early UI uses before the first params push. `wireVersion`
    // 3 signals the High-profile-capable protocol; an old UI falls back to baseline.
    let (codec, profile_name) = match cfg.profile.as_str() {
        "baseline" => ("avc1.42e01e", "baseline"),
        "main" => ("avc1.4d0028", "main"),
        _ => ("avc1.640028", "high"),
    };
    // Ladder maxrate: tier-0 base (config cap, else the 12 Mbps ~1 MP default —
    // the daemon auto-picks the real per-resolution cap at runtime), then the
    // SECTION 2.1 scale factors 1.0 / 0.60 / 0.35.
    let base_kbps: u32 = if cfg.maxrate_kbps > 0 {
        cfg.maxrate_kbps
    } else {
        12000
    };
    let crf0 = cfg.crf;
    let crf1 = (crf0 + 3).min(51);
    let crf2 = (crf0 + 6).min(51);
    let med_kbps = ((base_kbps as f64) * 0.60).round() as u32;
    let low_kbps = ((base_kbps as f64) * 0.35).round() as u32;
    let video = serde_json::json!({
        "codec": codec,
        "profile": profile_name,
        "preset": cfg.preset,
        "tune": cfg.tune,
        "width": 1280, "height": 800,
        "fpsCap": cfg.fps,
        "keyframeMs": cfg.keyframe_ms,
        "gop": 300,
        "crf": crf0,
        "abr": cfg.abr,
        "defaultTier": 0,
        "ladder": [
            {"tier":0,"name":"high","crf":crf0,"maxKbps":base_kbps},
            {"tier":1,"name":"med","crf":crf1,"maxKbps":med_kbps},
            {"tier":2,"name":"low","crf":crf2,"maxKbps":low_kbps},
            {"tier":3,"name":"floor","crf":crf2,"maxKbps":low_kbps,"minHeight":cfg.abr_floor_height},
        ],
    });

    let doc = serde_json::json!({
        "tile": cfg.tile,
        "host": cfg.advertise_host,
        "udpPort": cfg.udp_port,
        "certHashB64": b.hash_b64,
        "certHashHex": b.hash_hex,
        "transport": "webtransport-h264-opus",
        "quic": {
            "maxUdpPayloadSize": crate::transport::QUIC_MAX_UDP_PAYLOAD,
            "mtuDiscovery": false,
        },
        "wireVersion": 3,
        "pointer": cfg.input_backend.pointer_mode(),
        "inputBackend": cfg.input_backend.as_str(),
        "audio": cfg.audio,
        "video": video,
        "updatedAt": now,
        "notAfter": b.not_after_rfc3339,
    });
    write_atomic(&cfg.signaling_json, &serde_json::to_string_pretty(&doc)?)?;

    eprintln!(
        "CERT_SHA256_B64={} (tile={} udp/{} -> {})",
        b.hash_b64, cfg.tile, cfg.udp_port, cfg.signaling_json
    );
    Ok(())
}

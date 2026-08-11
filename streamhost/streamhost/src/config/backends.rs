//! Capture (frame source) and input backend enums + their string parsers.
//!
//! Split out of `config` so the god-struct module stays under the file-size cap;
//! `config` re-exports both enums, so `crate::config::{CaptureBackend,
//! InputBackend}` remain the public paths.

/// Frame source for the capture stage. `Qemu` is the historical QEMU
/// dbus-display path (shm scanout + v1 copy fallback) that every production station
/// uses. `X11` grabs an X server's root window (Xvfb in an LXC emulator-bridge
/// container, e.g. the IRIX/MAME station whose emulator panics under a KVM vCPU and
/// must run on the bare-metal CPU) and fills `FrameState.fb`. `Shm` reads the
/// same emulator's frames out of a file-backed shared mapping it publishes
/// itself, so the emulator needs no window (and no X server) at all — the whole
/// SDL-texture/llvmpipe/X round trip the `X11` backend pays for disappears, and
/// the pixels are the exact emulated framebuffer rather than a window-scaled
/// resample. Selected by `SH_CAPTURE`; default `qemu` so nothing about the
/// existing fleet changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptureBackend {
    Qemu,
    X11,
    Shm,
}

impl CaptureBackend {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Qemu => "qemu",
            Self::X11 => "x11",
            Self::Shm => "shm",
        }
    }

    /// True for frame sources that are not a QEMU dbus-display, i.e. those whose
    /// `Capture.main_conn` is `None` (no dbus audio, no QMP idle-pause).
    pub fn is_qemu(self) -> bool {
        matches!(self, Self::Qemu)
    }
}

pub(super) fn parse_capture_backend(s: &str) -> CaptureBackend {
    match s.trim().to_ascii_lowercase().as_str() {
        "x11" | "xvfb" => CaptureBackend::X11,
        "shm" => CaptureBackend::Shm,
        _ => CaptureBackend::Qemu,
    }
}

/// PCM source for the audio stage (SH_AUDIO_SOURCE; only consulted when
/// `SH_AUDIO=on`). `Dbus` is the historical QEMU path: an AudioOutListener
/// registered on the capture stage's p2p connection — which only the `Qemu`
/// capture backend has. `Fifo` reads raw s16le stereo 48 kHz PCM out of a named
/// pipe that the emulator's SDL "disk" audio driver writes
/// (`-sound sdl -audiodriver disk` + SDL_DISKAUDIOFILE), so shm/x11-capture
/// stations with no QEMU connection at all (the IRIX/MAME station) get audio through
/// the exact same Opus encode path. Default `dbus` so nothing about the
/// existing fleet changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioSource {
    Dbus,
    Fifo,
}

impl AudioSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Dbus => "dbus",
            Self::Fifo => "fifo",
        }
    }
}

pub(super) fn parse_audio_source(s: &str) -> AudioSource {
    match s.trim().to_ascii_lowercase().as_str() {
        "fifo" => AudioSource::Fifo,
        // Forgiving fall-back-to-default, matching parse_capture_backend.
        _ => AudioSource::Dbus,
    }
}

/// SH_AUDIO_SILENCE_THRESH: max|sample| (i16 full scale) a 20 ms frame may
/// reach and still count as silent for the fifo source's gate. Default 4 —
/// MAME's mixer emits exact zeros or ±1..2 of dither when idle, and 4 is
/// inaudible (−78 dBFS). Capped at 32767 (|i16::MIN| = 32768 is representable
/// as a peak but a threshold of "everything is silent" is never useful).
pub(super) fn parse_silence_thresh(s: &str) -> u16 {
    s.trim().parse::<u16>().map(|v| v.min(32767)).unwrap_or(4)
}

/// Parse `SH_KEY_REMAP`: a comma-separated list of `from:to` XT set1 wire codes,
/// each hex (`0x0e`, `0xe04b`) or decimal. Whitespace is ignored, an empty value
/// yields no remaps, and a malformed or out-of-range (> 0xffff) pair is skipped
/// rather than taking the station down — a typo must not cost the whole keyboard.
pub(super) fn parse_key_remap(s: &str) -> Vec<(u32, u32)> {
    fn code(t: &str) -> Option<u32> {
        let t = t.trim();
        let v = match t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
            Some(hex) => u32::from_str_radix(hex, 16).ok()?,
            None => t.parse::<u32>().ok()?,
        };
        (v <= 0xffff).then_some(v)
    }
    s.split(',')
        .filter(|p| !p.trim().is_empty())
        .filter_map(|pair| {
            let (from, to) = pair.split_once(':')?;
            Some((code(from)?, code(to)?))
        })
        .collect()
}

/// Pointer semantics and transport, expressed as one unambiguous backend.
///
/// `GalleryHid` is deliberately limited to the Solaris/QNX driver work. It is
/// never inferred from a socket or PCI device being present, and is not the
/// general successor for the six frozen warpd guest agents.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputBackend {
    /// Keyboard-only exhibit: retain key injection but discard every pointer,
    /// button, wheel, and touch record before it reaches the guest.
    Disabled,
    DbusAbs,
    DbusRel,
    Warpd,
    GalleryHid,
    /// XTEST fake-input into an X server (pairs with `CaptureBackend::X11`).
    /// Absolute pointer is 1:1 (xtest_fake_input MotionNotify at root x,y);
    /// buttons/wheel/keys ride the same XTEST channel. Never inferred — only
    /// set explicitly via `SH_INPUT_BACKEND=x11test` on an X11-capture station.
    X11Test,
    /// Window-free pointer/button route for a MAME station running `-video none`
    /// (pairs with `CaptureBackend::Shm`). There is no X window to XTEST into,
    /// so absolute targets are converted to relative deltas and appended to the
    /// in-emulator Lua agent's command file as `MOVE dx dy`, which drives the
    /// emulated PS/2 mouse axes directly. Never inferred — only set explicitly
    /// via `SH_INPUT_BACKEND=mamecmd`.
    MameCmd,
    /// Native mamectl/1 route for the same MAME station (issue #45): the identical
    /// closed-loop MOVEA/edge/KEY wire contract as `MameCmd`, but spoken to the
    /// in-emulator ctlsock OSD module's unix control socket (`SH_MAMECTL_SOCK`)
    /// with per-verb acks instead of an append-only file tailed by a Lua agent.
    /// Never inferred — only set explicitly via `SH_INPUT_BACKEND=mamesock`.
    /// Single-injector rule: the station must then NOT launch MAME with
    /// `-autoboot_script irixagent.lua`.
    MameSock,
}

impl InputBackend {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::DbusAbs => "dbus-abs",
            Self::DbusRel => "dbus-rel",
            Self::Warpd => "warpd",
            Self::GalleryHid => "gallery-hid",
            Self::X11Test => "x11test",
            Self::MameCmd => "mamecmd",
            Self::MameSock => "mamesock",
        }
    }

    pub fn is_dbus(self) -> bool {
        matches!(self, Self::DbusAbs | Self::DbusRel)
    }

    /// Compatibility value for the existing signaling.json `pointer` field.
    /// Transport selection itself is reported by `as_str()`.
    pub fn pointer_mode(self) -> &'static str {
        match self {
            Self::Disabled => "none",
            Self::DbusRel => "rel",
            Self::Warpd => "warpd",
            Self::DbusAbs | Self::GalleryHid | Self::X11Test | Self::MameCmd | Self::MameSock => {
                "abs"
            }
        }
    }
}

/// Resolve the preferred unified backend or the legacy two-knob configuration.
///
/// Old fleet values remain valid:
///   SH_POINTER=abs|rel + SH_INPUT_BACKEND=dbus (or no backend override)
///   SH_POINTER=warpd  + SH_INPUT_BACKEND=warpd (or no backend override)
///   SH_POINTER=warpd  + SH_INPUT_BACKEND=gallery-hid
pub(super) fn parse_input_backend(legacy_pointer: &str, backend: Option<&str>) -> InputBackend {
    let legacy_pointer = if legacy_pointer.eq_ignore_ascii_case("rel") {
        InputBackend::DbusRel
    } else if legacy_pointer.eq_ignore_ascii_case("warpd") {
        InputBackend::Warpd
    } else {
        // Preserve the historical SH_POINTER behavior: unknown values fell back
        // to the safe/default absolute D-Bus path.
        InputBackend::DbusAbs
    };

    match backend {
        Some(v) if v.eq_ignore_ascii_case("disabled") => InputBackend::Disabled,
        Some(v) if v.eq_ignore_ascii_case("dbus-abs") => InputBackend::DbusAbs,
        Some(v) if v.eq_ignore_ascii_case("dbus-rel") => InputBackend::DbusRel,
        Some(v) if v.eq_ignore_ascii_case("warpd") => InputBackend::Warpd,
        Some(v) if v.eq_ignore_ascii_case("gallery-hid") => InputBackend::GalleryHid,
        Some(v) if v.eq_ignore_ascii_case("x11test") => InputBackend::X11Test,
        Some(v) if v.eq_ignore_ascii_case("mamecmd") => InputBackend::MameCmd,
        Some(v) if v.eq_ignore_ascii_case("mamesock") => InputBackend::MameSock,
        Some(v) if v.eq_ignore_ascii_case("dbus") && legacy_pointer.is_dbus() => legacy_pointer,
        Some(v) if v.eq_ignore_ascii_case("dbus") => panic!(
            "invalid legacy input combination SH_POINTER=warpd + SH_INPUT_BACKEND=dbus; use SH_INPUT_BACKEND=dbus-abs|dbus-rel|warpd|gallery-hid"
        ),
        Some(v) => panic!(
            "invalid SH_INPUT_BACKEND={v:?}; expected disabled|dbus-abs|dbus-rel|warpd|gallery-hid|x11test|mamecmd|mamesock (legacy dbus also accepted with SH_POINTER=abs|rel)"
        ),
        None => legacy_pointer,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        parse_audio_source, parse_input_backend, parse_key_remap, parse_silence_thresh,
        AudioSource, InputBackend,
    };

    #[test]
    fn key_remap_parses_pairs_and_survives_typos() {
        assert_eq!(parse_key_remap(""), vec![]);
        assert_eq!(parse_key_remap("0x0e:0xe04b"), vec![(0x0e, 0xe04b)]);
        assert_eq!(parse_key_remap(" 14 : 57419 "), vec![(0x0e, 0xe04b)]); // decimal
        assert_eq!(
            parse_key_remap("0x0e:0xe04b, 0x53:0x0e"),
            vec![(0x0e, 0xe04b), (0x53, 0x0e)]
        );
        // A malformed or out-of-range entry is skipped, never fatal.
        assert_eq!(parse_key_remap("nope,0x0e:0xe04b,,7"), vec![(0x0e, 0xe04b)]);
        assert_eq!(parse_key_remap("0x10000:0x01"), vec![]);
    }

    #[test]
    fn audio_source_parses_forgivingly() {
        assert_eq!(parse_audio_source("fifo"), AudioSource::Fifo);
        assert_eq!(parse_audio_source(" FIFO "), AudioSource::Fifo);
        assert_eq!(parse_audio_source("dbus"), AudioSource::Dbus);
        assert_eq!(parse_audio_source(""), AudioSource::Dbus); // unset -> default
        assert_eq!(parse_audio_source("garbage"), AudioSource::Dbus);
    }

    #[test]
    fn silence_thresh_defaults_and_clamps() {
        assert_eq!(parse_silence_thresh("4"), 4);
        assert_eq!(parse_silence_thresh("0"), 0); // 0 = only exact digital silence mutes
        assert_eq!(parse_silence_thresh("40000"), 32767); // over full scale clamps
        assert_eq!(parse_silence_thresh("-1"), 4); // garbage -> default
        assert_eq!(parse_silence_thresh(""), 4);
    }

    #[test]
    fn unified_input_backend_values_are_unambiguous() {
        assert_eq!(
            parse_input_backend("abs", Some("disabled")),
            InputBackend::Disabled
        );
        assert_eq!(
            parse_input_backend("warpd", Some("dbus-abs")),
            InputBackend::DbusAbs
        );
        assert_eq!(
            parse_input_backend("abs", Some("dbus-rel")),
            InputBackend::DbusRel
        );
        assert_eq!(
            parse_input_backend("abs", Some("warpd")),
            InputBackend::Warpd
        );
        assert_eq!(
            parse_input_backend("warpd", Some("gallery-hid")),
            InputBackend::GalleryHid
        );
        assert_eq!(
            parse_input_backend("abs", Some("x11test")),
            InputBackend::X11Test
        );
        assert_eq!(
            parse_input_backend("abs", Some("mamecmd")),
            InputBackend::MameCmd
        );
        assert_eq!(
            parse_input_backend("abs", Some("mamesock")),
            InputBackend::MameSock
        );
    }

    /// The rejection must name every accepted value, or an operator debugging a
    /// station.env typo cannot see that the new backend exists.
    #[test]
    #[should_panic(expected = "mamesock")]
    fn unknown_backend_error_lists_mamesock() {
        parse_input_backend("abs", Some("garbage"));
    }

    #[test]
    fn legacy_pointer_and_backend_values_keep_their_routes() {
        assert_eq!(parse_input_backend("abs", None), InputBackend::DbusAbs);
        assert_eq!(parse_input_backend("rel", None), InputBackend::DbusRel);
        assert_eq!(parse_input_backend("warpd", None), InputBackend::Warpd);
        assert_eq!(
            parse_input_backend("abs", Some("dbus")),
            InputBackend::DbusAbs
        );
        assert_eq!(
            parse_input_backend("rel", Some("dbus")),
            InputBackend::DbusRel
        );
        assert_eq!(
            parse_input_backend("warpd", Some("warpd")),
            InputBackend::Warpd
        );
        assert_eq!(
            parse_input_backend("warpd", Some("gallery-hid")),
            InputBackend::GalleryHid
        );
        assert_eq!(parse_input_backend("unknown", None), InputBackend::DbusAbs);
    }
}

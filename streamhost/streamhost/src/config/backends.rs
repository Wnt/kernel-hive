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

/// Parse `SH_X11TEST_BUTTONS`: the button route of the `x11test` input
/// backend. `cmdfile` (default) keeps the historical MAME-Lua-agent command
/// file; `xtest` sends paced XTEST ButtonPress/ButtonRelease instead (any SDL
/// emulator under Xvfb, no agent required). Unknown values panic like
/// `SH_INPUT_BACKEND` does: a typo must be visible, not a silent cmd-file
/// fallback on a station that has no agent to read the file.
pub(super) fn parse_x11test_buttons(s: &str) -> bool {
    match s.trim().to_ascii_lowercase().as_str() {
        "xtest" => true,
        "cmdfile" | "" => false,
        v => panic!("invalid SH_X11TEST_BUTTONS={v:?}; expected cmdfile|xtest"),
    }
}

/// The `x11test` sink's opt-in mode block, construction-frozen. Everything
/// defaults to the historical behavior, so the existing fleet is
/// byte-identical with the envs unset; each knob is documented in
/// docs/CONFIG.md. Doubling as the sink's own options type keeps the
/// god-struct module under the size cap.
#[derive(Clone, Copy, Debug)]
pub struct X11TestConfig {
    /// `SH_X11TEST_ABS` — motion as TRUE ABSOLUTE XTEST (root window plus
    /// root coords) for an emulator that follows the host X cursor 1:1
    /// (FS-UAE `--mouse_integration=1`). Off = relative+homing dead reckoning.
    pub abs: bool,
    /// `SH_X11TEST_BUTTONS=xtest` — buttons/wheel as paced XTEST edges
    /// instead of Lua-agent cmd-file lines.
    pub buttons_xtest: bool,
    /// `SH_X11TEST_KEYS` — keyboard as paced XTEST edges (embedded US-layout
    /// table, `SH_X11TEST_KEYMAP` override). Off = keys unrouted, as today.
    pub keys: bool,
    /// `SH_BTN_MIN_HOLD_MS` (default 60, capped 250) — XTEST-button dwell
    /// floor, both press-to-release hold and release-to-next-press gap: an
    /// instant browser click is stretched to three 50 Hz frames, never
    /// dropped (an XTEST press+release ~0 ms apart is NEVER sampled).
    pub btn_hold_ms: u64,
    /// `SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS` as they apply to THIS sink:
    /// same envs as the dbus key gate, but UNSET means 40/40 here (capped
    /// 250) — a 50 Hz guest needs the floor, and turning it off must be an
    /// explicit `0`, not an omission.
    pub key_hold_ms: u64,
    pub key_gap_ms: u64,
}

impl X11TestConfig {
    pub(super) fn from_env() -> Self {
        use super::parse::env_or;
        let flag = |name: &str| {
            matches!(
                env_or(name, "off").to_ascii_lowercase().as_str(),
                "on" | "1" | "true"
            )
        };
        // Env PRESENCE decides the key floors: unset -> 40, explicit value
        // (0 included) wins.
        let key_floor = |name: &str| -> u64 {
            std::env::var(name)
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(40)
        };
        Self {
            abs: flag("SH_X11TEST_ABS"),
            buttons_xtest: parse_x11test_buttons(&env_or("SH_X11TEST_BUTTONS", "cmdfile")),
            keys: flag("SH_X11TEST_KEYS"),
            // Same 250 ms cap as the key gate: a station.env typo must not be
            // able to wedge the pointer or keyboard.
            btn_hold_ms: env_or("SH_BTN_MIN_HOLD_MS", "60")
                .parse()
                .unwrap_or(60)
                .min(250),
            key_hold_ms: key_floor("SH_KEY_MIN_HOLD_MS").min(250),
            key_gap_ms: key_floor("SH_KEY_MIN_GAP_MS").min(250),
        }
    }
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
    /// Native `vicectl/1` route for a host-native headless VICE station (the
    /// VICE de-bridging wave). Same socket/ack state machine as `MameSock`, but
    /// the key verb carries an X11 KEYSYM rather than a matrix cell: VICE
    /// resolves it through the machine's own `.vkm` keymap, so one shared
    /// host-layout table serves all seven stations. Keyboard-only. Never
    /// inferred — only set explicitly via `SH_INPUT_BACKEND=vicesock`.
    /// Single-injector rule: the station must then NOT be driven through VICE's
    /// binary monitor.
    ViceSock,
    /// Native `mgaptr/1` route for `aix432`: the fleet's second CLOSED-LOOP
    /// pointer, and the first one inside QEMU. AIX's GXT130P X server drives
    /// the emulated Matrox HARDWARE cursor, so the guest writes the pointer
    /// position into the DAC's CURPOSX/Y registers and the device model reads
    /// them back — the loop converges on the measurement instead of reckoning
    /// deltas against a belief the way `DbusRel` must. Pointer only: keys stay
    /// on this station's working QEMU/dbus path. Never inferred — only set
    /// explicitly via `SH_INPUT_BACKEND=mgactl` (socket `SH_MGACTL_SOCK`).
    /// Single-injector rule: nothing else may push motion or button edges at
    /// that guest's PS/2 mouse while the socket is connected.
    MgaCtl,
    /// Native `artistptr/1` route for `hpuxvue`: the same closed loop as
    /// `MgaCtl`, ported to the B160L's Artist framebuffer. HP-UX 10.20's X
    /// server drives the Artist HARDWARE cursor, so the guest writes the
    /// pointer position into the CURSOR_POS/CURSOR_CTRL registers and the
    /// device model reads them back — the loop converges on the measurement
    /// instead of reckoning deltas against a belief the way `DbusRel` must.
    /// Pointer only: keys stay on this station's working QEMU/dbus path.
    /// Never inferred — only set explicitly via `SH_INPUT_BACKEND=artistctl`
    /// (socket `SH_ARTISTCTL_SOCK`). Single-injector rule: nothing else may
    /// push motion or button edges at that guest's LASI PS/2 mouse while the
    /// socket is connected.
    ArtistCtl,
    /// Native `ramabs/1` route: the wire to a QEMU-side control object that
    /// performs an ABSOLUTE WRITE of the commanded coordinate into the guest
    /// OS's own pointer structure in guest RAM, then publishes it. NOT a
    /// closed loop — no gain, no convergence, no hotspot in the path; the
    /// control object verifies its address at connect and fails closed, and
    /// everything guest-specific lives on the QEMU side, never here. Pointer
    /// only: keys stay on the station's working QEMU/dbus path. Never
    /// inferred — only set explicitly via `SH_INPUT_BACKEND=ramabs` (socket
    /// `SH_RAMABS_SOCK`). Single-injector rule: nothing else may push motion
    /// or button edges at that guest's pointer while the socket is connected.
    /// First station: `rhapsody` (Rhapsody 5.1 DR2 for Intel).
    RamAbs,
    /// XWarpPointer route for `sunos414`: the guest's own X server (X11R5
    /// `xnews`, reached over a loopback SLIRP forward, `SH_X11WARP_DISPLAY`)
    /// is both actuator (WarpPointer to an absolute root coordinate) and
    /// sensor (QueryPointer reads the guest's own position back) — the cg3
    /// framebuffer has no hardware cursor, so no register loop is possible.
    /// POINTER ONLY: the server has no XTEST, so buttons and keys CANNOT be
    /// injected through X and stay on the QEMU D-Bus PS/2 path; the sink
    /// verifies every ordered warp with QueryPointer before the held edge is
    /// released (see `x11_warp.rs`). Never inferred — only set explicitly via
    /// `SH_INPUT_BACKEND=x11warp`. Single-injector rule: nothing else may push
    /// MOTION at this guest's pointer while the X connection is up.
    X11Warp,
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
            Self::ViceSock => "vicesock",
            Self::MgaCtl => "mgactl",
            Self::ArtistCtl => "artistctl",
            Self::RamAbs => "ramabs",
            Self::X11Warp => "x11warp",
        }
    }

    pub fn is_dbus(self) -> bool {
        matches!(self, Self::DbusAbs | Self::DbusRel)
    }

    /// Compatibility value for the existing signaling.json `pointer` field.
    /// Transport selection itself is reported by `as_str()`.
    pub fn pointer_mode(self) -> &'static str {
        match self {
            // Keyboard-only, exactly like a `pointer: none` station: the
            // vicesock sink has no pointer verb at all.
            Self::Disabled | Self::ViceSock => "none",
            Self::DbusRel => "rel",
            Self::Warpd => "warpd",
            Self::DbusAbs
            | Self::GalleryHid
            | Self::X11Test
            | Self::MameCmd
            | Self::MameSock
            | Self::MgaCtl
            | Self::ArtistCtl
            | Self::RamAbs
            | Self::X11Warp => "abs",
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
        Some(v) if v.eq_ignore_ascii_case("vicesock") => InputBackend::ViceSock,
        Some(v) if v.eq_ignore_ascii_case("mgactl") => InputBackend::MgaCtl,
        Some(v) if v.eq_ignore_ascii_case("artistctl") => InputBackend::ArtistCtl,
        Some(v) if v.eq_ignore_ascii_case("ramabs") => InputBackend::RamAbs,
        Some(v) if v.eq_ignore_ascii_case("x11warp") => InputBackend::X11Warp,
        Some(v) if v.eq_ignore_ascii_case("dbus") && legacy_pointer.is_dbus() => legacy_pointer,
        Some(v) if v.eq_ignore_ascii_case("dbus") => panic!(
            "invalid legacy input combination SH_POINTER=warpd + SH_INPUT_BACKEND=dbus; use SH_INPUT_BACKEND=dbus-abs|dbus-rel|warpd|gallery-hid"
        ),
        Some(v) => panic!(
            "invalid SH_INPUT_BACKEND={v:?}; expected disabled|dbus-abs|dbus-rel|warpd|gallery-hid|x11test|mamecmd|mamesock|vicesock|mgactl|artistctl|ramabs|x11warp (legacy dbus also accepted with SH_POINTER=abs|rel)"
        ),
        None => legacy_pointer,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        parse_audio_source, parse_input_backend, parse_key_remap, parse_silence_thresh,
        parse_x11test_buttons, AudioSource, InputBackend,
    };

    #[test]
    fn x11test_buttons_parses_both_routes() {
        assert!(!parse_x11test_buttons("cmdfile"));
        assert!(!parse_x11test_buttons("")); // unset -> historical route
        assert!(parse_x11test_buttons("xtest"));
        assert!(parse_x11test_buttons(" XTEST "));
    }

    /// A typo'd route must be loud — on an agentless station the cmd-file
    /// fallback would be a black hole for every click.
    #[test]
    #[should_panic(expected = "SH_X11TEST_BUTTONS")]
    fn x11test_buttons_rejects_garbage() {
        parse_x11test_buttons("agent");
    }

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
        assert_eq!(
            parse_input_backend("abs", Some("vicesock")),
            InputBackend::ViceSock
        );
        assert_eq!(
            parse_input_backend("abs", Some("mgactl")),
            InputBackend::MgaCtl
        );
        assert_eq!(
            parse_input_backend("abs", Some("artistctl")),
            InputBackend::ArtistCtl
        );
        assert_eq!(
            parse_input_backend("abs", Some("ARTISTCTL")),
            InputBackend::ArtistCtl
        );
        assert_eq!(
            parse_input_backend("abs", Some("ramabs")),
            InputBackend::RamAbs
        );
        assert_eq!(
            parse_input_backend("abs", Some("RAMABS")),
            InputBackend::RamAbs
        );
        assert_eq!(InputBackend::ViceSock.pointer_mode(), "none");
        assert_eq!(InputBackend::ArtistCtl.pointer_mode(), "abs");
        assert_eq!(InputBackend::RamAbs.pointer_mode(), "abs");
        assert_eq!(
            parse_input_backend("abs", Some("x11warp")),
            InputBackend::X11Warp
        );
        assert_eq!(InputBackend::X11Warp.as_str(), "x11warp");
        assert_eq!(InputBackend::X11Warp.pointer_mode(), "abs");
    }

    /// The rejection must name every accepted value, or an operator debugging a
    /// station.env typo cannot see that the new backend exists.
    #[test]
    #[should_panic(expected = "mamesock")]
    fn unknown_backend_error_lists_mamesock() {
        parse_input_backend("abs", Some("garbage"));
    }

    /// ...and every value added since, or the same operator cannot see the
    /// backend their fixture is supposed to name.
    #[test]
    #[should_panic(expected = "vicesock")]
    fn unknown_backend_error_lists_vicesock() {
        parse_input_backend("abs", Some("garbage"));
    }

    /// ...ramabs included.
    #[test]
    #[should_panic(expected = "ramabs")]
    fn unknown_backend_error_lists_ramabs() {
        parse_input_backend("abs", Some("garbage"));
    }

    #[test]
    #[should_panic(expected = "artistctl")]
    fn unknown_backend_error_lists_artistctl() {
        parse_input_backend("abs", Some("garbage"));
    }

    #[test]
    #[should_panic(expected = "x11warp")]
    fn unknown_backend_error_lists_x11warp() {
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

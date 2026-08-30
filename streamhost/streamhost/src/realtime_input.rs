//! Process-wide realtime input router and native gallery-hid backend.
//!
//! Browser receive tasks only take a short `try_lock`, update state, and offer a
//! fixed record. Socket connect/handshake/write/reconnect work lives in one
//! background task. Motion has one latest-wins slot; transitions use a bounded
//! ordered queue and are never coalesced across.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, TryLockError};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::Notify;

use crate::config::{Config, InputBackend};
use crate::{mame_input, mame_sock, ptr_grid, vice_keymap, vice_sock};

const RECORD_BYTES: usize = 16;
const ORDERED_CAPACITY: usize = 64;
const HEALTH_STARTING: u8 = 0;
const HEALTH_HEALTHY: u8 = 1;
const HEALTH_DOWN: u8 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AcceptedSeq(pub u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reject {
    Busy,
    Overflow,
    BackendDown,
    Unsupported,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SinkHealth {
    Starting,
    Healthy,
    Down,
}

#[derive(Clone, Copy, Debug)]
pub struct PointerAbs {
    pub seq: u64,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub buttons: u16,
    pub wheel_v: i8,
    pub wheel_h: i8,
    /// Button/wheel snapshots are ordered; move-only snapshots may coalesce.
    pub ordered: bool,
}

// The KeyEvent/try_key path mirrors try_pointer_abs one-for-one. input.rs::handle()
// routes type=3 records here for the `mamecmd`/`mamesock` backends (the IRIX station,
// whose guest has no D-Bus connection to inject over); every other backend still
// takes the classic dbus/warpd key path, so the QEMU fleet is untouched. `repeat` is carried
// but unused by the sinks today — both let the guest auto-repeat from the held key.
#[derive(Clone, Copy, Debug)]
pub struct KeyEvent {
    pub seq: u64,
    pub key: u16,
    pub down: bool,
    pub repeat: bool,
    pub modifiers: u16,
}

pub trait RealtimeInputSink: Send + Sync {
    /// Nonblocking. All socket work is performed by the backend task.
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject>;
    /// Sinks whose transport has no keyboard leave this rejecting; input.rs only
    /// routes keys to backends that implement it.
    fn try_key(&self, _event: KeyEvent) -> Result<AcceptedSeq, Reject> {
        Err(Reject::Unsupported)
    }
    fn health(&self) -> SinkHealth;
    fn backend_name(&self) -> &'static str;
}

// The concrete GalleryHid/Warpd sinks live in a sibling file purely for the
// per-file line budget; `#[path]` keeps them a private child module with the
// same access to this module's items (and the tests' access to theirs).
#[path = "realtime_input_sinks.rs"]
mod sinks;
use sinks::*;

#[derive(Clone, Copy)]
struct RouterState {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    buttons: u16,
    /// Modifier mask carried on every KeyEvent. The mamecmd sink does not need it
    /// (the browser sends real Shift/Ctrl make/break, which the matrix presses like
    /// any other key); gallery-hid's wire format does.
    modifiers: u16,
}

pub struct InputRouter {
    sink: Arc<dyn RealtimeInputSink>,
    seq: AtomicU64,
    state: Mutex<RouterState>,
}

/// The routed-button set, by backend NAME so it is testable without a sink.
/// See `InputRouter::routes_buttons` for why this list is an invariant.
pub(crate) fn backend_routes_buttons(backend: &str, warpd_buttons_qemu: bool) -> bool {
    matches!(
        backend,
        "gallery-hid" | "x11test" | "mamecmd" | "mamesock" | "mgactl" | "artistctl" | "ramabs"
    ) || (backend == "warpd" && !warpd_buttons_qemu)
}

impl InputRouter {
    pub fn from_config(cfg: &Config) -> Option<Arc<Self>> {
        let sink: Arc<dyn RealtimeInputSink> = match cfg.input_backend {
            InputBackend::Disabled | InputBackend::DbusAbs | InputBackend::DbusRel => return None,
            InputBackend::Warpd => WarpdSink::new(cfg),
            InputBackend::GalleryHid => GalleryHidSink::new(cfg.ghid_socket.clone()),
            InputBackend::MameCmd => mame_input::MameCmdSink::new(
                &cfg.x11_cmd_file,
                cfg.mamecmd_abs,
                mame_input::KeyMap::from_env(),
            ),
            InputBackend::MameSock => mame_sock::MameSockSink::new(
                cfg.mamectl_sock.clone(),
                ptr_grid::PtrGrid::from_env(),
                mame_input::KeyMap::from_env(),
            ),
            InputBackend::ViceSock => vice_sock::ViceSockSink::new(
                cfg.vicectl_sock.clone(),
                vice_keymap::ViceKeyMap::from_env(),
            ),
            InputBackend::MgaCtl => {
                crate::mga_ctl::MgaCtlSink::new(crate::mga_ctl::socket_from_env(&cfg.tile))
            }
            InputBackend::ArtistCtl => {
                crate::artist_ctl::ArtistCtlSink::new(crate::artist_ctl::socket_from_env(&cfg.tile))
            }
            InputBackend::RamAbs => {
                crate::ram_abs::RamAbsSink::new(crate::ram_abs::socket_from_env(&cfg.tile))
            }
            InputBackend::X11Test => {
                match crate::x11_input::X11TestSink::new(
                    &cfg.x11_display,
                    &cfg.x11_cmd_file,
                    cfg.x11test,
                ) {
                    Ok(sink) => sink,
                    Err(e) => {
                        eprintln!("[input-router] x11test sink init failed: {e:#}; input disabled");
                        return None;
                    }
                }
            }
        };
        eprintln!(
            "[input-router] backend={} process-wide health={:?}",
            sink.backend_name(),
            sink.health(),
        );
        Some(Arc::new(Self {
            sink,
            seq: AtomicU64::new(1),
            state: Mutex::new(RouterState {
                x: 0,
                y: 0,
                width: 1,
                height: 1,
                buttons: 0,
                modifiers: 0,
            }),
        }))
    }

    pub fn backend(&self) -> &'static str {
        self.sink.backend_name()
    }

    /// True when type=3 key records route to this router's sink instead of the
    /// classic QEMU/dbus keyboard path (see input.rs). The matrix sinks always
    /// do; x11test only when SH_X11TEST_KEYS armed its keyboard.
    pub fn routes_keys(&self, cfg: &Config) -> bool {
        matches!(self.backend(), "mamecmd" | "mamesock" | "vicesock")
            || (self.backend() == "x11test" && cfg.x11test.keys)
    }

    /// True when a type=2 button EDGE routes to this sink — position and edge
    /// as one ordered event — instead of firing immediately down the classic
    /// QEMU/dbus PS/2 path (see input.rs).
    ///
    /// THIS LIST IS AN INVARIANT, NOT A PREFERENCE. Motion already routes to
    /// whatever sink exists (`apply_move_abs` takes the router unconditionally),
    /// so a sink that is missing HERE gets its moves through the queue and its
    /// clicks around it — two injectors racing over one guest pointer. The
    /// symptom does not look like a routing bug: the cursor tracks perfectly
    /// and only clicks misbehave, because the press fires while the sink is
    /// still walking the cursor to the point the click was aimed at. The guest
    /// then sees press-at-A, motion, release-at-B — a DRAG. Links tolerate it;
    /// an HTML form field never takes keyboard focus from it, which reaches the
    /// operator as "the keyboard stopped working in the browser".
    ///
    /// mgactl (aix432) shipped missing from it and cost an afternoon, so
    /// `routes_buttons_invariant` in the tests below now pins it: every sink
    /// that can carry an ordered button edge must be listed.
    ///
    /// warpd is the ONE deliberate exception: with SH_WARPD_BUTTONS=qemu its
    /// motion rides the agent channel while buttons ride PS/2 on purpose, and
    /// input.rs holds the edge back by SH_WARPD_BUTTON_DELAY_MS instead.
    pub fn routes_buttons(&self, cfg: &Config) -> bool {
        backend_routes_buttons(self.backend(), cfg.warpd_buttons_qemu)
    }

    pub fn health(&self) -> SinkHealth {
        self.sink.health()
    }

    /// try_lock the router state, counting a telemetry drop on contention (these
    /// samples were previously discarded silently, uncounted).
    ///
    /// MOVES ONLY. Dropping a move under contention is free — another one is
    /// always right behind it — but dropping a button EDGE loses the click
    /// outright, and nothing retries it. Edges take `lock_state_ordered`.
    fn lock_state(&self) -> Result<std::sync::MutexGuard<'_, RouterState>, Reject> {
        self.state.try_lock().map_err(|_| {
            crate::input_telemetry::record_router_drop(self.backend());
            Reject::Busy
        })
    }

    /// Block for the router state, for events that MUST NOT be dropped: button
    /// edges, wheel, keys. The lock is held for a handful of field writes plus
    /// one non-blocking sink offer and is never held across an await, so waiting
    /// costs microseconds and cannot deadlock — while losing an edge costs the
    /// visitor a click, or strands a button DOWN in the guest until they find
    /// their way out of a drag they never started (measured on IRIX, 2026-08-05:
    /// a hover stream at ~25/s beat every press to this lock, and every one of
    /// those presses was silently discarded).
    fn lock_state_ordered(&self) -> std::sync::MutexGuard<'_, RouterState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn try_move(&self, x: u32, y: u32, width: u32, height: u32) -> Result<AcceptedSeq, Reject> {
        let mut state = self.lock_state()?;
        state.x = x.min(width.saturating_sub(1));
        state.y = y.min(height.saturating_sub(1));
        state.width = width.max(1);
        state.height = height.max(1);
        self.offer_pointer(&state, 0, 0, false)
    }

    /// A button edge, optionally AT a position the client carried with it.
    ///
    /// Position and edge are applied under ONE acquisition and leave as ONE
    /// ordered event, so nothing — not a concurrent move, not a lock race — can
    /// get between a press and the point it was aimed at.
    pub fn try_button_at(
        &self,
        button: u8,
        down: bool,
        at: Option<(u32, u32, u32, u32)>,
    ) -> Result<AcceptedSeq, Reject> {
        if button >= 5 {
            return Err(Reject::Unsupported);
        }
        let mut state = self.lock_state_ordered();
        if let Some((x, y, width, height)) = at {
            state.x = x.min(width.saturating_sub(1));
            state.y = y.min(height.saturating_sub(1));
            state.width = width.max(1);
            state.height = height.max(1);
        }
        let mask = 1u16 << button;
        if down {
            state.buttons |= mask;
        } else {
            state.buttons &= !mask;
        }
        self.offer_pointer(&state, 0, 0, true)
    }

    pub fn try_button(&self, button: u8, down: bool) -> Result<AcceptedSeq, Reject> {
        self.try_button_at(button, down, None)
    }

    pub fn try_wheel(&self, dx: i32, dy: i32) -> Result<AcceptedSeq, Reject> {
        let state = self.lock_state_ordered();
        let wheel_v = dy.clamp(-127, 127) as i8;
        let wheel_h = dx.clamp(-127, 127) as i8;
        self.offer_pointer(&state, wheel_v, wheel_h, true)
    }

    pub fn try_key(&self, key: u16, down: bool, repeat: bool) -> Result<AcceptedSeq, Reject> {
        let mut state = self.state.try_lock().map_err(|_| Reject::Busy)?;
        if let Some(bit) = modifier_bit(key) {
            if down {
                state.modifiers |= 1 << bit;
            } else {
                state.modifiers &= !(1 << bit);
            }
        }
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        self.sink.try_key(KeyEvent {
            seq,
            key,
            down,
            repeat,
            modifiers: state.modifiers,
        })
    }

    fn offer_pointer(
        &self,
        state: &RouterState,
        wheel_v: i8,
        wheel_h: i8,
        ordered: bool,
    ) -> Result<AcceptedSeq, Reject> {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        self.sink.try_pointer_abs(PointerAbs {
            seq,
            x: state.x,
            y: state.y,
            width: state.width,
            height: state.height,
            buttons: state.buttons,
            wheel_v,
            wheel_h,
            ordered,
        })
    }
}

fn modifier_bit(key: u16) -> Option<u8> {
    match key {
        0x002a => Some(0),
        0x0036 => Some(1),
        0x001d => Some(2),
        0xe01d => Some(3),
        0x0038 => Some(4),
        0xe038 => Some(5),
        0xe05b => Some(6),
        0xe05c => Some(7),
        _ => None,
    }
}

#[cfg(test)]
#[path = "realtime_input_tests.rs"]
mod tests;

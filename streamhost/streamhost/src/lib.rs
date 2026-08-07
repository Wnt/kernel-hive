// streamhost — library surface.
//
// The daemon binary (`src/main.rs`) is self-contained and declares its own private
// `mod`s; it does NOT use this lib (so the normal streamhost build is untouched).
// This lib exists ONLY so the `bootrec-tap` sidecar binary (src/bin/bootrec-tap.rs)
// can REUSE the exact QEMU dbus display + audio capture plumbing the daemon ships,
// rather than re-implementing the SCM_RIGHTS fd-passing / zbus p2p register dance.
//
// Surface is deliberately minimal and self-contained:
//   capture -> config (env_flag only);  audio -> clock;  config, clock -> std only.
// Nothing else from the daemon is pulled in.
#![allow(dead_code)]

pub mod audio;
pub mod capture;
pub mod clock;
pub mod config;

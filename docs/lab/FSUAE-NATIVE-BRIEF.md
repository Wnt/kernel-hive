# FS-UAE host-native (no Xvfb) — fork brief

**Status: IN PROGRESS (2026-09-09).** `a1000` and `a3000` are LIVE on the box
on the host-native plane since ~19:57 (box clock) — no Xvfb, no XTEST:
`SH_CAPTURE=shm` 640x512, `SH_INPUT_BACKEND=mamesock` against the
`FSUAE_NATIVE_CTL_SOCK` control socket, `SH_AUDIO_SOURCE=fifo`, pointer
proven exact through the real daemon. `amigaos35` and `amix` boot headless on
rigs (desktop up, a socket double-click proven) but their conversion —
netns cage, audio, reset, RTG publish gating — is still in progress on
branch `fsuae-stations2`. Rule 13 work, carried as commits on the fork:

| | |
|---|---|
| fork | `github.com/Wnt/fs-uae`, branch `kernel-hive/integrated` (v3.2.35 + lab commits) |
| submodule | `third_party/fs-uae-kernel-hive`, gitlink = the builder's pin |
| builder | `scripts/build-guests/emulators/build-fsuae-native.sh` (`FSUAE_FORK_PIN`); bootstrap runs on labhost (autotools, no zip), configure/make in CT950 (zip, no autotools) |
| declared | `registry/release-notes/sources.json` |
| plane branches | `kernel-hive/native-video`, `kernel-hive/native-input`, `kernel-hive/native-audio` — merged into `integrated` once each is proven on the framebuffer |

The survey, source map and commit plan below were produced by an Opus
discovery agent on 2026-09-09 and are kept verbatim as the design record; the
station conversions and measured results are appended as they land.

**Station status (2026-09-09, box clock):**

| Station | Path | Proof |
|---|---|---|
| `a1000` | native since 19:58 | shm 640x512 floppy boot; pointer exact; keys via socket unmeasured on this station |
| `a3000` | native since 19:57 | shm 640x512; pointer exact; `KEY` PASS (Right-Amiga+E, `echo hello 1234` → Output Window); reset in 5 s |
| `amigaos35` | native since 20:32 | shm 640x514; ~10 s cold boot (was ~85 s); inside the `rn-amigaos35` cage AWeb loaded the retronet www.amiga.de mirror after a socket double-click |
| `amix` | **rolled back to Xvfb** at 20:35 | headless video proven (A2410 1024x768 via the RTG route), but its buttons/keys rode XTEST into the Xvfb window while the pointer warps into the guest's X — with no Xvfb the daemon's `x11test` sink had nothing to connect to (input disabled). Reconvert once the daemon composes `x11warp` motion with ctlsock button/key edges (one input backend per station today). |

Open on the fork: RTG publish rate is ungated (~80/s at 1024x768); SAVEST/LOADST and
the FIFO reopen throttle unexercised; `labctl type` needs the natural-keyboard
verbs (`POST`/`CODE`) — drive keys with `labctl mctl <id> "KEY 1 amiga <raw>"`.

---

# FS-UAE host-native (no Xvfb): fork survey, source map, commit plan

Agent: **Opus** (discovery, read-only). Fork survey delegated to one Sonnet web
agent; source map and proposal are mine. Every file:line below was read in this
session. Source tree read: `/data/vms/sandbox/amigaos35/BUILD-fsuae/fs-uae-3.2.35`
(upstream 3.2.35 + the two lab patches).

---

## Part 1 — fork survey: is any of this already done?

**Verdict: nobody in the UAE lineage has built the shm+FIFO+ctlsock triple.**
No FS-UAE 3.x fork exists whose patches could be cherry-picked. Details:

| Project | URL (fetched) | Video export | Audio export | Input inject | Abs mouse | License / activity | Lineage |
|---|---|---|---|---|---|---|---|
| FS-UAE headless ask | https://github.com/FrodeSolheim/fs-uae/issues/91 | no | no | no | — | GPL; issue open since 2015-11-07, never implemented | upstream itself |
| Amiberry | https://github.com/BlitterStudio/amiberry/issues/1142 | no (issue is only "don't abort SDL init with no display"; proposed `--enable-video-dummy`) | no | no | **yes** (WinUAE mousehack, per issue #728 + wiki) | GPL, active 2026 | WinUAE-derived, NOT FS-UAE 3.x |
| libretro-uae | https://github.com/libretro/libretro-uae | **yes** (`retro_video_refresh_t`) | **yes** (`retro_audio_sample_batch_t`) | **yes** (`retro_input_state_t`) | **yes** (`RETRO_DEVICE_POINTER`, normalized ±0x7fff) | GPL-2.0, very active (WHDLoad pack 2026-03) | core is **WinUAE 5.3.1**, not FS-UAE |
| WinUAE | https://github.com/tonioni/WinUAE/blob/master/debug.cpp | no | no | console debugger only (no socket in fetched portion) | yes (origin of mousehack) | GPL, active | upstream of Amiberry/libretro-uae |
| vAmiga | https://github.com/dirkwhoffmann/vAmiga | — | — | — | — | active | 68000/020 only — **no 68040**, dead end for amigaos35/amix |
| Copperline | https://copperline.dev/ + https://github.com/CopperlineHQ/Copperline | frame streaming over its control channel | not confirmed | **yes** (JSON-RPC 2.0 over loopback TCP, `--control`: input inject, savestates, screenshots) | not confirmed | GPLv3 (m68k core MIT), releases through 2026 | independent Rust core, **not UAE** — nothing ports |

Unverified lead, flagged not fetched: `github.com/samuelbernardo/AVExe-FSUAE`
(surfaced on a "shared memory FS-UAE" search; appears to be video-dedup thesis
tooling, not an emulator interface). Do not treat as a hit.

Two things worth carrying forward even though no code ports:
- **Amiberry/WinUAE confirm mousehack is the right absolute-mouse primitive** —
  the same mechanism FS-UAE already has and the lab already patches.
- **libretro-uae is the only existing zero-SDL callback surface in the family.**
  A frontend (not a core patch) that dlopens `libretro-uae.so`, drives
  `retro_run()`, copies each `retro_video_refresh_t` buffer into the IFB1 shm,
  writes `retro_audio_sample_batch_t` into the FIFO, and answers
  `retro_input_state_t` from the ctlsock, is a real and well-trodden option.
  Cost: a **different emulator core** than the one the four goldens were baked
  against (rule 6 — golden + binary + device set are ONE combination).

---

## Part 2 — FS-UAE 3.2.35 source map

FS-UAE's own architecture is unusually kind here: the UAE core (`src/`,
`src/od-fs/`) is already decoupled from the presentation layer (`src/fs-uae/`,
`libfsemu/`) by a **C callback struct**. All three planes have a clean seam.

### (a) VIDEO — the frame exists as a plain RGB buffer before any GL

- `src/include/uae/fs.h:32` — `struct _libamiga_callbacks { init, event, render, display, log }`,
  the global at `src/od-fs/libamiga.cpp:29` (`g_libamiga_callbacks`).
- `src/od-fs/include/uae/uae.h:143-157` — `typedef struct _RenderData { unsigned char *pixels;
  int width, height; int limit_x, limit_y, limit_w, limit_h; char line[]; int flags;
  void *(*grow)(int,int); double refresh_rate; int bpp; }`.
- **THE HOOK:** `src/od-fs/video.cpp:249-251`
  ```
  if (g_libamiga_callbacks.render) {
      g_libamiga_callbacks.render(&g_renderdata);
  }
  ```
  called once per emulated frame from `render_frame()` (`src/od-fs/video.cpp:151`),
  itself called by `render_screen()` (`src/od-fs/video.cpp:271`). At this point
  `rd->pixels` is the **completed Amiga (or Picasso96 RTG) framebuffer**, fully
  drawn, in host memory, no GL involved.
- Registration: `src/od-fs/libamiga.cpp:641-643` `amiga_set_render_function()`,
  and the stock frontend registers its own `render_screen(RenderData*)` at
  `src/fs-uae/video.c:823` → body at `src/fs-uae/video.c:423`. That frontend
  function is the *only* consumer; it copies into an `fs_emu_video_buffer`
  (`libfsemu/src/emu/video_buffer.c:90` lock / `:97` unlock) which the GL
  renderer later uploads as a texture.
- Geometry / format:
  - `src/od-fs/video.cpp:30-33` — `AMIGA_WIDTH = AMIGA_WIDTH_MAX*2`, `AMIGA_HEIGHT 572`.
    `rd->width`/`rd->height` are the **full allocated buffer** (AGA hires-laced),
    while `rd->limit_x/y/w/h` are the auto-scale crop rectangle from
    `get_custom_limits()` (`src/od-fs/video.cpp:186`), normalized to hires/laced
    pixels by the shifts at `src/fs-uae/video.c:469-475`. RTG mode replaces both
    with `g_picasso_width/height` (`src/od-fs/video.cpp:165-170`) and sets
    `AMIGA_VIDEO_RTG_MODE`.
  - `src/od-fs/libamiga.cpp:43` — `g_amiga_video_bpp = 4` (32-bit) by default;
    `:168-174` can select 2 (16-bit). Keep 4 → **RGB32, stride = width*4**, which
    is exactly the IFB1 wire format, zero conversion.
- **Can it run without GL?** Not as shipped. `libfsemu/src/ml/` has no dummy
  video backend (the "dummy" symbols at `libfsemu/src/ml/video.c:5` etc. are
  empty-translation-unit padding, not a driver), and `SDL_VIDEODRIVER=dummy`
  still takes the SDL/GL path in `libfsemu/src/emu/video.c` — a GL context is
  created and `fs_emu_video_render_function` runs each frame. **Cheapest route
  is not a "null video backend" inside libfsemu — it is to never enter libfsemu
  at all**: register our own `render_function` instead of the frontend's and run
  the UAE core loop directly (see the proposal). The `g_libamiga_callbacks`
  seam makes libfsemu optional by construction, which is why this is much less
  work than it looks.
- Trap: `render_frame()` calls `notice_screen_contents_lost()` when
  `fse_drivers()` (`src/od-fs/video.cpp:264`), and `render_screen()` early-returns
  when `picasso_on` (`src/od-fs/video.cpp:275`) — RTG frames arrive through
  `gfx_lock_picasso2` (`src/od-fs/video.cpp:895`) instead. AmigaOS 3.5 on a
  Picasso96 screen will exercise that second path; amix (Amiga UNIX, native
  chipset) will not.

### (b) AUDIO — one callback, already s16 stereo

- `src/od-fs/audio.cpp:19` — `static int (*g_audio_callback)(int type, int16_t *buffer, int size)`.
- `src/od-fs/audio.cpp:50` — `amiga_set_audio_callback(func)`; `:56`
  `amiga_set_audio_buffer_size(size)`; `:62` `amiga_set_audio_frequency(freq)`.
- **THE CALL:** `src/od-fs/audio.cpp:192-194` inside `send_sound()`:
  `g_audio_callback(0, (int16_t *) paula_sndbuffer, paula_sndbufsize);`
  reached from `finish_sound_buffer()` (`src/od-fs/audio.cpp:197`) once per
  Paula buffer. `paula_sndbufsize = g_audio_buffer_size` (`src/od-fs/audio.cpp:295`),
  default `512*2*2 = 2048 bytes` (`:20`) = **512 frames of interleaved s16 stereo**;
  `currprefs.sound_stereo = 1` forced at `src/od-fs/audio.cpp:281`.
  Frequency is whatever `amiga_set_audio_frequency()` was given —
  the stock frontend passes `fs_emu_audio_output_frequency()`
  (`src/fs-uae/main.c:571`); we pass **48000** and the FIFO contract is met with
  no resampling.
- Stock consumer: `src/fs-uae/main.c:410` `audio_callback_function()` →
  `fse_queue_audio_buffer()`; registered `src/fs-uae/main.c:1372-1373`
  (also for CD audio, `type == 3`).
- **Return value matters.** `send_sound` discards it, but the CD path
  (`type == 3, buffer == NULL`) uses it as a buffer-fullness query. A FIFO sink
  returns a constant "fine" and **must never block**, or it becomes the timing
  source (see risks).

### (c) INPUT — mousehack absolute already exists and the lab already patches it

- **Absolute mouse, the exact entry point:** `src/inputdevice.cpp:8731`
  ```
  void uae_mousehack_helper(int x, int y)   /* #ifdef FSUAE */
  { lastmx = x; lastmy = y; mousehack_helper(0xffffffff); }
  ```
  Coordinate space: **host window / native output pixels, NOT Amiga pixels.**
  `mousehack_helper()` (`src/inputdevice.cpp:2520`) converts:
  `getgfxoffset(&fdx,&fdy,&fmx,&fmy)` (`src/od-fs/video.cpp:615-623`, which returns
  `fs_emu_video_offset_x/y` and `fs_emu_video_scale_x/y`), then
  `x = x*fmx - (fdx*fmx) + 1`, clamps to `gfxvidinfo.outbuffer->outwidth/outheight`
  (`src/inputdevice.cpp:2552-2561`), then
  `coord_native_to_amiga_x/y` (`:2562-2563`) before `inputdevice_mh_abs(x, y, buttonmask)`.
  **This is the load-bearing detail for the whole design:** the scale/offset
  come from libfsemu's *renderer*. Headless, nothing sets them. We must set
  `fs_emu_video_offset_x/y = 0` and `fs_emu_video_scale_x/y = 1.0` (or bypass
  `getgfxoffset` under the knob) so the daemon's MOVEA in published-frame pixel
  space maps 1:1 onto `outwidth/outheight`.
- Stock path for comparison: `src/od-fs/input.cpp:98-108` — on
  `INPUTEVENT_MOUSE1_HORIZ/VERT` with `input_magic_mouse`, it calls
  `uae_mousehack_helper(fs_emu_mouse_absolute_x, fs_emu_mouse_absolute_y)`.
  Today under Xvfb: XTEST motion → SDL motion → those globals → this call.
- Lower-level alternative (SDL-free but does the same clamping):
  `setmousestate(mouse, axis, data, isabs=1)` at `src/inputdevice.cpp:8075`;
  the abs branch (`:8113-8123`) sets `lastmx/lastmy` and calls
  `mousehack_helper` on the y axis. `uae_mousehack_helper` is strictly simpler.
- **Buttons:** `setmousebuttonstate(int mouse, int button, int state)` —
  `src/inputdevice.cpp:7986` (decl `src/include/inputdevice.h:238`); it also
  refreshes mousehack (`:7995`).
- **Keys:** `inputdevice_do_keyboard(int code, int state)` —
  `src/inputdevice.cpp:3698` (decl `src/include/inputdevice.h:255`), takes an
  **Amiga raw keycode**; it defers to `inputdevice_add_inputcode`
  (`src/inputdevice.cpp:3676`) for special codes. Higher-level:
  `amiga_send_input_event(input_event, state)` (`src/od-fs/input.cpp:76`) takes
  a UAE `INPUTEVENT_*`.
- **Threading — where injected events must be applied:** the UAE core calls back
  into the frontend twice per frame:
  - `handle_events()` — `src/od-fs/input.cpp:166`, fires
    `g_libamiga_callbacks.event(-1)` once per frame (vsync);
  - `handle_msgpump()` — `src/od-fs/input.cpp:198`, fires `...event(vpos)` per line.
  The stock frontend's `event_handler(int line)` (`src/fs-uae/main.c:329`)
  branches on `line >= 0`, and drains a lock-free queue via
  `fs_emu_get_input_event()` (`libfsemu/src/emu/input.c:795`, producer
  `fs_emu_queue_input_event` `:855`, queue `:793`). **A ctlsock reader thread
  must therefore only enqueue; all `setmousebuttonstate` /
  `inputdevice_do_keyboard` / `uae_mousehack_helper` calls happen on the UAE
  core thread inside our `event` callback.** That is the same shape MAME's
  ctlsock uses (drain in the emulator's frame callback), so per-verb acks are
  emitted from the drain, not from the reader.
- The lab's existing patch lives right here: `mousehack_rearm_from_env()` at
  `src/inputdevice.cpp:2019-2038` (restores `mousehack_address` after a
  savestate restore zeroes it via `mousehack_reset()` `:1981`).

### (d) CONTROL — where a unix socket server belongs

- No existing socket/stdin control plane in 3.2.35 — `grep` finds no listener;
  FS-UAE's remote surface is the Python launcher, not the emulator.
- Threading primitives are available: `src/od-fs/threading.cpp` + libfsemu's
  `fs_thread`. A detached reader thread + a mutex-guarded ordered queue drained
  in the `event(-1)` callback (above) is the whole design.
- **Savestate verbs.** `save_state(const TCHAR *filename, const TCHAR *description)`
  — `src/savestate.cpp:1107`; `restore_state(const TCHAR *filename)` —
  `src/savestate.cpp:507` (sets `savestate_state = STATE_RESTORE` at `:526`).
  Asynchronous variants set `savestate_state = STATE_DOSAVE / STATE_DORESTORE`
  (`src/savestate.cpp:1203`, `:1216`) and completion is signalled through
  `uae_on_save_state_finished` / `uae_on_restore_state_finished`
  (`src/od-fs/callbacks.h`) — those are the natural places to emit the ack.
  Note: amigaos35 currently **rejects** UAE savestates (`docs/guests/amigaos35.md:100-108`),
  so SAVEST/LOADST is a later commit, not a blocker.

### (e) RESET

`void uae_reset(int hardreset, int keyboardreset)` — `src/main.cpp:745`
(decl `src/include/uae.h:30`). `uae_reset(1, 1)` from the drain gives the
in-process 0.4 s reset the MAME stations got, replacing a service restart.

### Contrast — the shapes the lab already ships (read, not copied)

- **MAME video producer:** `scripts/build-guests/patches/mame-drawshm.patch`
  (557 lines) adds `-video shm`. Env `MAME_SHM_PATH` (required, unset = loud
  failure, no fallback), `MAME_SHM_SIZE=WxH`, `MAME_SHM_TRACE`. Wire: 64-byte
  header — `magic 'IFB1' 0x31424649`, version, width, height, stride, bpp,
  `u64` seqlock at offset 24, dirty rect at 32..47, pad to 64 — then
  `width*height` RGB32 pixels (patch lines 214-233, 281, 376-400).
  Seqlock discipline: `seq` goes **odd** before pixels are touched and **even**
  after, both `memory_order_release`.
- **Daemon reader:** `streamhost/streamhost/src/capture/shm.rs` — header doc
  `:21-44`, `const HEADER = 64` `:73`, `MAGIC = 0x3142_4649` `:74`,
  `MAX_TEARS = 16` `:80`, seq read acquire `:140`, re-map on any
  width/height/stride change `:258-268`.
- **MAME control plane:** `third_party/mame-irix/src/osd/modules/ctlsock/ctlsock.cpp`
  — listener on `MAME_CTL_SOCK` (`:352`), banner
  `HELLO mamectl/1 <machine> caps=natkbd,savest screen=WxH` (verified daemon-side
  at `streamhost/streamhost/src/mame_sock.rs:554`), verbs `MOVEA x y`,
  `DOWN1..3/UP1..3`, `KEY <0|1> <port> <field>`, per-verb `<seq> OK|ERR`.
  MOVEA acks on target-**accept**; edges ack when the edge **applies**.
  Daemon behaviour worth mirroring (`mame_sock.rs:1-48`): move-only targets
  coalesce latest-wins, transitions ride a bounded ordered queue and flush the
  pending move ahead of themselves, a fresh MOVEA is restated before every
  button edge, and on reconnect the guest is resynchronized (UP1..UP3, MOVEA,
  then DOWNn for held buttons). Single-injector rule is BINDING.
- **VICE control plane:** `streamhost/streamhost/src/vice_sock.rs:1-25` — same
  state machine, but `KEY <0|1> <X11 keysym>` so VICE's own `.vkm` resolves the
  matrix and no per-station map is needed. **This is the model FS-UAE should
  follow**: FS-UAE has a keymap (`keymap.cpp` / `INPUTEVENT_KEY_*`), so the
  verb should carry a symbolic key, not an Amiga matrix cell.
- **Audio FIFO contract:** `streamhost/streamhost/src/audio.rs:194-236` —
  raw **s16le interleaved stereo @ 48 kHz** into a named pipe;
  `FIFO_TICK_BYTES = 3840` (960 samples × 2ch × 2B) consumed per 20 ms tick =
  192,000 B/s; pipe shrunk to 16 KiB via `F_SETPIPE_SZ` (~85 ms standing
  latency); producer stalls > 250 ms resnap the schedule rather than burst.
  **"THE DAEMON IS THE CLOCK"** (`audio.rs:201`) — the producer writes unpaced
  and pipe backpressure paces it. No `Init()` handshake; format is fixed by the
  launcher contract (`audio.rs:226-235`).

---

## Part 3 — proposal

### Route: **patch FS-UAE 3.2.35 on `Wnt/fs-uae`.** Not libretro, not Amiberry.

Reasons, in order of weight:

1. **Rule 6.** Four stations (a1000, a3000, amigaos35, amix) have goldens,
   device sets and — for amigaos35 — a documented cold-boot reset contract baked
   against *this* binary. libretro-uae is a WinUAE-5.3.1 core: different chipset
   timing, different config surface, different savestate format. Every golden is
   orphaned and every bring-up is redone. That is four station re-bakes to avoid
   writing ~600 lines of C.
2. **The seam is already there.** `g_libamiga_callbacks.render` /
   `amiga_set_audio_callback` / `amiga_set_event_function` are a
   frontend-replacement API that FS-UAE's own author built. We are not carving a
   hole in a monolith; we are writing a second frontend against an existing one.
   Video needs no format conversion (RGB32 already), audio needs no resampling
   (`amiga_set_audio_frequency(48000)`), absolute mouse already exists and the
   lab already patches it.
3. **libretro would still need a frontend** — the callbacks are only half the
   work; we'd write the same shm/FIFO/ctlsock code *plus* a core loader, config
   translation, and four re-bakes. Strictly more work for a worse rule-6 story.
   Keep it documented as the fallback if FS-UAE 3.2.35 proves unpatchable.
4. **Amiberry contributes nothing** — its headless issue is about not crashing,
   and it is a different (WinUAE) core anyway.

### Coordinate-space decision (absolute mouse)

The daemon sends **surface-clamped `MOVEA x y` in the published frame's pixel
space** — i.e. the same `W×H` the shm header advertises. Therefore:

- The shm surface is published at the **crop rectangle** `limit_x/y/w/h`
  normalized to hires/laced (`src/fs-uae/video.c:469-475`), *not* the full
  572-line allocation — that is what the visitor sees and what MOVEA is clamped to.
- The ctlsock's `MOVEA` handler adds the crop origin back and calls
  `uae_mousehack_helper(x + limit_x, y + limit_y)` with
  `fs_emu_video_offset_x/y = 0` and `fs_emu_video_scale_x/y = 1.0` forced under
  the knob, so `mousehack_helper`'s transform (`src/inputdevice.cpp:2549-2563`)
  degrades to `coord_native_to_amiga_*` alone.
- Publish `screen=WxH` in the HELLO banner (same field mamectl/1 uses) and
  **re-emit it whenever the crop changes** (mode switch, Workbench →
  Picasso96 RTG). The daemon already re-maps on any geometry change
  (`capture/shm.rs:258-268`); the ctlsock must not go stale behind it.

### Commit series on `Wnt/fs-uae` (branch `kernel-hive-native`, tag from `v3.2.35`)

Every commit is gated so that **with the knob unset the binary is
byte-behaviourally identical** to today's build — the four live stations keep
running the Xvfb path off the same source until each is converted.

| # | Commit | Files | Knob | Framebuffer proof |
|---|---|---|---|---|
| 1 | Import 3.2.35 + the two existing lab patches as commits | `src/inputdevice.cpp`, `src/savestate.cpp`, `src/slirp_uae.cpp` | none (already live) | `--version` matches; amigaos35 boots unchanged |
| 2 | `native`: skeleton — a second frontend `src/fs-uae-native/main.c` that registers `amiga_set_render_function/_audio_callback/_event_function` and runs the core, entered only when `FSUAE_NATIVE_SHM` is set; otherwise `main()` is stock | new dir + `Makefile.am`, `configure.ac` | `FSUAE_NATIVE_SHM` | unset ⇒ existing Xvfb station boots byte-identical |
| 3 | `native/video`: IFB1 shm publisher — mmap `FSUAE_NATIVE_SHM`, publish the crop rect as RGB32 with the 64-byte header + odd/even seqlock, re-map on geometry change; `FSUAE_NATIVE_SHM_TRACE` for the publish counter. Unset path = loud failure, no fallback | `src/fs-uae-native/shm.c` | `FSUAE_NATIVE_SHM` | `scripts/shmshot.py` on a booting a1000 shows the Kickstart hand; then a Workbench screen |
| 4 | `native/audio`: `amiga_set_audio_frequency(48000)` + FIFO writer, **non-blocking** write, drop-on-full, always return "fine" to the CD-query path | `src/fs-uae-native/audio.c` | `FSUAE_NATIVE_AUDIO_FIFO` | daemon reports live Opus; disk-activity click audible in the browser |
| 5 | `native/ctlsock`: `fsuaectl/1` listener, HELLO banner with `screen=WxH caps=...`, reader thread enqueues only, drain in the `event(-1)` callback, per-verb `<seq> OK\|ERR` | `src/fs-uae-native/ctlsock.c` | `FSUAE_NATIVE_CTL_SOCK` | `HELLO` verified by a hand-run `socat`; `STAT` acks |
| 6 | `native/ctlsock`: `MOVEA` → `uae_mousehack_helper` with offsets/scale forced to identity; `DOWN1..3/UP1..3` → `setmousebuttonstate` | + `src/od-fs/video.cpp` (identity `getgfxoffset` under the knob) | same | **pointer lands on the Workbench close gadget and the window closes** — the one proof that matters |
| 7 | `native/ctlsock`: `KEY <0\|1> <sym>` → FS-UAE keymap → `inputdevice_do_keyboard`, VICE-style symbolic (no per-station matrix map) | `src/fs-uae-native/keys.c` | same | a typed line appears in a Shell |
| 8 | `native/ctlsock`: `RESET` → `uae_reset(1,1)`; `SAVEST/LOADST` → `save_state`/`restore_state` with acks from `uae_on_*_state_finished` | `src/fs-uae-native/ctlsock.c` | same | reset returns to Kickstart in-process (no service restart) |
| 9 | `build-fsuae-native.sh`: fetch `Wnt/fs-uae` at a pinned sha instead of the upstream tarball; keep the per-station `PREFIX` (rule 6) | `scripts/build-guests/emulators/build-fsuae-native.sh` | — | rebuilt binary restores each station's golden |

Convert stations one at a time after commit 8 (a1000 or a3000 first — simplest
device set; amigaos35 last because of RTG + its cold-boot reset contract).

### Risks

1. **GL-less render path (highest).** `render_screen()` early-returns on
   `picasso_on` (`src/od-fs/video.cpp:275`) and RTG frames come via
   `gfx_lock_picasso2` (`:895`); `render_frame()` also calls
   `notice_screen_contents_lost()` under `fse_drivers()` (`:264`). Commit 3 must
   prove **both** paths (native Workbench *and* a Picasso96 screen on amigaos35)
   or amigaos35 gets a black frame after a mode switch. Race it per rule 14:
   one clone per theory, `fb-wait.py --change`, not a guessed sleep.
2. **`getgfxoffset` is renderer state.** `fs_emu_video_offset_x/scale_x`
   (`src/od-fs/video.cpp:619-622`) are set by libfsemu's renderer, which we do
   not run. Left uninitialized the pointer transform is garbage. Commit 6 must
   force identity explicitly, and the crop-origin add must be re-derived on every
   geometry change, not cached.
3. **Mousehack one-event-late.** `docs/guests/amigaos35.md:100-108` — a *restored*
   mousehack consumes packets one event late even re-armed, which is why
   amigaos35 uses `relaunch` cold boot rather than a savestate. Commit 8's
   LOADST inherits that bug; do not promise SAVEST/LOADST on amigaos35 until it
   is measured on a rig. a1000/a3000 may be fine.
4. **Audio must not become the clock (the VICE 24%-speed trap).** The daemon is
   the clock (`audio.rs:201`) and pipe backpressure paces the *producer's audio
   thread* — but FS-UAE's `finish_sound_buffer` runs on the **emulation thread**
   (`src/od-fs/audio.cpp:197`), not a separate audio thread. A blocking FIFO
   write there throttles emulation to the FIFO's drain rate. Commit 4 must open
   the FIFO `O_NONBLOCK` and drop on full; the frame limiter stays
   `fs_emu_wait_for_frame`-equivalent or a plain monotonic pacer, never the FIFO.
5. **Frame-limiter replacement.** Dropping libfsemu drops
   `fs_emu_wait_for_frame()` (`src/fs-uae/main.c:360`). Commit 2 needs its own
   pacer from `currprefs.chipset_refreshrate` (already surfaced on
   `rd->refresh_rate`, `src/od-fs/video.cpp:243-247`), or the guest free-runs.
6. **Single-injector rule.** As with mamectl/1: a station launched with
   `FSUAE_NATIVE_CTL_SOCK` must not also have the Xvfb/XTEST path armed.

### If commit 3 walls

Fall back to **libretro-uae** (the only real alternative), accepting four golden
re-bakes; use Copperline's `copperline-ctl` JSON-RPC only as protocol
inspiration, never as a core swap.

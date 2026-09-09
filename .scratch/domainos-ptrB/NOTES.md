# Racer B: domainos pointer wall, theory B (ctlsock module field-writing)

Hard-stop reached before a framebuffer proof completed (boot-to-DM takes
~190s wall/emulated time; the autoboot Lua script's login-timing guess of
t0+118s was too aggressive and the drive phase never got observed before
the 25-minute clock ran out).

## What IS proven, from source (ctlsock.cpp in this checkout):

`scripts/build-guests/emulators/mamectl/src/osd/modules/ctlsock/ctlsock.cpp`
around line 1230-1264, the MOVE/MOVEP relative-count path:

    m_mx = ((m_mx + dx) % 65536 + 65536) % 65536;
    m_my = ((m_my + dy) % 65536 + 65536) % 65536;
    m_x_field->set_value(u32(m_mx));
    m_y_field->set_value(u32(m_my));
    // analog path: set_value lands in m_adjoverride and the very next
    // ioport read returns it -- no re-latch needed (design section 2)

Contrast with the KEY verb path (~line 1580), which DOES re-latch:

    f->set_value(u32(e.val));
    pt->frame_update();  // mid-frame re-latch (V6-proven on the
                          // button port; kbd matrix re-checked)

The MOVE path's comment ASSERTS no re-latch is needed for analog fields,
but never proves it for THIS device: the Apollo mouse ports
(apollo_kbd.cpp mouse2/mouse3) are 8-bit RELATIVE fields
(IPT_MOUSE_X/Y, PORT_SENSITIVITY(50)) read by the guest's own delta logic
(`dx = x - m_last_x`) on an ad-hoc 5ms-poll/50ms-self-block schedule, NOT
a standard analog control read every frame. `set_value` writes a 16-bit
accumulator value into an 8-bit-masked field with NO frame_update() call
-- if the device's read() happens on a timer callback rather than through
MAME's normal ioport polling cycle, `m_adjoverride` may never be
consulted before the device's own read timer fires and moves on, or the
value may already have been overwritten by the next MOVE before the
device ever samples it. This is consistent with the observed symptom:
applied= counts accumulate correctly (the ctlsock accounting is fine) but
nothing moves on screen (the guest device never actually samples the
override).

## Next step (what I could not finish)

Rerun this exact Lua approach (mousetest-autoboot.lua) with corrected
timing (wait ~195s emulated, not 118s, before posting the login) OR drive
the login via natkeyboard immediately and just wait longer before the
drive phase; then compare:
  (a) Lua's plain field:set_value() walking +20/100ms (bypassing ctlsock
      entirely, calling frame_update() after each set_value as an extra
      experiment) against
  (b) the identical values WITHOUT frame_update()
on the SAME rig, using fbdiff.py bbox before/after each burst. If (a)
moves the cursor and (b) does not, the fix is one line: call
pt->frame_update() after set_value() in the ctlsock MOVE/MOVEP path
(mirroring the KEY verb), and possibly for m_x_field/m_y_field's owning
port specifically -- NOT a rebuild-and-hope, a one-line change to test on
a clone first.

VERDICT: **INCONCLUSIVE within the 25-minute budget** -- no framebuffer
evidence gathered. Source review is suggestive of (a) (module bug: missing
frame_update() after set_value on the analog mouse fields) but this is
NOT the "no rebuild, cheap decisive test" proof the brief required. Rig
was torn down clean (pid 1682259 killed and confirmed gone, tailfwd
pid already exited) before this could be re-run.

// ============================================================================
//  input/mouseChord — a MOUSE's buttons, sent as one wire edge per changed bit.
//  ---------------------------------------------------------------------------
//  Pointer Events fire `pointerdown` only for the FIRST button of a pointer and
//  `pointerup` only for the LAST. Every button change in between — the right
//  button pressed while left is held, either one released while the other is
//  still down — arrives as a `pointermove` whose `button` is not -1 and whose
//  `buttons` mask has changed ("chorded buttons"). A handler that reads buttons
//  only from down/up events loses all of them: before this module the second
//  button of a chord never reached the guest, and the Minesweeper L+R chord
//  became a flag or a plain left click (job MB, 2026-09-28, proven on the
//  win98se framebuffer; the daemon and QEMU already carried a hand-made chord).
//
//  So the edges come from the MASK, not from the event type: every pointer
//  event of an open mouse contact diffs `buttons` against what was sent and
//  emits one edge per changed bit, in bit order (left, right, middle), at that
//  event's point. The wire is already per-button down/up (type-2 records on the
//  ordered button stream), so nothing downstream changes.
//
//  A contact opens at the pointer's first `pointerdown` ON the picture, so a
//  drag that began elsewhere never presses a guest button by sliding in. A
//  button that a lifecycle flush released behind our back (blur, hidden tab,
//  pointer-lock exit, inputSuspended — all of which empty `pressed`) is DEAD
//  until the hand actually lets go of it: a stale mask on the next move must not
//  press it again under a guest that was just told it is up.
//
//  Mouse only. A pen keeps its own single-button + barrel path (penContact,
//  penRightClick) and a finger has the touch recognizer; neither chords.
// ============================================================================
import type { StreamControlHandle } from '../three/useStreamControl';

/** DOM `buttons` bit → wire button (0 = left, 1 = middle, 2 = right), in the
 *  order a multi-bit change is emitted. Back/forward (8/16) are not sent: the
 *  daemon reads wire buttons 3/4 as the wheel. */
const BITS: ReadonlyArray<readonly [dom: number, wire: number]> = [[1, 0], [2, 2], [4, 1]];
const MASK = 7;

/** DOM `button` (the one that changed) → its `buttons` bit. */
function bitOf(button: number): number {
  return button === 0 ? 1 : button === 1 ? 4 : button === 2 ? 2 : 0;
}

interface Contact { sent: number; dead: number }
type Ev = Pick<PointerEvent, 'pointerId' | 'button' | 'buttons'>;
type Send = StreamControlHandle['sendMouseButton'];

export class MouseChord {
  private readonly contacts = new Map<number, Contact>();

  constructor(private readonly send: Send, private readonly pressed: Set<number>) {}

  /** `pointerdown`: open the contact (or continue it) and press what is held.
   *  The event's own button counts as held even if a UA leaves it out of
   *  `buttons`. */
  down(e: Ev, x?: number, y?: number): void {
    let c = this.contacts.get(e.pointerId);
    if (!c) { c = { sent: 0, dead: 0 }; this.contacts.set(e.pointerId, c); }
    this.apply(c, e.buttons | bitOf(e.button), x, y);
  }

  /** `pointermove` / `pointerrawupdate`: the chorded-button edges. A pointer with
   *  no open contact is plain motion and sends nothing. */
  move(e: Ev, x?: number, y?: number): void {
    const c = this.contacts.get(e.pointerId);
    if (c) this.apply(c, e.buttons, x, y);
  }

  /** `pointerup` releases what is no longer held (the event's own button always);
   *  `pointercancel` releases everything. The contact closes once nothing is. */
  up(e: Ev & { type: string }, x?: number, y?: number): void {
    const c = this.contacts.get(e.pointerId);
    if (!c) return;
    const held = e.type === 'pointercancel' ? 0 : e.buttons & ~bitOf(e.button);
    this.apply(c, held, x, y);
    if ((held & MASK) === 0) this.contacts.delete(e.pointerId);
  }

  /** Capture lost mid-contact: release every bit this pointer still holds and
   *  close it, so no later event of that press can reach the guest. */
  lost(pointerId: number, x?: number, y?: number): void {
    const c = this.contacts.get(pointerId);
    if (!c) return;
    this.apply(c, 0, x, y);
    this.contacts.delete(pointerId);
  }

  private apply(c: Contact, buttons: number, x?: number, y?: number): void {
    // Bits a lifecycle flush released without us become dead (see header).
    for (const [bit, wire] of BITS) {
      if ((c.sent & bit) && !this.pressed.has(wire)) { c.sent &= ~bit; c.dead |= bit; }
    }
    c.dead &= buttons;
    const target = buttons & MASK & ~c.dead;
    const changed = target ^ c.sent;
    for (const [bit, wire] of BITS) {
      if (!(changed & bit)) continue;
      const down = (target & bit) !== 0;
      if (down) this.pressed.add(wire); else this.pressed.delete(wire);
      this.send(wire, down, x, y);
    }
    c.sent = target;
  }
}

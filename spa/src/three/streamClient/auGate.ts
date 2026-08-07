// ============================================================================
//  streamClient/auGate — pure decode-feed gate logic for feedVideoAU:
//    - stale/out-of-order AU rejection (per-AU uni streams complete in
//      retransmit order, not frame_id order)
//    - the frame_id-gap → wait-for-keyframe state machine
//  Kept free of VideoDecoder/StreamClient state so vitest drives it under
//  plain Node.
// ============================================================================

/** True for a non-key AU at or behind the newest frame_id already seen — a
 *  retransmit-delayed delta whose reference chain has moved on. Keys always
 *  pass: an IDR resets the reference chain, so decoding one is always safe
 *  (and self-heals any frame_id discontinuity after an encoder reopen). */
export function isStaleAu(lastFrameId: number, frameId: number, isKey: boolean): boolean {
  return lastFrameId >= 0 && frameId <= lastFrameId && !isKey;
}

/** Gap→keyframe gate: after a frame_id gap the missing AUs are this stream's
 *  reference frames — feeding further deltas would paint reference-corrupted
 *  "partial updates" until the next IDR. Freeze on the last clean frame
 *  instead: arm on gap, drop non-keys while armed, clear on any key. */
export class VideoAuGate {
  private awaitingKey = false;

  /** Arm the gate: a frame_id gap was observed (references lost in transit). */
  noteGap(): void {
    this.awaitingKey = true;
  }

  /** May this AU be decoded? Keys always pass and clear the gate. */
  admit(isKey: boolean): boolean {
    if (isKey) {
      this.awaitingKey = false;
      return true;
    }
    return !this.awaitingKey;
  }
}

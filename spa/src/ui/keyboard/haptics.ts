// Haptic feedback via the Vibration API — present on Chrome/Android, silently
// absent elsewhere (iOS Safari has no navigator.vibrate). Used for BOTH on-screen
// keys and the pointer clicks we forward to the guest, so a key and a click feel
// alike. The body sits in try/catch because a UA that lacks the API is not the
// only failure mode worth surviving, and feedback must never break sending.
//
// There is no mute preference any more: the ⋯ menu row that set it is gone
// (2026-08-05), and a preference nothing can clear is worse than none — a stale
// 'off' would silently kill every pulse with no way back.

export function hapticTap(ms = 10): void {
  try {
    navigator.vibrate?.(ms);
  } catch { /* API absent */ }
}

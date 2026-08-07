// One-time touch coachmark seen-flag. Same defensive try/catch shape as
// ui/keyboard/haptics.ts: with site data blocked even READING localStorage
// throws, and that must never break the view — a storage failure is treated as
// "already seen" so a user who can't persist the flag is never nagged again.

const COACH_KEY = 'sv.coach';

export function coachSeen(): boolean {
  try {
    return localStorage.getItem(COACH_KEY) === '1';
  } catch {
    return true; // storage blocked → treat as seen (never nag)
  }
}

export function markCoachSeen(): void {
  try {
    localStorage.setItem(COACH_KEY, '1');
  } catch { /* storage blocked — the flag just doesn't persist */ }
}

// lib/safety.mjs — every disruptive or account-creating action the tool can
// take goes through one gate here, so the caps described in the tool's own
// --help are actually the caps enforced, not just documented intentions.
//
// This traffic crosses the public edge (a loopback-bound listener behind a
// forwarder — docs/PUBLIC-GALLERY.md) and lands on one physical box already
// running ~71 emulated guests. Nothing in this module is about being polite;
// it is about not being the incident.

/** Simple counting semaphore for concurrent visitor contexts. */
export class Semaphore {
  #free;
  #queue = [];
  constructor(n) {
    this.#free = n;
  }
  async acquire() {
    if (this.#free > 0) {
      this.#free--;
      return;
    }
    await new Promise((resolve) => this.#queue.push(resolve));
  }
  release() {
    const next = this.#queue.shift();
    if (next) next();
    else this.#free++;
  }
}

/** Consecutive-failure circuit breaker: "fail loudly and stop on repeated
 *  errors rather than hammering a broken gallery." Any success resets it. */
export class FailureBreaker {
  #consecutive = 0;
  #tripped = false;
  constructor(limit = 5) {
    this.limit = limit;
  }
  ok() {
    this.#consecutive = 0;
  }
  fail(reason) {
    this.#consecutive++;
    if (this.#consecutive >= this.limit) {
      this.#tripped = true;
      this.tripReason = reason;
    }
    return this.#tripped;
  }
  get tripped() {
    return this.#tripped;
  }
}

/** Golden-reset gate: OFF unless explicitly armed, capped for the whole run,
 *  and rate-limited per station so one run cannot recapture-worthy-thrash a
 *  station that is mid-visit for someone real. */
export class ResetGate {
  #lastAt = new Map();
  #count = 0;
  constructor({ allowed = false, maxTotal = 1, minIntervalMs = 30 * 60 * 1000 } = {}) {
    this.allowed = allowed;
    this.maxTotal = maxTotal;
    this.minIntervalMs = minIntervalMs;
  }
  /** May a reset of `station` happen right now? Does NOT record one — the
   *  caller records via `record()` only after the request actually went out,
   *  so a decision to skip never consumes budget. */
  eligible(station) {
    if (!this.allowed) return false;
    if (this.#count >= this.maxTotal) return false;
    const last = this.#lastAt.get(station) ?? 0;
    return Date.now() - last >= this.minIntervalMs;
  }
  record(station) {
    this.#count++;
    this.#lastAt.set(station, Date.now());
  }
  get count() {
    return this.#count;
  }
}

/** Walk-in signup gate: real passkey accounts, capped for the whole run. */
export class WalkinSignupGate {
  #count = 0;
  constructor({ maxTotal = 1 } = {}) {
    this.maxTotal = maxTotal;
  }
  eligible() {
    return this.#count < this.maxTotal;
  }
  record() {
    this.#count++;
  }
  get count() {
    return this.#count;
  }
}

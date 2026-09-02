// lib/bannerWatch.mjs — watch a station tab's CONNECTION BANNER and PHASE
// OVERLAY, log every transition, and (optionally) photograph each one.
//
// WHY THIS EXISTS. The operator sees "Spotty connection" and "Reconnecting to
// tile…" banners on a 4 ms LAN, and the log plane cannot prove them: the
// streamhost telemetry line (spa/src/three/streamClient/telemetry.ts) is
// emitted once per 5 s, so a 2–5 s spotty dwell can begin and end between two
// consecutive T-lines and leave `good` on both. The only witness of what the
// visitor actually saw is the pixels, which is the same reasoning as AGENTS.md
// rule 9 ("the framebuffer is the only proof"). So: sample the DOM inside the
// page, record the transition with its own timestamp, and let the node side
// take the picture.
//
// WHY TEXT MATCHING, NOT SELECTORS. Every one of these overlays is styled with
// INLINE styles from StreamView/styles.ts — the banner, the chip stack and the
// spinner overlay carry no class, id or data-testid between them. The words
// themselves are the only stable hook, and they are pure derivations
// (bannerCopy.ts, exitReason.ts, useStreamhostSession.ts's setMessage calls),
// so this file mirrors those strings and nothing else. No SPA change was
// needed, and none was made — which also keeps this tool off the toes of
// anyone editing the SPA.
//
// WHY THE SAMPLER RUNS IN-PAGE. A node-side poll can only see the state at the
// instant it asks; a 250 ms poll across six tabs would miss a banner that
// flashes between two asks and would also mis-time the ones it caught by up to
// a poll interval. The in-page interval samples on its own clock and QUEUES
// transitions; node drains the queue, so the timestamps are the page's and the
// screenshot lag is visible in the record rather than hidden in it.

import fs from 'node:fs';
import path from 'node:path';

// The words, in the three families the operator's report mixes together.
// Kept as source strings (not RegExp) so the whole set survives the
// structured-clone into the page.
const PHASE_WORDS = [
  'Reconnecting to restored tile…',
  'Reconnecting to tile…',
  'Reconnecting WebRTC…',
  'Restoring tile…',
  'Waiting for desktop…',
  'Connecting…',
];
const BANNER_WORDS = [
  'Spotty connection',
  'Device under load',
  'Reconnecting…',
  'Restoring…',
  'Session closed by you',
  'Session ended — connection lost',
  'Session ended — the tile stopped responding',
  'Session ended — the video stream stalled',
  'Session paused — this device went to sleep',
  'Session ended — the exhibit closed the stream',
  "This browser can't play the live stream",
];
const CHIP_WORDS = [
  'No video · stream stalled',
  'No video · decoder failing',
  'Device under load',
  'Low battery',
];

/** Installed into the page. Samples the three overlay families every
 *  `intervalMs` and pushes a record whenever the composite state changes.
 *  Self-contained: no imports, no closures over module scope. */
function installSampler({ phaseWords, bannerWords, chipWords, intervalMs }) {
  if (window.__khBannerWatch) return 'already';
  const state = { queue: [], last: null, startedAt: Date.now() };
  window.__khBannerWatch = state;

  const hit = (text, words) => words.find((w) => text.includes(w)) ?? null;

  const sample = () => {
    // Text nodes only — the overlays put their copy in bare text nodes beside
    // a styled dot span, so this is both the cheapest walk and the exact one.
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let phase = null;
    let banner = null;
    const chips = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const raw = n.nodeValue;
      if (!raw) continue;
      const text = raw.trim();
      if (text.length < 5) continue;
      const p = hit(text, phaseWords);
      if (p) {
        // Keep the FULL text, so "(attempt 3)" / "(2/4)" survives.
        if (!phase) phase = text;
        continue;
      }
      const b = hit(text, bannerWords);
      const c = hit(text, chipWords);
      if (!b && !c) continue;
      // "Device under load" is the one string that is BOTH a banner and a
      // chip. They never share a place on the stage: the banner is centred
      // (styles.ts `banner`: left 50%, translateX(-50%)) and the chip stack is
      // pinned to the top-right (`chipStack`). Ask the box, not the words.
      let right = false;
      const el = n.parentElement;
      if (el) {
        const r = el.getBoundingClientRect();
        const w = window.innerWidth || 1;
        right = r.width > 0 && (r.left + r.width / 2) / w > 0.72;
      }
      if (c && (right || !b)) chips.push(text);
      else if (b) banner = text;
    }
    chips.sort();
    const sig = JSON.stringify([banner, phase, chips]);
    if (sig === state.last) return;
    state.last = sig;
    state.queue.push({ at: Date.now(), banner, phase, chips, url: location.pathname });
    if (state.queue.length > 500) state.queue.splice(0, state.queue.length - 500);
  };

  state.timer = window.setInterval(sample, intervalMs);
  sample();
  return 'installed';
}

/** A file-name-safe token for the composite state, used in the shot name. */
export function stateSlug({ banner, phase, chips }) {
  const parts = [];
  if (banner) parts.push(`b-${banner}`);
  if (phase) parts.push(`p-${phase}`);
  for (const c of chips) parts.push(`c-${c}`);
  if (parts.length === 0) return 'none';
  return parts
    .join('+')
    .replace(/…/g, '')
    .replace(/[^A-Za-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 70)
    .toLowerCase();
}

/** One line for the sim log, in the shape the brief asked for:
 *  `banner <station> +<elapsed>s: "<text>"` — "(none)" when everything cleared. */
export function bannerLine(station, elapsedMs, ev) {
  const bits = [ev.banner, ev.phase, ...(ev.chips ?? [])].filter(Boolean);
  const text = bits.length ? bits.join(' | ') : '(none)';
  return `banner ${station} +${(elapsedMs / 1000).toFixed(1)}s: "${text}"`;
}

const stationOf = (page) => {
  const m = /\/(?:os|walkin\/play)\/([A-Za-z0-9_-]+)/.exec(page.url());
  return m ? m[1] : 'nostation';
};

/**
 * Start watching `page`. Returns a handle with `stop()` (which drains one last
 * time) and the accumulated `timeline`.
 *
 * Absent `shotsDir` this still logs and records the timeline and takes no
 * pictures at all — the watch is the evidence, the shots are the proof.
 */
export function startBannerWatch(page, {
  visitorId,
  shotsDir = null,
  log = () => {},
  sampleMs = 250,
  pollMs = 250,
  periodicMs = 5000,
} = {}) {
  const t0 = Date.now();
  const timeline = [];
  const vis = `v${visitorId}`;
  let stopped = false;
  let lastPeriodic = 0;
  let shotSeq = 0;
  if (shotsDir) fs.mkdirSync(shotsDir, { recursive: true });

  const payload = {
    phaseWords: PHASE_WORDS,
    bannerWords: BANNER_WORDS,
    chipWords: CHIP_WORDS,
    intervalMs: sampleMs,
  };
  // Re-applied on every navigation (the SPA is client-routed, but a hard
  // reload would otherwise silently end the watch), plus once now for the
  // document that is already loaded.
  const armed = page.addInitScript(installSampler, payload).catch(() => {});

  async function shoot(ev, elapsedMs, kind) {
    if (!shotsDir) return null;
    const station = stationOf(page);
    const name = `${vis}-${station}-${String(elapsedMs).padStart(6, '0')}-${stateSlug(ev)}.png`;
    const file = path.join(shotsDir, name);
    try {
      await page.screenshot({ path: file, timeout: 8000 });
      shotSeq++;
      return { file, kind };
    } catch (err) {
      log(`banner: screenshot failed (${String(err).split('\n')[0]})`);
      return null;
    }
  }

  async function drain() {
    let evs = [];
    try {
      evs = await page.evaluate(() => {
        const s = window.__khBannerWatch;
        if (!s) return null;
        return s.queue.splice(0, s.queue.length);
      });
    } catch {
      return; // navigation in flight, or the page is gone
    }
    if (evs === null) {
      // A hard reload landed before addInitScript could re-arm, or the very
      // first evaluate beat the arming — install it directly.
      await page.evaluate(installSampler, payload).catch(() => {});
      return;
    }
    for (const ev of evs) {
      const elapsed = ev.at - t0;
      const station = stationOf(page);
      log(bannerLine(station, elapsed, ev));
      const shot = await shoot(ev, elapsed, 'transition');
      timeline.push({
        visitorId,
        station,
        atMs: ev.at,
        at: new Date(ev.at).toISOString(),
        elapsedMs: elapsed,
        kind: 'transition',
        banner: ev.banner,
        phase: ev.phase,
        chips: ev.chips,
        shot: shot ? path.basename(shot.file) : null,
      });
    }
  }

  async function periodic() {
    if (!shotsDir) return;
    const now = Date.now();
    if (now - lastPeriodic < periodicMs) return;
    lastPeriodic = now;
    let cur = { banner: null, phase: null, chips: [] };
    try {
      const s = await page.evaluate(() => {
        const st = window.__khBannerWatch;
        if (!st || !st.last) return null;
        const [banner, phase, chips] = JSON.parse(st.last);
        return { banner, phase, chips };
      });
      if (s) cur = s;
    } catch {
      /* mid-navigation — photograph it anyway, state unknown */
    }
    const elapsed = now - t0;
    const shot = await shoot(cur, elapsed, 'periodic');
    if (shot) {
      timeline.push({
        visitorId,
        station: stationOf(page),
        atMs: now,
        at: new Date(now).toISOString(),
        elapsedMs: elapsed,
        kind: 'periodic',
        banner: cur.banner,
        phase: cur.phase,
        chips: cur.chips ?? [],
        shot: path.basename(shot.file),
      });
    }
  }

  const loop = (async () => {
    await armed;
    await page.evaluate(installSampler, payload).catch(() => {});
    while (!stopped) {
      await drain();
      await periodic();
      await new Promise((r) => setTimeout(r, pollMs));
    }
    await drain();
  })();

  return {
    timeline,
    get shotCount() {
      return shotSeq;
    },
    async stop() {
      stopped = true;
      await loop.catch(() => {});
      return timeline;
    },
  };
}

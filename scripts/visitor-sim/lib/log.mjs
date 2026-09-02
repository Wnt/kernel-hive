// lib/log.mjs — console trace + the run manifest the operator uses for
// cleanup. Nothing here is analytics; it is this TOOL's own accounting of
// what it did, kept locally, never sent anywhere.

import fs from 'node:fs';
import path from 'node:path';

export function nowStamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

export function log(tag, msg) {
  const t = new Date().toISOString().slice(11, 19);
  process.stdout.write(`[${t}] [${tag}] ${msg}\n`);
}

/** Accumulates what the run did, and writes it to a JSON file the operator can
 *  read to know what needs cleaning up: which stations were reset, and — the
 *  one that matters most — the handles of every walk-in account this run
 *  created, so they can be found in /admin and removed. See
 *  docs/lab/VISITOR-SIM.md "What this creates, and how to clean it up". */
export class RunManifest {
  constructor(config) {
    this.startedAt = new Date().toISOString();
    this.config = config;
    this.visitors = [];
    this.resets = [];
    this.walkinAccounts = [];
    this.errors = [];
    // Every connection-banner / phase-overlay transition every watched tab
    // went through, in wall-clock order across all visitors — the record the
    // 5s telemetry line cannot hold (see lib/bannerWatch.mjs's header).
    this.bannerTimeline = [];
  }

  visitor(entry) {
    this.visitors.push(entry);
  }

  reset(station) {
    this.resets.push({ station, at: new Date().toISOString() });
  }

  walkinAccount({ handle, station, visitorId }) {
    this.walkinAccounts.push({ handle, station, visitorId, at: new Date().toISOString() });
  }

  banner(entries) {
    for (const e of entries) this.bannerTimeline.push(e);
    this.bannerTimeline.sort((a, b) => a.atMs - b.atMs);
  }

  error(entry) {
    this.errors.push({ ...entry, at: new Date().toISOString() });
  }

  /** Visitor entries whose journey reported ok:false — a FAILED journey that
   *  returned normally (a station that never streamed, a card that was never
   *  found) rather than throwing. `errors` above is exceptions ONLY (the
   *  catch block in visitor-sim.mjs); a run can fail a sixth of its journeys
   *  and throw zero exceptions, so the two counts must never be conflated in
   *  a summary line — see docs/lab/VISITOR-SIM.md "DEFECT 3". */
  get failedVisitors() {
    return this.visitors.filter((v) => v.ok === false);
  }

  write(outDir) {
    fs.mkdirSync(outDir, { recursive: true });
    const file = path.join(outDir, `run-${nowStamp()}.json`);
    this.finishedAt = new Date().toISOString();
    // `failedVisitors` is a getter (prototype accessor), which
    // JSON.stringify's own-enumerable-property walk skips — materialize it as
    // an own field so the manifest on disk actually carries the failure list,
    // not just this in-process object.
    this.failedVisitorCount = this.failedVisitors.length;
    fs.writeFileSync(file, JSON.stringify(this, null, 2));
    return file;
  }
}

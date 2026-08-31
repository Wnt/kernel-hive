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

  error(entry) {
    this.errors.push({ ...entry, at: new Date().toISOString() });
  }

  write(outDir) {
    fs.mkdirSync(outDir, { recursive: true });
    const file = path.join(outDir, `run-${nowStamp()}.json`);
    this.finishedAt = new Date().toISOString();
    fs.writeFileSync(file, JSON.stringify(this, null, 2));
    return file;
  }
}

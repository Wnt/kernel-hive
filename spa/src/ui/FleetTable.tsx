import { useMemo, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { useFleetTable, type FleetEntry } from '../data/fleetTable';
import './FleetTable.css';

// Operator-facing fleet table: every lineup entry, one row, with the facts the
// registry can answer about HOW it runs (tier, emulator, kiosk, I/O paths,
// memory, idle-pause, golden scene). Data is /fleet-table.json — see
// scripts/stations_registry/fleet_table.py for every derivation rule.

type SortKey =
  | 'name' | 'year' | 'tier' | 'emulator' | 'kiosk' | 'arch' | 'lineage'
  | 'memory' | 'accel' | 'capture' | 'keyboard' | 'pointer' | 'idle' | 'golden' | 'stream';

interface Column {
  key: SortKey;
  label: string;
  title: string;
  sort: (e: FleetEntry) => string | number;
  render: (e: FleetEntry) => ReactNode;
}

const dash = <span className="fleet-dash">—</span>;
const num = (v: number | null | undefined, unit: string) => (v == null ? '' : `${v} ${unit}`);

function ram(e: FleetEntry): string {
  if (e.guestRamKB != null && !e.guestRamMB) return `${e.guestRamKB} KB`;
  return num(e.guestRamMB, 'MB');
}

const COLUMNS: Column[] = [
  {
    key: 'name', label: 'Station', title: 'displayName / registry id',
    sort: (e) => e.displayName.toLowerCase(),
    render: (e) => (
      <>
        <Link to={`/os/${e.id}`} className="fleet-name">{e.displayName}</Link>
        <span className="fleet-id">{e.id}{e.slot != null ? ` · slot ${e.slot}` : ''}</span>
        {!e.listed && <span className="fleet-badge fleet-badge--muted">{e.lifecycle === 'showcase' ? 'poster' : 'hidden'}</span>}
      </>
    ),
  },
  { key: 'year', label: 'Year', title: 'museum.year', sort: (e) => e.year, render: (e) => e.year },
  {
    key: 'tier', label: 'Tier', title: 'Derived per docs/GUEST-TIERS.md',
    sort: (e) => e.tier,
    render: (e) => <span className={`fleet-badge fleet-tier-${e.tier}`} title={e.tierLabel}>T{e.tier} · {e.tierLabel}</span>,
  },
  {
    key: 'emulator', label: 'Emulator', title: 'registry emulator {family, version, driver}; hover for the pin source',
    sort: (e) => `${e.emulator?.family ?? ''} ${e.emulator?.version ?? ''}`.toLowerCase(),
    render: (e) => e.emulator ? (
      <span title={e.emulator.source}>
        <strong>{e.emulator.family}</strong>{' '}
        {e.emulator.version ?? <span className="fleet-badge fleet-badge--warn" title="no version pinned anywhere in the repo">version not recorded</span>}
        {e.emulator.driver && <span className="fleet-sub">{e.emulator.driver}</span>}
      </span>
    ) : dash,
  },
  {
    key: 'kiosk', label: 'Kiosk', title: 'Emulator inside a captured Linux VM? (registry/bridge-suites.json)',
    sort: (e) => (e.kiosk ? `1 ${e.kiosk.suite}` : '0'),
    render: (e) => e.kiosk ? (
      <span title={e.kiosk.kind}>
        <span className="fleet-badge fleet-badge--warn">kiosk</span> {e.kiosk.distro}
      </span>
    ) : <span className="fleet-muted">no</span>,
  },
  { key: 'arch', label: 'CPU / arch', title: 'museum.arch', sort: (e) => (e.arch ?? '').toLowerCase(), render: (e) => e.arch ?? dash },
  { key: 'lineage', label: 'Lineage / vendor', title: 'museum.lineage', sort: (e) => (e.lineage ?? '').toLowerCase(), render: (e) => e.lineage ?? dash },
  {
    key: 'memory', label: 'Memory', title: 'guest machine RAM (museum.ramMB) / QEMU VM -m (runtime.qemu.memoryMB)',
    sort: (e) => e.machine.vmMemoryMB ?? e.guestRamMB ?? 0,
    render: (e) => (
      <>
        {ram(e) || dash}
        {e.machine.vmMemoryMB != null && (
          <span className="fleet-sub" title={e.machine.role ?? 'QEMU -m'}>VM {e.machine.vmMemoryMB} MB{e.machine.role ? ' (kiosk)' : ''}</span>
        )}
      </>
    ),
  },
  {
    key: 'accel', label: 'QEMU / accel', title: 'runtime.qemu binary, machine, accel — or the x11 launcher geometry',
    sort: (e) => `${e.machine.accel ?? 'zz'} ${e.machine.qemuBinary ?? ''}`,
    render: (e) => e.machine.qemuBinary ? (
      <>
        <span className={`fleet-badge ${e.machine.accel === 'kvm' ? 'fleet-badge--ok' : 'fleet-badge--warn'}`}>{e.machine.accel}</span>{' '}
        <span title={e.machine.qemuMachine ?? ''}>{e.machine.qemuBinary.split('/').pop()}</span>
        {e.machine.qemuBinary.includes('/') && <span className="fleet-sub">{e.machine.qemuBinary}</span>}
      </>
    ) : e.machine.geometry ? (
      <><span className="fleet-muted">no QEMU</span><span className="fleet-sub">{e.machine.geometry}</span></>
    ) : dash,
  },
  { key: 'capture', label: 'Capture', title: 'frame source: dbus (QEMU display) / shm (emulator publishes) / x11', sort: (e) => e.capture ?? 'zz', render: (e) => e.capture ?? dash },
  { key: 'keyboard', label: 'Keyboard path', title: 'how a key reaches the guest; hover for pacing', sort: (e) => e.keyboardPath ?? 'zz',
    render: (e) => e.keyboardPath ? (
      <span title={e.keyPacingMs ? `hold ${e.keyPacingMs.holdMs} ms / gap ${e.keyPacingMs.gapMs} ms` : 'default pacing'}>
        {e.keyboardPath}
        {e.keyPacingMs && <span className="fleet-sub">{e.keyPacingMs.holdMs}/{e.keyPacingMs.gapMs} ms</span>}
      </span>
    ) : dash },
  {
    key: 'pointer', label: 'Pointer path', title: 'stream.pointer method · abs/rel · backend',
    sort: (e) => (e.pointer.present ? `${e.pointer.method}` : 'zz'),
    render: (e) => e.pointer.present ? (
      <>
        {e.pointer.method}{' '}
        <span className="fleet-badge fleet-badge--muted">{e.pointer.absolute ? 'abs' : 'rel'}</span>
        <span className="fleet-sub">
          {[e.pointer.device, e.pointer.backend, e.pointer.via, e.pointer.buttons && `buttons: ${e.pointer.buttons}`, e.pointer.scale && e.pointer.scale !== 1 ? `×${e.pointer.scale}` : null]
            .filter(Boolean).join(' · ')}
        </span>
      </>
    ) : <span className="fleet-muted">{e.pointer.method === 'none' && e.tier !== 5 ? 'none (keyboard-only)' : '—'}</span>,
  },
  {
    key: 'idle', label: 'Idle auto-pause', title: 'SH_IDLE_PAUSE_SECS (daemon default 60; 0 = off)',
    sort: (e) => e.idlePauseSecs ?? -1,
    render: (e) => e.idlePauseSecs == null ? dash : e.idlePauseSecs === 0
      ? <span className="fleet-badge fleet-badge--warn">off</span>
      : <span className="fleet-badge fleet-badge--ok">{e.idlePauseSecs} s</span>,
  },
  {
    key: 'golden', label: 'Golden scene', title: 'reset.resetMode / snapshot: how "restore to golden" works',
    sort: (e) => (e.golden ? `${e.golden.instant ? 0 : 1} ${e.golden.resetMode}` : 'zz'),
    render: (e) => e.golden ? (
      <span title={e.golden.kind ?? ''}>
        <span className={`fleet-badge ${e.golden.instant ? 'fleet-badge--ok' : 'fleet-badge--muted'}`}>{e.golden.resetMode}</span>
        {e.golden.snapshot && <span className="fleet-sub">{e.golden.snapshot}</span>}
      </span>
    ) : dash,
  },
  {
    key: 'stream', label: 'Stream', title: 'fps · audio (source) · labctl exec channel',
    sort: (e) => e.fps ?? 0,
    render: (e) => e.fps == null ? dash : (
      <>
        {e.fps} fps{e.audio ? ` · audio (${e.audioSource})` : ' · silent'}
        {e.execKind && <span className="fleet-sub">exec: {e.execKind}</span>}
      </>
    ),
  },
];

function matches(e: FleetEntry, q: string): boolean {
  if (!q) return true;
  const hay = [
    e.id, e.displayName, e.arch, e.lineage, e.tierLabel, e.emulator?.family, e.emulator?.version, e.emulator?.driver,
    e.kiosk?.distro, e.machine.qemuBinary, e.machine.accel, e.capture, e.keyboardPath, e.pointer.method, e.pointer.backend,
    e.golden?.resetMode,
  ].filter(Boolean).join(' ').toLowerCase();
  return q.split(/\s+/).every((word) => hay.includes(word));
}

export function FleetTable() {
  const doc = useFleetTable();
  const [query, setQuery] = useState('');
  const [tiers, setTiers] = useState<Set<number>>(new Set());
  const [sortKey, setSortKey] = useState<SortKey>('year');
  const [sortDir, setSortDir] = useState<1 | -1>(1);

  const rows = useMemo(() => {
    if (!doc) return [];
    const q = query.trim().toLowerCase();
    const col = COLUMNS.find((c) => c.key === sortKey) ?? COLUMNS[0];
    return doc.entries
      .filter((e) => (tiers.size === 0 || tiers.has(e.tier)) && matches(e, q))
      .sort((a, b) => {
        const av = col.sort(a), bv = col.sort(b);
        const cmp = typeof av === 'number' && typeof bv === 'number' ? av - bv : String(av).localeCompare(String(bv));
        return (cmp || a.year - b.year || a.id.localeCompare(b.id)) * sortDir;
      });
  }, [doc, query, tiers, sortKey, sortDir]);

  const onSort = (key: SortKey) => {
    if (key === sortKey) setSortDir((d) => (d === 1 ? -1 : 1));
    else { setSortKey(key); setSortDir(1); }
  };
  const toggleTier = (t: number) => setTiers((prev) => {
    const next = new Set(prev);
    if (next.has(t)) next.delete(t); else next.add(t);
    return next;
  });

  if (doc === undefined) return <div className="fleet-view"><p className="fleet-status">Loading fleet table…</p></div>;
  if (doc === null) {
    return (
      <div className="fleet-view">
        <p className="fleet-status">No fleet table published. Run <code>scripts/serve-https-spa.sh manifests</code> (it renders <code>fleet-table.json</code> from the registry).</p>
      </div>
    );
  }

  const tierCounts = new Map<number, number>();
  for (const e of doc.entries) tierCounts.set(e.tier, (tierCounts.get(e.tier) ?? 0) + 1);

  return (
    <div className="fleet-view">
      <div className="fleet-toolbar">
        <input
          type="search"
          className="fleet-search"
          placeholder="Filter: e.g. mame, kiosk, tcg, warpd, rel…"
          value={query}
          onChange={(ev) => setQuery(ev.target.value)}
          aria-label="Filter stations"
        />
        <div className="seg fleet-tiers" role="group" aria-label="Filter by tier">
          {[...tierCounts.entries()].sort(([a], [b]) => a - b).map(([t, n]) => (
            <button key={t} type="button" className={tiers.has(t) ? 'active' : ''} onClick={() => toggleTier(t)} title={doc.tierLabels[String(t)]}>
              T{t} <span className="fleet-count">{n}</span>
            </button>
          ))}
        </div>
        <span className="fleet-summary">{rows.length} / {doc.entries.length} stations</span>
      </div>
      <div className="fleet-scroll">
        <table className="fleet-table">
          <thead>
            <tr>
              {COLUMNS.map((c) => (
                <th key={c.key} scope="col" title={c.title} aria-sort={sortKey === c.key ? (sortDir === 1 ? 'ascending' : 'descending') : 'none'}>
                  <button type="button" className={`fleet-sort${sortKey === c.key ? ' active' : ''}`} onClick={() => onSort(c.key)}>
                    {c.label}{sortKey === c.key ? (sortDir === 1 ? ' ▲' : ' ▼') : ''}
                  </button>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((e) => (
              <tr key={e.id} className={e.listed ? '' : 'fleet-row--unlisted'}>
                {COLUMNS.map((c) => <td key={c.key} className={`fleet-col-${c.key}`}>{c.render(e)}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="fleet-footnote">
        Rendered from <code>registry/stations/*.json</code> + <code>registry/bridge-suites.json</code> by <code>stations-registry.py</code> (<code>fleet-table.json</code>).
        Tier is derived per <code>docs/GUEST-TIERS.md</code>; emulator family/version is the registry's <code>emulator</code> field. Hover a header or cell for the source of each value.
      </p>
    </div>
  );
}

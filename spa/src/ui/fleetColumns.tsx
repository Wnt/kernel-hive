import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import type { FleetEntry } from '../data/fleetTable';

// The /fleet columns. Each column knows how to RENDER a cell, how to SORT by
// it, and which FACET values it contributes for the header filter (a cell may
// contribute several — the pointer cell facets on abs/rel AND on method — and a
// row matches a facet if ANY of its values is chosen). Keep facet values short
// and stable: they are what the operator clicks.

export type ColKey =
  | 'name' | 'year' | 'tier' | 'emulator' | 'kiosk' | 'ui' | 'screen' | 'depth' | 'arch' | 'lineage'
  | 'memory' | 'accel' | 'capture' | 'keyboard' | 'pointer' | 'exec' | 'network' | 'idle' | 'golden' | 'stream';

export interface Column {
  key: ColKey;
  label: string;
  title: string;
  sort: (e: FleetEntry) => string | number;
  facet: (e: FleetEntry) => string[];
  render: (e: FleetEntry) => ReactNode;
}

const dash = <span className="fleet-dash">—</span>;
const num = (v: number | null | undefined, unit: string) => (v == null ? '' : `${v} ${unit}`);
const NET_ORDER: Record<string, number> = { internet: 0, 'host-only': 1, isolated: 2, 'nic-only': 3, none: 4 };
const NET_BADGE: Record<string, string> = {
  internet: 'fleet-badge--ok', 'host-only': 'fleet-badge--info', isolated: 'fleet-badge--warn', 'nic-only': 'fleet-badge--warn', none: 'fleet-badge--muted',
};
const UI_LABEL: Record<string, string> = {
  desktop: 'graphical desktop', 'text-console': 'text console', 'home-computer': 'home-computer prompt', mobile: 'mobile UI', other: 'other',
};

function ram(e: FleetEntry): string {
  if (e.guestRamKB != null && !e.guestRamMB) return `${e.guestRamKB} KB`;
  return num(e.guestRamMB, 'MB');
}
function ramBucket(e: FleetEntry): string {
  const mb = e.guestRamMB ?? (e.guestRamKB != null ? e.guestRamKB / 1024 : null);
  if (mb == null) return 'unknown';
  if (mb < 1) return '< 1 MB';
  if (mb <= 16) return '1–16 MB';
  if (mb <= 128) return '17–128 MB';
  if (mb <= 512) return '129–512 MB';
  return '> 512 MB';
}
const listing = (e: FleetEntry) => (e.lifecycle === 'showcase' ? 'poster' : e.listed ? 'listed' : 'hidden');

export const FLEET_COLUMNS: Column[] = [
  {
    key: 'name', label: 'Station', title: 'displayName / registry id · facet: listed / hidden / poster',
    sort: (e) => e.displayName.toLowerCase(),
    facet: (e) => [listing(e)],
    render: (e) => (
      <>
        <Link to={`/os/${e.id}`} className="fleet-name">{e.displayName}</Link>
        <span className="fleet-id">{e.id}{e.slot != null ? ` · slot ${e.slot}` : ''}</span>
        {!e.listed && <span className="fleet-badge fleet-badge--muted">{listing(e)}</span>}
      </>
    ),
  },
  { key: 'year', label: 'Year', title: 'museum.year · facet: era', sort: (e) => e.year, facet: (e) => [e.era ?? 'unknown'], render: (e) => e.year },
  {
    key: 'tier', label: 'Tier', title: 'Derived per docs/GUEST-TIERS.md',
    sort: (e) => e.tier,
    facet: (e) => [`T${e.tier} · ${e.tierLabel}`],
    render: (e) => <span className={`fleet-badge fleet-tier-${e.tier}`} title={e.tierLabel}>T{e.tier} · {e.tierLabel}</span>,
  },
  {
    key: 'emulator', label: 'Emulator', title: 'registry emulator {family, version, driver}; hover for the pin source · facet: family',
    sort: (e) => `${e.emulator?.family ?? ''} ${e.emulator?.version ?? ''}`.toLowerCase(),
    facet: (e) => [e.emulator?.family ?? 'none'],
    render: (e) => e.emulator ? (
      <span title={e.emulator.source}>
        <strong>{e.emulator.family}</strong>{' '}
        {e.emulator.version ?? <span className="fleet-badge fleet-badge--warn" title="no version pinned anywhere in the repo">version not recorded</span>}
        {e.emulator.driver && <span className="fleet-sub">{e.emulator.driver}</span>}
      </span>
    ) : dash,
  },
  {
    key: 'kiosk', label: 'Kiosk', title: 'Emulator inside a captured Linux VM? (registry/bridge-suites.json) · facet: kiosk distro / no kiosk',
    sort: (e) => (e.kiosk ? `1 ${e.kiosk.suite}` : '0'),
    facet: (e) => (e.kiosk ? ['kiosk', e.kiosk.distro] : ['no kiosk']),
    render: (e) => e.kiosk ? (
      <span title={e.kiosk.kind}>
        <span className="fleet-badge fleet-badge--warn">kiosk</span> {e.kiosk.distro}
      </span>
    ) : <span className="fleet-muted">no</span>,
  },
  {
    key: 'ui', label: 'UI', title: 'registry ui: what the exhibited scene is (graphical desktop, text console, 8-bit prompt, mobile)',
    sort: (e) => e.ui ?? 'zz',
    facet: (e) => [e.ui ? UI_LABEL[e.ui] ?? e.ui : 'unknown'],
    render: (e) => e.ui ? <span className={`fleet-badge ${e.ui === 'desktop' ? 'fleet-badge--info' : 'fleet-badge--muted'}`}>{UI_LABEL[e.ui] ?? e.ui}</span> : dash,
  },
  {
    key: 'screen', label: 'Resolution', title: 'exhibited framebuffer size: registry display block > runtime.x11.geometry > fixture prose (heuristic, hover)',
    sort: (e) => (e.screen?.width ?? 0) * 10000 + (e.screen?.height ?? 0),
    facet: (e) => [e.screen?.width ? `${e.screen.width}×${e.screen.height}` : 'not recorded'],
    render: (e) => e.screen?.width ? (
      <span title={e.screen.source}>{e.screen.width}×{e.screen.height}{e.screen.source.includes('heuristic') && <span className="fleet-sub">prose</span>}</span>
    ) : <span className="fleet-muted" title={e.screen?.source ?? ''}>—</span>,
  },
  {
    key: 'depth', label: 'Depth', title: 'bits per pixel of the exhibited framebuffer (same sources as Resolution; for host-native 8-bit machines this is the host surface, not the machine palette)',
    sort: (e) => e.screen?.bpp ?? 0,
    facet: (e) => [e.screen?.bpp ? `${e.screen.bpp} bpp` : 'not recorded'],
    render: (e) => e.screen?.bpp ? <span title={e.screen.source}>{e.screen.bpp} bpp</span> : <span className="fleet-muted">—</span>,
  },
  { key: 'arch', label: 'CPU / arch', title: 'museum.arch', sort: (e) => (e.arch ?? '').toLowerCase(), facet: (e) => [e.arch ?? 'unknown'], render: (e) => e.arch ?? dash },
  { key: 'lineage', label: 'Lineage / vendor', title: 'museum.lineage', sort: (e) => (e.lineage ?? '').toLowerCase(), facet: (e) => [e.lineage ?? 'unknown'], render: (e) => e.lineage ?? dash },
  {
    key: 'memory', label: 'Memory', title: 'guest machine RAM (museum.ramMB) / QEMU VM -m (runtime.qemu.memoryMB) · facet: guest RAM bucket',
    sort: (e) => e.machine.vmMemoryMB ?? e.guestRamMB ?? 0,
    facet: (e) => [ramBucket(e)],
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
    key: 'accel', label: 'QEMU / accel', title: 'runtime.qemu binary, machine, accel — or the x11 launcher geometry · facet: kvm / tcg / no QEMU + binary',
    sort: (e) => `${e.machine.accel ?? 'zz'} ${e.machine.qemuBinary ?? ''}`,
    facet: (e) => e.machine.qemuBinary ? [`QEMU ${e.machine.accel ?? ''}`.trim(), e.machine.qemuBinary.split('/').pop() ?? ''] : ['no QEMU'],
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
  { key: 'capture', label: 'Capture', title: 'frame source: dbus (QEMU display) / shm (emulator publishes) / x11', sort: (e) => e.capture ?? 'zz', facet: (e) => [e.capture ?? 'none'], render: (e) => e.capture ?? dash },
  {
    key: 'keyboard', label: 'Keyboard path', title: 'how a key reaches the guest; hover for pacing', sort: (e) => e.keyboardPath ?? 'zz',
    facet: (e) => [e.keyboardPath ?? 'none'],
    render: (e) => e.keyboardPath ? (
      <span title={e.keyPacingMs ? `hold ${e.keyPacingMs.holdMs} ms / gap ${e.keyPacingMs.gapMs} ms` : 'default pacing'}>
        {e.keyboardPath}
        {e.keyPacingMs && <span className="fleet-sub">{e.keyPacingMs.holdMs}/{e.keyPacingMs.gapMs} ms</span>}
      </span>
    ) : dash,
  },
  {
    key: 'pointer', label: 'Pointer path', title: 'stream.pointer method · abs/rel · backend · facet: abs / rel / none + method',
    sort: (e) => (e.pointer.present ? `${e.pointer.method}` : 'zz'),
    facet: (e) => e.pointer.present ? [e.pointer.absolute ? 'absolute' : 'relative', e.pointer.method ?? ''] : ['no pointer'],
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
    key: 'exec', label: 'labctl exec', title: 'operator.labctl exec_kind: the out-of-band command channel into the guest; hover for how it is wired',
    sort: (e) => (e.exec?.supported ? e.exec.kind : 'zz'),
    facet: (e) => [e.exec?.supported ? e.exec.kind : 'none'],
    render: (e) => !e.exec ? dash : e.exec.supported ? (
      <span title={e.exec.detail ?? ''}>
        <span className="fleet-badge fleet-badge--ok">{e.exec.kind}</span>
        <span className="fleet-sub">{[e.exec.user && `${e.exec.user}@`, e.exec.port != null && `:${e.exec.port}`].filter(Boolean).join('')}</span>
      </span>
    ) : (
      <span title={e.exec.detail ?? ''}><span className="fleet-badge fleet-badge--muted">none</span></span>
    ),
  },
  {
    key: 'network', label: 'Guest network', title: 'derived from the QEMU device ledger / station env, or the registry network block; hover for the mechanism',
    sort: (e) => NET_ORDER[e.network?.status ?? ''] ?? 9,
    facet: (e) => e.network ? [e.network.status, ...(e.network.source.startsWith('registry') ? ['declared'] : []), ...(e.network.source.includes('implicit') ? ['implicit'] : [])] : ['n/a'],
    render: (e) => !e.network ? dash : (
      <span title={`${e.network.detail} — source: ${e.network.source}`}>
        <span className={`fleet-badge ${NET_BADGE[e.network.status] ?? 'fleet-badge--muted'}`}>{e.network.status}</span>
        {e.network.source.startsWith('registry') && <span className="fleet-badge fleet-badge--muted" title="hand-declared in the registry">declared</span>}
        {e.network.source.includes('implicit') && <span className="fleet-badge fleet-badge--muted" title="QEMU default NIC; nothing declares the guest uses it">implicit</span>}
        {e.network.hostfwd.length > 0 && <span className="fleet-sub">{e.network.hostfwd.join(', ')}</span>}
      </span>
    ),
  },
  {
    key: 'idle', label: 'Idle auto-pause', title: 'SH_IDLE_PAUSE_SECS (daemon default 60; 0 = off)',
    sort: (e) => e.idlePauseSecs ?? -1,
    facet: (e) => [e.idlePauseSecs == null ? 'n/a' : e.idlePauseSecs === 0 ? 'off' : `${e.idlePauseSecs} s`],
    render: (e) => e.idlePauseSecs == null ? dash : e.idlePauseSecs === 0
      ? <span className="fleet-badge fleet-badge--warn">off</span>
      : <span className="fleet-badge fleet-badge--ok">{e.idlePauseSecs} s</span>,
  },
  {
    key: 'golden', label: 'Golden scene', title: 'reset.resetMode / snapshot: how "restore to golden" works · facet: resetMode + instant',
    sort: (e) => (e.golden ? `${e.golden.instant ? 0 : 1} ${e.golden.resetMode}` : 'zz'),
    facet: (e) => e.golden ? [e.golden.resetMode ?? 'unknown', e.golden.instant ? 'instant restore' : 'not instant'] : ['n/a'],
    render: (e) => e.golden ? (
      <span title={e.golden.kind ?? ''}>
        <span className={`fleet-badge ${e.golden.instant ? 'fleet-badge--ok' : 'fleet-badge--muted'}`}>{e.golden.resetMode}</span>
        {e.golden.snapshot && <span className="fleet-sub">{e.golden.snapshot}</span>}
      </span>
    ) : dash,
  },
  {
    key: 'stream', label: 'Stream', title: 'fps · audio (source) · facet: fps, audio/silent',
    sort: (e) => e.fps ?? 0,
    facet: (e) => e.fps == null ? ['n/a'] : [`${e.fps} fps`, e.audio ? `audio (${e.audioSource})` : 'silent'],
    render: (e) => e.fps == null ? dash : <>{e.fps} fps{e.audio ? ` · audio (${e.audioSource})` : ' · silent'}</>,
  },
];

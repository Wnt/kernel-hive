import { useEffect, useRef } from 'react';
import type { RuntimeVMManifestEntry } from '../types';
import { assemblyForTile } from './machines';

interface Props {
  vm: RuntimeVMManifestEntry;
  onClose: () => void;
}

export default function ExhibitInfoCard({ vm, onClose }: Props) {
  const card = useRef<HTMLElement>(null);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose();
    };
    const onPointerDown = (event: PointerEvent) => {
      if (!card.current?.contains(event.target as Node)) onClose();
    };
    document.addEventListener('keydown', onKeyDown);
    document.addEventListener('pointerdown', onPointerDown, true);
    return () => {
      document.removeEventListener('keydown', onKeyDown);
      document.removeEventListener('pointerdown', onPointerDown, true);
    };
  }, [onClose]);

  return (
    <aside
      ref={card}
      className="scene-info-card"
      style={{ '--exhibit-accent': vm.accent } as React.CSSProperties}
      role="dialog"
      aria-modal="false"
      aria-labelledby="scene-info-title"
      data-testid="exhibit-info-card"
    >
      <div className="scene-info-index" aria-hidden="true">
        Collection {String(vm.order).padStart(2, '0')}
      </div>
      <button
        type="button"
        className="scene-info-close"
        aria-label="Close exhibit information"
        onClick={onClose}
      >
        ×
      </button>
      <p className="scene-info-kicker">The Kernel Hive</p>
      <h1 id="scene-info-title">{vm.displayName}</h1>
      <p className="scene-info-meta">
        {vm.era} <span aria-hidden="true">/</span> {hardwareSetLabel(vm.id)}
      </p>
      <p className="scene-info-blurb">{vm.blurb}</p>
      <p className="scene-info-lineage">
        <span>Lineage</span> {vm.lineage}
      </p>
    </aside>
  );
}

function hardwareSetLabel(tileId: string) {
  const assembly = assemblyForTile(tileId);
  const flatPanel = assembly.monitor?.startsWith('lcd');
  switch (assembly.kind) {
    case 'towerSetup':
      return flatPanel ? 'tower + flat-panel set' : 'tower + CRT set';
    case 'pizzaBox':
      return flatPanel ? 'desktop + flat-panel set' : 'desktop + CRT set';
    case 'homeMicro':
      return 'home micro + CRT set';
    case 'phoneDock':
      return 'touch handset set';
    case 'terminal':
      return 'integrated terminal set';
    case 'industrial':
      return 'embedded workstation set';
    case 'allInOne':
      return 'all-in-one set';
    case 'combo':
      return 'complete period set';
    case 'covered':
      return 'archival hardware set';
  }
}

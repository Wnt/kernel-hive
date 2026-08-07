// ============================================================================
//  LayerTabs — the slim persistent strip atop the mobile OSK sheet
//  ---------------------------------------------------------------------------
//  [ABC] [?123] [OS] pick the body layer; the right cluster carries the
//  free-text IME toggle (🌐 — a DISTINCT control from the [ABC] alpha tab; it
//  docks the composed-commit proxy input, the only ä/ö path) and [▾] close.
//
//  Every button fires on pointerdown + preventDefault (exactly like the key
//  buttons) so the strip steals no focus and never summons the device IME.
// ============================================================================

export type OskLayer = 'abc' | '123' | 'os';

const TAB_LABEL: Record<OskLayer, string> = { abc: 'ABC', '123': '?123', os: 'OS' };

export function LayerTabs({
  layer,
  onLayer,
  abcOpen,
  onToggleAbc,
  onClose,
}: {
  layer: OskLayer;
  onLayer: (l: OskLayer) => void;
  abcOpen: boolean;
  onToggleAbc: () => void;
  onClose?: () => void;
}) {
  const tab = (l: OskLayer) => (
    <button
      key={l}
      type="button"
      className={l === layer ? 'osk-tab active' : 'osk-tab'}
      onPointerDown={(e) => { e.preventDefault(); onLayer(l); }}
      onContextMenu={(e) => e.preventDefault()}
    >
      {TAB_LABEL[l]}
    </button>
  );

  return (
    <div className="osk-tabs">
      <div className="osk-tabgroup">{(['abc', '123', 'os'] as OskLayer[]).map(tab)}</div>
      <div className="osk-tabgroup">
        <button
          type="button"
          className={abcOpen ? 'osk-tab active' : 'osk-tab'}
          onPointerDown={(e) => { e.preventDefault(); onToggleAbc(); }}
          onContextMenu={(e) => e.preventDefault()}
          title="Free-text input (composed ä/ö)"
        >
          🌐
        </button>
        <button
          type="button"
          className="osk-tab"
          onPointerDown={(e) => { e.preventDefault(); onClose?.(); }}
          onContextMenu={(e) => e.preventDefault()}
          title="Hide keyboard"
        >
          ▾
        </button>
      </div>
    </div>
  );
}

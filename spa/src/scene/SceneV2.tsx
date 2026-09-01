import { useCallback, useEffect, useMemo, useState } from 'react';
import { Canvas } from '@react-three/fiber';
import { AgXToneMapping } from 'three';
import HallShell from './HallShell';
import LightRig from './LightRig';
import CameraRig from './CameraRig';
import ModelLineup from './ModelLineup';
import { useMuseum } from '../state/store';
import ScreenTierManager from './ScreenTierManager';
import GroundingShadows from './GroundingShadows';
import { computeHall } from './hallLayout';
import { entriesForHall } from './sceneEntries';
import { shotNames } from './shots';
import ProgressiveExhibits from './ProgressiveExhibits';
import ExhibitInfoCard from './ExhibitInfoCard';
import { getFocusedScreenTileId } from './screenTiers';
import { requestHoverZoom } from './railNavigation';
import type { HallDesk } from './hallLayout';
import SceneInteractionDebug from './SceneInteractionDebug';
import EditorialGrade from './EditorialGrade';
import { beginHallEpisode, endHallEpisode } from './hallEngagement';

// ============================================================================
//  SCENE V2 — root ("/museum")
//  ---------------------------------------------------------------------------
//  Clean-slate rewrite of the 3D museum per docs/lab/research/webgl-gallery-
//  scene/ (research + ART-DIRECTION.md). Ground rules baked in from day one:
//   - AgX tone mapping, one shared color pipeline, no toneMapped opt-outs
//   - IBL only (LightRig); no analytic light soup, no billboard atmospherics
//   - real-world meters; eye-level camera; damped, clamped controls
//   - demand frameloop: zero GPU work while nothing moves
// ============================================================================

export default function SceneV2() {
  // The ANNOUNCED lineup only: a soft-hidden station (registry `listing`) gets no
  // desk in the hall. The store's `vms` still carries it for /os/:osId, so this
  // surface must read `listedVms` — including for the info card, whose id can
  // only ever come from a desk that is here.
  const registryLineup = useMuseum((state) => state.listedVms);
  const search = window.location.search;
  const displayed = useMemo(
    () => entriesForHall(registryLineup, search),
    [registryLineup, search],
  );
  const layout = useMemo(
    () => displayed.length > 0 ? computeHall(displayed) : null,
    [displayed],
  );
  const lineup = new URLSearchParams(window.location.search).get('lineup');
  const [firstSectionReady, setFirstSectionReady] = useState(false);
  const handleFirstSectionReady = useCallback(() => setFirstSectionReady(true), []);
  const [infoId, setInfoId] = useState<string | null>(null);
  const closeInfo = useCallback(() => setInfoId(null), []);
  const infoVm = registryLineup.find((entry) => entry.id === infoId) ?? null;
  const hoverInfo = useCallback((slot: HallDesk, pointerType: string | null) => {
    if (!pointerType) {
      requestHoverZoom(null);
      return;
    }
    if (pointerType !== 'mouse') {
      requestHoverZoom(null);
      return;
    }
    const focusedId = getFocusedScreenTileId();
    const focusedDesk = layout?.desks.find((desk) => desk.entry.id === focusedId);
    const currentRow = focusedDesk
      && focusedDesk.sectionKey === slot.sectionKey
      && focusedDesk.row === slot.row;
    requestHoverZoom(
      currentRow
        ? [slot.pos[0], slot.pos[1] + 1.02, slot.pos[2]]
        : null,
    );
  }, [layout]);
  // One `hall.navigate` episode per mount of the hall: entered -> approached a
  // machine -> opened one. In an effect, not the render body, so StrictMode's
  // double render cannot open two. See hallEngagement.ts for what an approach
  // is defined as and what it deliberately does not claim.
  useEffect(() => {
    beginHallEpisode();
    return endHallEpisode;
  }, []);
  useEffect(() => {
    if (import.meta.env.DEV && layout) {
      (window as unknown as { __shots?: string[] }).__shots = shotNames(layout);
    }
  }, [layout]);
  if (!layout) return null;
  return (
    <div className="scene-v2">
      <Canvas
        frameloop="demand"
        dpr={[1, 1.5]}
        gl={{ antialias: true, powerPreference: 'high-performance' }}
        camera={{
          fov: 40,
          near: 0.05,
          far: Math.max(60, layout.dims.depth * 3),
          position: [layout.dims.width * 0.4, 1.6, layout.dims.depth * 0.4],
        }}
        onCreated={({ gl }) => {
          gl.toneMapping = AgXToneMapping;
          gl.toneMappingExposure = 1.28;
          if (import.meta.env.DEV) {
            (window as unknown as {
              __sceneV2RendererInfo?: typeof gl.info;
            }).__sceneV2RendererInfo = gl.info;
          }
        }}
      >
        <color attach="background" args={['#e8e6e0']} />
        <LightRig layout={layout} />
        <HallShell
          layout={layout}
          onOpenInfo={lineup === null ? setInfoId : undefined}
          onHoverInfo={lineup === null ? hoverInfo : undefined}
        />
        {lineup === null && <GroundingShadows layout={layout} />}
        <ScreenTierManager />
        <SceneInteractionDebug layout={layout} />
        <CameraRig layout={layout} onRailMove={closeInfo} />
        <EditorialGrade />
        {lineup !== null ? (
          <ModelLineup only={lineup} />
        ) : (
          <ProgressiveExhibits
            layout={layout}
            onFirstSectionReady={handleFirstSectionReady}
            onOpenInfo={setInfoId}
            onHoverInfo={hoverInfo}
          />
        )}
      </Canvas>
      {lineup === null && !firstSectionReady && (
        <div className="scene-v2-loading" role="status" aria-live="polite">
          Loading nearby exhibits…
        </div>
      )}
      {infoVm && <ExhibitInfoCard vm={infoVm} onClose={closeInfo} />}
    </div>
  );
}

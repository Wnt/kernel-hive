import type { HallDesk } from './hallLayout';
import { DESK_MODULE } from './hallSpec';
import MachineAssembly, { DustCover } from './MachineAssembly';
import { assemblyForTile } from './machines';
import { requestRailApproach } from './railNavigation';
import type { ThreeEvent } from '@react-three/fiber';

// ============================================================================
//  SCENE V2 — exhibit: school desk + a varied machine assembly
//  ---------------------------------------------------------------------------
//  Desk at real dimensions; the machine on top comes from the sourced-model
//  variation table (towers, desktop+CRT sets, all-in-ones, pizza boxes, and
//  the occasional authentic dust cover). Shapes-first: textures later.
// ============================================================================

interface Props {
  slot: HallDesk;
  tileId: string;
  bootVideo?: string;
  loadMachine?: boolean;
  onMachineSettled?: () => void;
  onOpenInfo: (tileId: string) => void;
  onHoverInfo: (slot: HallDesk, pointerType: string | null) => void;
}

export default function PlaceholderExhibit({
  slot,
  tileId,
  bootVideo,
  loadMachine = true,
  onMachineSettled,
  onOpenInfo,
  onHoverInfo,
}: Props) {
  const assembly = assemblyForTile(slot.entry.assemblyId ?? tileId);
  const openInfo = () => onOpenInfo(tileId);
  const hoverInfo = (pointerType: string | null) => onHoverInfo(slot, pointerType);
  const onClick = (event: ThreeEvent<MouseEvent>) => {
    event.stopPropagation();
    if (event.delta > 5) return;
    requestRailApproach([slot.pos[0], DESK_MODULE.height + 0.24, slot.pos[2]]);
    openInfo();
  };
  return (
    <group
      position={slot.pos}
      rotation={[0, slot.rotY, 0]}
      onClick={onClick}
      onPointerOver={(event: ThreeEvent<PointerEvent>) => hoverInfo(event.pointerType)}
      onPointerOut={() => hoverInfo(null)}
    >
      <group position={[0, DESK_MODULE.height, 0]}>
        {loadMachine ? (
          <MachineAssembly
            assembly={assembly}
            tileId={tileId}
            bootVideo={bootVideo}
            variation={slot.variation}
            onSettled={onMachineSettled}
            onOpenInfo={openInfo}
            onHoverInfo={hoverInfo}
          />
        ) : <DustCover />}
      </group>
    </group>
  );
}

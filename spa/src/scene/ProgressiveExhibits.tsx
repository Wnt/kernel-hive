import { useCallback, useMemo, useRef, useState } from 'react';
import { invalidate, useFrame } from '@react-three/fiber';
import type { HallLayout, Point3 } from './hallLayout';
import FurnitureVariants from './FurnitureVariants';
import { VARIED_FURNITURE_MODELS } from './furnitureVariants';
import PlaceholderExhibit from './PlaceholderExhibit';
import { nextSectionToMount } from './progressiveLoading';
import SetDressing from './SetDressing';

interface Props {
  layout: HallLayout;
  onFirstSectionReady: () => void;
  onOpenInfo: (tileId: string) => void;
  onHoverInfo: (slot: HallLayout['desks'][number], pointerType: string | null) => void;
}

export default function ProgressiveExhibits({
  layout,
  onFirstSectionReady,
  onOpenInfo,
  onHoverInfo,
}: Props) {
  const [mountedSections, setMountedSections] = useState<ReadonlySet<string>>(() => new Set());
  const mountedRef = useRef(mountedSections);
  const settledSections = useRef(new Set<string>());
  const settledDesks = useRef(new Map<string, Set<string>>());
  const firstSection = useRef<string | null>(null);
  const standardDressingLayout = useMemo(() => ({
    ...layout,
    props: layout.props.filter(
      (prop) => !VARIED_FURNITURE_MODELS.includes(
        prop.model as (typeof VARIED_FURNITURE_MODELS)[number],
      ),
    ),
  }), [layout]);

  useFrame(({ camera }) => {
    const mounted = mountedRef.current;
    const hasPendingSection = [...mounted].some((key) => !settledSections.current.has(key));
    if (hasPendingSection) return;
    const position: Point3 = [camera.position.x, camera.position.y, camera.position.z];
    const next = nextSectionToMount(layout, position, mounted);
    if (!next) return;
    if (firstSection.current === null) firstSection.current = next;
    const updated = new Set(mounted).add(next);
    mountedRef.current = updated;
    setMountedSections(updated);
    invalidate();
  });

  const handleExhibitSettled = useCallback((sectionKey: string, deskId: string) => {
    const desks = settledDesks.current.get(sectionKey) ?? new Set<string>();
    if (desks.has(deskId)) return;
    desks.add(deskId);
    settledDesks.current.set(sectionKey, desks);
    const section = layout.sections.find(({ key }) => key === sectionKey);
    if (!section || desks.size < section.deskIds.length) return;
    settledSections.current.add(sectionKey);
    if (sectionKey === firstSection.current) onFirstSectionReady();
    invalidate();
  }, [layout, onFirstSectionReady]);

  return (
    <group>
      <SetDressing layout={standardDressingLayout} />
      <FurnitureVariants layout={layout} />
      {layout.desks.map((slot) => (
        <PlaceholderExhibit
          key={slot.id}
          slot={slot}
          tileId={slot.entry.id}
          bootVideo={slot.entry.bootVideo?.mp4}
          loadMachine={mountedSections.has(slot.sectionKey)}
          onMachineSettled={() => handleExhibitSettled(slot.sectionKey, slot.id)}
          onOpenInfo={onOpenInfo}
          onHoverInfo={onHoverInfo}
        />
      ))}
    </group>
  );
}

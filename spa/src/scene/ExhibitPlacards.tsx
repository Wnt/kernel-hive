import { useEffect, useMemo } from 'react';
import type { ThreeEvent } from '@react-three/fiber';
import { CanvasTexture, SRGBColorSpace } from 'three';
import type { HallDesk, HallLayout } from './hallLayout';
import { DESK_MODULE } from './hallSpec';
import { assemblyForTile } from './machines';
import { requestRailApproach } from './railNavigation';

type PlacardVariant = 'acrylic' | 'clipped' | 'framed';

function stableIndex(id: string, modulo: number) {
  let hash = 2166136261;
  for (let index = 0; index < id.length; index += 1) {
    hash = Math.imul(hash ^ id.charCodeAt(index), 16777619);
  }
  return (hash >>> 0) % modulo;
}

function displayName(desk: HallDesk) {
  if (desk.entry.displayName) return desk.entry.displayName;
  return desk.entry.id
    .replace(/^hall-test-\d+-/, '')
    .split(/[-_]/)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

function PlacardMaterial({
  desk,
  variant,
}: {
  desk: HallDesk;
  variant: PlacardVariant;
}) {
  const texture = useMemo(() => {
    const canvas = document.createElement('canvas');
    canvas.width = 512;
    canvas.height = 320;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('2d canvas unavailable');
    const accent = variant === 'acrylic'
      ? '#a23b32'
      : variant === 'clipped'
        ? '#4e6973'
        : '#9b6d35';
    context.fillStyle = variant === 'clipped' ? '#ece8dc' : '#f7f4eb';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = accent;
    context.fillRect(0, 0, 34, canvas.height);
    context.fillRect(54, 40, 420, 6);
    context.fillStyle = '#292a28';
    context.textAlign = 'left';
    context.textBaseline = 'middle';
    const name = displayName(desk);
    const fontSize = name.length > 22 ? 48 : name.length > 15 ? 57 : 66;
    context.font = `700 ${fontSize}px system-ui, sans-serif`;
    const words = name.split(' ');
    const lines: string[] = [];
    let line = '';
    for (const word of words) {
      const candidate = line ? `${line} ${word}` : word;
      if (context.measureText(candidate).width > 410 && line) {
        lines.push(line);
        line = word;
      } else {
        line = candidate;
      }
    }
    if (line) lines.push(line);
    const shown = lines.slice(0, 2);
    const startY = shown.length === 1 ? 135 : 104;
    shown.forEach((item, index) => context.fillText(item, 58, startY + index * 64));
    context.fillStyle = accent;
    context.font = '700 46px Georgia, serif';
    context.fillText(String(desk.entry.era_year), 58, 258);
    context.fillStyle = '#777166';
    context.font = '600 19px system-ui, sans-serif';
    context.textAlign = 'right';
    context.fillText('LIVING COMPUTER COLLECTION', 474, 276);
    const next = new CanvasTexture(canvas);
    next.colorSpace = SRGBColorSpace;
    next.anisotropy = 8;
    return next;
  }, [desk, variant]);
  useEffect(() => () => texture.dispose(), [texture]);
  return <meshStandardMaterial map={texture} roughness={0.82} />;
}

function AcrylicPlacard({ desk }: { desk: HallDesk }) {
  return (
    <>
      <mesh position={[0, 0.015, -0.015]}>
        <boxGeometry args={[0.25, 0.03, 0.12]} />
        <meshPhysicalMaterial
          color="#dce3e2"
          opacity={0.34}
          roughness={0.18}
          transparent
          transmission={0.3}
        />
      </mesh>
      <mesh position={[0, 0.105, 0]}>
        <planeGeometry args={[0.25, 0.16]} />
        <PlacardMaterial desk={desk} variant="acrylic" />
      </mesh>
      <mesh position={[0, 0.105, 0.009]}>
        <planeGeometry args={[0.27, 0.18]} />
        <meshPhysicalMaterial
          color="#eef4f2"
          opacity={0.18}
          roughness={0.12}
          transparent
          transmission={0.35}
        />
      </mesh>
    </>
  );
}

function ClippedPlacard({ desk }: { desk: HallDesk }) {
  return (
    <>
      <mesh position={[0, 0.022, -0.02]}>
        <boxGeometry args={[0.18, 0.022, 0.105]} />
        <meshStandardMaterial color="#333735" metalness={0.62} roughness={0.42} />
      </mesh>
      <mesh position={[0, 0.115, -0.038]}>
        <boxGeometry args={[0.014, 0.18, 0.014]} />
        <meshStandardMaterial color="#333735" metalness={0.62} roughness={0.42} />
      </mesh>
      <mesh position={[0, 0.158, -0.009]}>
        <boxGeometry args={[0.29, 0.235, 0.014]} />
        <meshStandardMaterial color="#496472" metalness={0.35} roughness={0.58} />
      </mesh>
      <mesh position={[0, 0.158, 0]}>
        <planeGeometry args={[0.25, 0.19]} />
        <PlacardMaterial desk={desk} variant="clipped" />
      </mesh>
      <mesh position={[0, 0.267, 0.014]}>
        <boxGeometry args={[0.075, 0.032, 0.022]} />
        <meshStandardMaterial color="#b13f35" metalness={0.38} roughness={0.46} />
      </mesh>
      <mesh position={[-0.027, 0.284, 0.014]} rotation={[0, 0, -0.42]}>
        <boxGeometry args={[0.009, 0.045, 0.009]} />
        <meshStandardMaterial color="#444845" metalness={0.72} roughness={0.36} />
      </mesh>
      <mesh position={[0.027, 0.284, 0.014]} rotation={[0, 0, 0.42]}>
        <boxGeometry args={[0.009, 0.045, 0.009]} />
        <meshStandardMaterial color="#444845" metalness={0.72} roughness={0.36} />
      </mesh>
    </>
  );
}

function FramedPlacard({ desk }: { desk: HallDesk }) {
  return (
    <>
      <mesh position={[0, 0.018, -0.02]}>
        <boxGeometry args={[0.27, 0.036, 0.13]} />
        <meshStandardMaterial color="#75502f" roughness={0.75} />
      </mesh>
      <mesh position={[0, 0.12, -0.012]}>
        <boxGeometry args={[0.285, 0.195, 0.018]} />
        <meshStandardMaterial color="#75502f" roughness={0.75} />
      </mesh>
      <mesh position={[0, 0.12, 0]}>
        <planeGeometry args={[0.245, 0.16]} />
        <PlacardMaterial desk={desk} variant="framed" />
      </mesh>
    </>
  );
}

function DeskPlacard({
  desk,
  onHoverInfo,
  onOpenInfo,
}: {
  desk: HallDesk;
  onHoverInfo?: (slot: HallDesk, pointerType: string | null) => void;
  onOpenInfo?: (tileId: string) => void;
}) {
  const prominent = assemblyForTile(
    desk.entry.assemblyId ?? desk.entry.id,
  ).kind === 'phoneDock';
  const variants: PlacardVariant[] = ['acrylic', 'clipped', 'framed'];
  const variant = variants[stableIndex(desk.entry.id, variants.length)];
  const click = onOpenInfo ? (event: ThreeEvent<MouseEvent>) => {
    event.stopPropagation();
    if (event.delta > 5) return;
    requestRailApproach([
      desk.pos[0],
      DESK_MODULE.height + 0.24,
      desk.pos[2],
    ]);
    onOpenInfo(desk.entry.id);
  } : undefined;
  return (
    <group
      position={desk.pos}
      rotation={[0, desk.rotY, 0]}
    >
      <group
        position={[
          (prominent ? 0.34 : 0.61) + desk.variation.placard.offset[0],
          DESK_MODULE.height + desk.variation.placard.offset[1],
          (prominent ? 0.10 : 0.24) + desk.variation.placard.offset[2],
        ]}
        rotation={[
          -0.18 + desk.variation.placard.lean,
          -0.28 + desk.variation.placard.yaw,
          0,
        ]}
        scale={prominent ? 1.12 : 1}
      >
        {variant === 'acrylic' && <AcrylicPlacard desk={desk} />}
        {variant === 'clipped' && <ClippedPlacard desk={desk} />}
        {variant === 'framed' && <FramedPlacard desk={desk} />}
        <mesh
          position={[0, 0.12, 0.025]}
          onClick={click}
          onPointerOver={onHoverInfo ? (event) => {
            event.stopPropagation();
            onHoverInfo(desk, event.pointerType);
          } : undefined}
          onPointerOut={onHoverInfo ? (event) => {
            event.stopPropagation();
            onHoverInfo(desk, null);
          } : undefined}
        >
          <planeGeometry args={[0.30, 0.24]} />
          <meshBasicMaterial
            colorWrite={false}
            depthWrite={false}
            opacity={0.001}
            transparent
          />
        </mesh>
      </group>
    </group>
  );
}

export default function ExhibitPlacards({
  layout,
  onHoverInfo,
  onOpenInfo,
}: {
  layout: HallLayout;
  onHoverInfo?: (slot: HallDesk, pointerType: string | null) => void;
  onOpenInfo?: (tileId: string) => void;
}) {
  return (
    <group>
      {layout.desks.map((desk) => (
        <DeskPlacard
          key={desk.id}
          desk={desk}
          onHoverInfo={onHoverInfo}
          onOpenInfo={onOpenInfo}
        />
      ))}
    </group>
  );
}

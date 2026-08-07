import { useEffect, useMemo } from 'react';
import {
  CanvasTexture,
  RepeatWrapping,
  SRGBColorSpace,
} from 'three';
import type { HallLayout } from './hallLayout';
import { PALETTE } from './hallSpec';

function useLabelTexture(label: string, compact = false) {
  const texture = useMemo(() => {
    const canvas = document.createElement('canvas');
    canvas.width = 512;
    canvas.height = compact ? 256 : 320;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('2d canvas unavailable');
    context.fillStyle = '#eee9dd';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = '#b9ab91';
    context.fillRect(20, 18, canvas.width - 40, 4);
    context.fillStyle = '#9b342c';
    context.fillRect(28, 34, 18, canvas.height - 68);
    context.fillStyle = '#292b2a';
    context.font = compact
      ? '700 104px Georgia, serif'
      : '700 124px Georgia, serif';
    context.textAlign = 'center';
    context.textBaseline = 'middle';
    context.fillText(label, canvas.width / 2 + 14, canvas.height / 2 - 8);
    context.font = '600 24px system-ui, sans-serif';
    context.fillStyle = '#625d52';
    context.fillText('COMPUTING COLLECTION', canvas.width / 2 + 14, canvas.height - 35);
    const next = new CanvasTexture(canvas);
    next.colorSpace = SRGBColorSpace;
    next.anisotropy = 8;
    return next;
  }, [compact, label]);
  useEffect(() => () => texture.dispose(), [texture]);
  return texture;
}

function HeaderCard({
  compact = false,
  label,
}: {
  compact?: boolean;
  label: string;
}) {
  const texture = useLabelTexture(label, compact);
  return (
    <meshStandardMaterial
      map={texture}
      polygonOffset
      polygonOffsetFactor={-1}
      roughness={0.76}
    />
  );
}

function EraPost({
  marker,
}: {
  marker: HallLayout['eraMarkers'][number];
}) {
  return (
    <group position={marker.pos} rotation={[0, marker.rotY, 0]}>
      <mesh position={[0, 0.035, 0]}>
        <boxGeometry args={[0.42, 0.07, 0.24]} />
        <meshStandardMaterial color={PALETTE.pineDark} roughness={0.8} />
      </mesh>
      <mesh position={[0, 0.57, 0]}>
        <boxGeometry args={[0.055, 1.08, 0.055]} />
        <meshStandardMaterial color={PALETTE.pine} roughness={0.78} />
      </mesh>
      <mesh position={[0, 1.14, 0]}>
        <boxGeometry args={[0.62, 0.31, 0.028]} />
        <HeaderCard compact label={marker.label} />
      </mesh>
      <mesh position={[0, 1.14, 0.018]}>
        <boxGeometry args={[0.66, 0.35, 0.012]} />
        <meshPhysicalMaterial
          color="#f4f1e8"
          opacity={0.2}
          roughness={0.18}
          transparent
          transmission={0.28}
        />
      </mesh>
    </group>
  );
}

function WallHeader({
  label,
  position,
}: {
  label: string;
  position: [number, number, number];
}) {
  return (
    <group position={position} rotation={[0, -Math.PI / 2, 0]}>
      <mesh>
        <boxGeometry args={[1.12, 0.39, 0.035]} />
        <HeaderCard label={label} />
      </mesh>
      <mesh position={[0, -0.235, 0.08]}>
        <boxGeometry args={[1.22, 0.075, 0.18]} />
        <meshStandardMaterial color={PALETTE.pineDark} roughness={0.8} />
      </mesh>
      <mesh position={[-0.48, -0.19, 0.045]}>
        <boxGeometry args={[0.055, 0.18, 0.10]} />
        <meshStandardMaterial color={PALETTE.pineDark} roughness={0.8} />
      </mesh>
      <mesh position={[0.48, -0.19, 0.045]}>
        <boxGeometry args={[0.055, 0.18, 0.10]} />
        <meshStandardMaterial color={PALETTE.pineDark} roughness={0.8} />
      </mesh>
    </group>
  );
}

function StripedWallpaper({ layout }: { layout: HallLayout }) {
  const texture = useMemo(() => {
    const canvas = document.createElement('canvas');
    canvas.width = 256;
    canvas.height = 256;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('2d canvas unavailable');
    const stripes = ['#d8c59e', '#94754c', '#d9a14b', '#716b57', '#ece1c6'];
    stripes.forEach((color, index) => {
      context.fillStyle = color;
      context.fillRect(index * 51, 0, 52, canvas.height);
    });
    context.globalAlpha = 0.12;
    context.fillStyle = '#6b5131';
    for (let y = 12; y < canvas.height; y += 24) {
      context.fillRect(0, y, canvas.width, 2);
    }
    const next = new CanvasTexture(canvas);
    next.colorSpace = SRGBColorSpace;
    next.wrapS = RepeatWrapping;
    next.repeat.set(2, 1);
    return next;
  }, []);
  useEffect(() => () => texture.dispose(), [texture]);
  const section = layout.sections[Math.max(0, layout.sections.length - 2)];
  return (
    <group
      position={[
        layout.dims.width / 2 - 0.012,
        1.38,
        section?.centerZ ?? 0,
      ]}
      rotation={[0, -Math.PI / 2, 0]}
    >
      <mesh>
        <planeGeometry args={[1.18, 1.72]} />
        <meshStandardMaterial map={texture} roughness={0.88} />
      </mesh>
      <mesh position={[0, 0, 0.018]}>
        <boxGeometry args={[1.24, 1.78, 0.035]} />
        <meshStandardMaterial
          color="#8a5a28"
          roughness={0.78}
          wireframe
        />
      </mesh>
    </group>
  );
}

export default function DecadeFixtures({ layout }: { layout: HallLayout }) {
  return (
    <group>
      {layout.eraMarkers.map((marker) => (
        <EraPost key={marker.id} marker={marker} />
      ))}
      {layout.sections.map((section) => (
        <WallHeader
          key={`wall-header:${section.key}`}
          label={section.label}
          position={[
            layout.dims.width / 2 - 0.026,
            2.27,
            section.centerZ,
          ]}
        />
      ))}
      <StripedWallpaper layout={layout} />
    </group>
  );
}

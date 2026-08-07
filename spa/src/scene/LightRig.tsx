import { Environment, Lightformer } from '@react-three/drei';
import type { HallLayout } from './hallLayout';

// ============================================================================
//  SCENE V2 — lighting
//  ---------------------------------------------------------------------------
//  Image-based lighting ONLY: an env map built once from Lightformers that
//  mirror the room's real sources (troffer rows overhead + the window wall).
//  No analytic light soup — per research report 03 and ART-DIRECTION.md
//  ("bright, flat-lit"; troffers ~4000K neutral, window ~6500K overcast).
// ============================================================================

export default function LightRig({ layout }: { layout: HallLayout }) {
  const { width, depth, height } = layout.dims;
  const rows = [...new Set(layout.troffers.map(([, , z]) => z))];
  return (
    <Environment frames={1} resolution={256}>
      {/* troffer rows — warm-neutral strips overhead */}
      {rows.map((z) => (
        <Lightformer
          key={z}
          form="rect"
          intensity={3.4}
          color="#fff2df"
          position={[0, height + 1.2, z]}
          rotation={[Math.PI / 2, 0, 0]}
          scale={[width - 1.4, 0.55, 1]}
        />
      ))}
      {/* window wall — one large cool softbox on -X */}
      <Lightformer
        form="rect"
        intensity={4.13}
        color="#d3e8fa"
        position={[-width / 2 - 1.1, height * 0.55, 0]}
        rotation={[0, Math.PI / 2, 0]}
        scale={[depth * 1.06, height * 0.86, 1]}
      />
      {/* faint warm floor/pine bounce so undersides never go dead black */}
      <Lightformer
        form="rect"
        intensity={0.9}
        color="#d8d6d2"
        position={[0, -1.5, 0]}
        rotation={[-Math.PI / 2, 0, 0]}
        scale={[width, depth, 1]}
      />
    </Environment>
  );
}

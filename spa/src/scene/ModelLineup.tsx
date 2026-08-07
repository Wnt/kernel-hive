import { Suspense } from 'react';
import NormalizedModel from './NormalizedModel';
import { MODELS, PHONE_DOCK_DISPLAY_SCALE, type ModelKey } from './machines';

// Diagnostic mode (?lineup=1&shot=lineup): every sourced model on a plinth in
// alphabetical order so a single harness shot reveals true shape, facing and
// proportions. Not part of the museum.
const KEYS = Object.keys(MODELS).sort() as ModelKey[];

export default function ModelLineup({ only }: { only?: string }) {
  // dev:<file>[:h] loads /assets/models/v2/dev/<file>.glb directly at height h —
  // lets the parametric-modeling pipeline render candidates with zero code edits.
  if (only?.startsWith('dev:')) {
    const [, file, h] = only.split(':');
    return (
      <group position={[0, 0.7, 0]}>
        <mesh position={[0, -0.35, 0]}>
          <boxGeometry args={[0.7, 0.7, 0.7]} />
          <meshStandardMaterial color="#b7bdc4" roughness={0.9} />
        </mesh>
        <Suspense fallback={null}>
          <NormalizedModel
            model={{ url: `/assets/models/v2/dev/${file}.glb`, targetH: Number(h) || 0.4 }}
          />
        </Suspense>
      </group>
    );
  }
  const keys = only && only in MODELS ? [only as ModelKey] : KEYS;
  return (
    <group>
      {keys.map((key, i) => {
        const x = (i - (keys.length - 1) / 2) * 0.9;
        return (
          <group key={key} position={[x, 0.7, 0]}>
            {/* plinth */}
            <mesh position={[0, -0.35, 0]}>
              <boxGeometry args={[0.7, 0.7, 0.7]} />
              <meshStandardMaterial color={i % 2 ? '#9aa0a6' : '#b7bdc4'} roughness={0.9} />
            </mesh>
            <Suspense fallback={null}>
              <group scale={PHONE_DOCK_DISPLAY_SCALE[key] ?? 1}>
                <NormalizedModel model={MODELS[key]} />
              </group>
            </Suspense>
          </group>
        );
      })}
    </group>
  );
}

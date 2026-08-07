import React, { Suspense, useEffect, useMemo, useRef } from 'react';
import { CatmullRomCurve3, Vector3 } from 'three';
import type {
  ExhibitVariation,
  LocalPlacementVariation,
  Point3,
} from './hallLayout';
import NormalizedModel from './NormalizedModel';
import {
  MODELS,
  PHONE_DOCK_DISPLAY_SCALE,
  type Assembly,
} from './machines';
import { PALETTE } from './hallSpec';
import { identityForTile } from './machineIdentity';
import MachineIdentityMarkers from './MachineIdentityMarkers';
import {
  machineCableRoutes,
  type MachineCableRoute,
} from './machineCable';

// ============================================================================
//  SCENE V2 — machine assembly on a desk
//  ---------------------------------------------------------------------------
//  Places sourced parts in era-correct zones on the 1.6x0.82m desk top
//  (y=0 here is the DESK SURFACE). Layout grammar: display centered slightly
//  back, keyboard front-center, mouse right of keyboard, tower on the floor
//  beside the desk. Suspense-per-part so one slow file never blanks a slot.
// ============================================================================

const DISPLAY_Z = -0.17;
const KEYBOARD_Z = 0.23;
const MOUSE_X = 0.43;

export function DustCover() {
  return (
    <group name="dust-cover-placeholder" position={[0, 0, -0.02]}>
      <mesh position={[0, 0.21, 0]}>
        <boxGeometry args={[0.42, 0.42, 0.44]} />
        <meshStandardMaterial color={PALETTE.dustCover} roughness={1} />
      </mesh>
      <mesh position={[0, 0.045, 0]}>
        <boxGeometry args={[0.5, 0.09, 0.52]} />
        <meshStandardMaterial color={PALETTE.dustCover} roughness={1} />
      </mesh>
    </group>
  );
}

interface Props {
  assembly: Assembly;
  tileId: string;
  bootVideo?: string;
  variation?: ExhibitVariation;
  onSettled?: () => void;
  onError?: (error: Error) => void;
  onOpenInfo?: () => void;
  onHoverInfo?: (pointerType: string | null) => void;
}

function Settled({ onSettled }: { onSettled?: () => void }) {
  const reported = useRef(false);
  useEffect(() => {
    if (!reported.current) {
      reported.current = true;
      onSettled?.();
    }
  }, [onSettled]);
  return null;
}

interface BoundaryProps extends React.PropsWithChildren {
  fallback: React.ReactNode;
  onError?: (error: Error) => void;
}

class ExhibitErrorBoundary extends React.Component<BoundaryProps, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  componentDidCatch(error: Error) {
    this.props.onError?.(error);
    console.error('[scene-v2] exhibit model failed; showing dust cover', error);
  }

  render() {
    return this.state.failed ? this.props.fallback : this.props.children;
  }
}

const DEFAULT_PLACEMENT: LocalPlacementVariation = {
  offset: [0, 0, 0],
  yaw: 0,
};

const DEFAULT_VARIATION: ExhibitVariation = {
  machine: DEFAULT_PLACEMENT,
  keyboard: DEFAULT_PLACEMENT,
  mouse: DEFAULT_PLACEMENT,
  placard: { ...DEFAULT_PLACEMENT, lean: 0 },
  aging: { yellowing: 0, valueOffset: 0, roughnessOffset: 0 },
};

function VariedPlacement({
  base = [0, 0, 0],
  placement,
  children,
}: React.PropsWithChildren<{
  base?: Point3;
  placement: LocalPlacementVariation;
}>) {
  return (
    <group
      position={[
        base[0] + placement.offset[0],
        base[1] + placement.offset[1],
        base[2] + placement.offset[2],
      ]}
      rotation={[0, placement.yaw, 0]}
    >
      {children}
    </group>
  );
}

function CableTube({
  route,
  tileId,
}: {
  route: MachineCableRoute;
  tileId: string;
}) {
  const geometry = useMemo(() => {
    const start = new Vector3(...route.start);
    const end = new Vector3(...route.end);
    const desktopEnd = end.y >= 0;
    const points = desktopEnd
      ? [
        start,
        start.clone().lerp(end, 0.34).setY(0.007),
        start.clone().lerp(end, 0.72).setY(0.009),
        end,
      ]
      : [
        start,
        new Vector3(end.x, 0.008, start.z - 0.06),
        new Vector3(end.x, end.y + 0.12, end.z),
        end,
      ];
    return new CatmullRomCurve3(points).getPoints(32);
  }, [route]);
  const curve = useMemo(
    () => geometry ? new CatmullRomCurve3(geometry) : null,
    [geometry],
  );
  if (!curve) return null;
  return (
    <mesh name={`machine-cable:${tileId}:${route.kind}`}>
      <tubeGeometry args={[curve, 32, 0.0027, 7, false]} />
      <meshStandardMaterial color="#343431" roughness={0.58} />
    </mesh>
  );
}

function MachineCables({
  assembly,
  tileId,
  variation,
}: {
  assembly: Assembly;
  tileId: string;
  variation: ExhibitVariation;
}) {
  return machineCableRoutes(assembly, variation).map((route) => (
    <CableTube key={route.kind} route={route} tileId={tileId} />
  ));
}

function MachineParts({
  assembly,
  tileId,
  bootVideo,
  variation = DEFAULT_VARIATION,
  onOpenInfo,
  onHoverInfo,
}: Props) {
  if (assembly.kind === 'covered') return null;
  const finish = identityForTile(tileId);

  return (
    <>
      {assembly.kind === 'combo' && assembly.combo && (
        <VariedPlacement placement={variation.machine}>
          <NormalizedModel
            model={MODELS[assembly.combo]}
            aging={variation.aging}
            finish={finish}
            tileId={tileId}
            bootVideo={bootVideo}
            onOpenInfo={onOpenInfo}
            onHoverInfo={onHoverInfo}
          />
        </VariedPlacement>
      )}

      {assembly.kind === 'allInOne' && (
        <group>
          {assembly.body && (
            <VariedPlacement base={[0, 0, DISPLAY_Z]} placement={variation.machine}>
              <NormalizedModel
                model={MODELS[assembly.body]}
                aging={variation.aging}
                finish={finish}
                tileId={tileId}
                bootVideo={bootVideo}
                onOpenInfo={onOpenInfo}
                onHoverInfo={onHoverInfo}
              />
            </VariedPlacement>
          )}
          {assembly.keyboard && (
            <VariedPlacement base={[0, 0, KEYBOARD_Z]} placement={variation.keyboard}>
              <NormalizedModel model={MODELS[assembly.keyboard]} finish={finish} />
            </VariedPlacement>
          )}
          {assembly.mouse && (
            <VariedPlacement base={[MOUSE_X, 0, KEYBOARD_Z]} placement={variation.mouse}>
              <NormalizedModel model={MODELS[assembly.mouse]} finish={finish} />
            </VariedPlacement>
          )}
        </group>
      )}

      {assembly.kind === 'pizzaBox' && (
        <group>
          <VariedPlacement placement={variation.machine}>
            {assembly.body && (
              <group position={[0, 0, DISPLAY_Z + 0.02]}>
                <NormalizedModel
                  model={MODELS[assembly.body]}
                  aging={variation.aging}
                  finish={finish}
                />
              </group>
            )}
            {assembly.monitor && (
              <group position={[0, assembly.body ? MODELS[assembly.body].targetH : 0, DISPLAY_Z]}>
                <NormalizedModel
                  model={MODELS[assembly.monitor]}
                  aging={variation.aging}
                  finish={finish}
                  tileId={tileId}
                  bootVideo={bootVideo}
                  onOpenInfo={onOpenInfo}
                  onHoverInfo={onHoverInfo}
                />
              </group>
            )}
          </VariedPlacement>
          {assembly.keyboard && (
            <VariedPlacement base={[0, 0, KEYBOARD_Z]} placement={variation.keyboard}>
              <NormalizedModel model={MODELS[assembly.keyboard]} finish={finish} />
            </VariedPlacement>
          )}
          {assembly.mouse && (
            <VariedPlacement base={[MOUSE_X, 0, KEYBOARD_Z]} placement={variation.mouse}>
              <NormalizedModel model={MODELS[assembly.mouse]} finish={finish} />
            </VariedPlacement>
          )}
        </group>
      )}

      {assembly.kind === 'homeMicro' && (
        <group>
          <VariedPlacement placement={variation.machine}>
            {assembly.monitor && (
              <group position={[0, 0, DISPLAY_Z - 0.04]}>
                <NormalizedModel
                  model={MODELS[assembly.monitor]}
                  aging={variation.aging}
                  finish={finish}
                  tileId={tileId}
                  bootVideo={bootVideo}
                  onOpenInfo={onOpenInfo}
                  onHoverInfo={onHoverInfo}
                />
              </group>
            )}
            {assembly.body && (
              <group position={[0, 0, 0.13]}>
                <NormalizedModel
                  model={MODELS[assembly.body]}
                  aging={variation.aging}
                  finish={finish}
                />
              </group>
            )}
          </VariedPlacement>
          {assembly.mouse && (
            <VariedPlacement base={[MOUSE_X, 0, 0.16]} placement={variation.mouse}>
              <NormalizedModel model={MODELS[assembly.mouse]} finish={finish} />
            </VariedPlacement>
          )}
        </group>
      )}

      {assembly.kind === 'terminal' && assembly.body && (
        <VariedPlacement base={[0, 0, -0.02]} placement={variation.machine}>
          <NormalizedModel
            model={MODELS[assembly.body]}
            aging={variation.aging}
            finish={finish}
            tileId={tileId}
            bootVideo={bootVideo}
            onOpenInfo={onOpenInfo}
            onHoverInfo={onHoverInfo}
          />
        </VariedPlacement>
      )}

      {assembly.kind === 'phoneDock' && assembly.body && (
        <VariedPlacement base={[0, 0, -0.02]} placement={variation.machine}>
          <group scale={PHONE_DOCK_DISPLAY_SCALE[assembly.body] ?? 1}>
            <NormalizedModel
              model={MODELS[assembly.body]}
              aging={variation.aging}
              finish={finish}
              tileId={tileId}
              bootVideo={bootVideo}
              onOpenInfo={onOpenInfo}
              onHoverInfo={onHoverInfo}
            />
          </group>
        </VariedPlacement>
      )}

      {assembly.kind === 'industrial' && (
        <group>
          <VariedPlacement placement={variation.machine}>
            {assembly.monitor && (
              <group position={[-0.12, 0, DISPLAY_Z]}>
                <NormalizedModel
                  model={MODELS[assembly.monitor]}
                  aging={variation.aging}
                  finish={finish}
                  tileId={tileId}
                  bootVideo={bootVideo}
                  onOpenInfo={onOpenInfo}
                  onHoverInfo={onHoverInfo}
                />
              </group>
            )}
            {assembly.body && (
              <group position={[0.42, 0, DISPLAY_Z + 0.02]}>
                <NormalizedModel
                  model={MODELS[assembly.body]}
                  aging={variation.aging}
                  finish={finish}
                />
              </group>
            )}
          </VariedPlacement>
          {assembly.keyboard && (
            <VariedPlacement base={[-0.08, 0, KEYBOARD_Z]} placement={variation.keyboard}>
              <NormalizedModel model={MODELS[assembly.keyboard]} finish={finish} />
            </VariedPlacement>
          )}
          {assembly.mouse && (
            <VariedPlacement
              base={[MOUSE_X - 0.08, 0, KEYBOARD_Z]}
              placement={variation.mouse}
            >
              <NormalizedModel model={MODELS[assembly.mouse]} finish={finish} />
            </VariedPlacement>
          )}
        </group>
      )}

      {assembly.kind === 'towerSetup' && (
        <group>
          <VariedPlacement placement={variation.machine}>
            {/* tower stands on the FLOOR beside the desk (group is in desk-top
                space, so drop it by desk height) */}
            {assembly.body && (
              <group position={[0.62, -0.72, -0.03]}>
                <NormalizedModel
                  model={MODELS[assembly.body]}
                  aging={variation.aging}
                  finish={finish}
                />
              </group>
            )}
            {assembly.monitor && (
              <group position={[-0.12, 0, DISPLAY_Z]}>
                <NormalizedModel
                  model={MODELS[assembly.monitor]}
                  aging={variation.aging}
                  finish={finish}
                  tileId={tileId}
                  bootVideo={bootVideo}
                  onOpenInfo={onOpenInfo}
                  onHoverInfo={onHoverInfo}
                />
              </group>
            )}
          </VariedPlacement>
          {assembly.keyboard && (
            <VariedPlacement base={[-0.12, 0, KEYBOARD_Z]} placement={variation.keyboard}>
              <NormalizedModel model={MODELS[assembly.keyboard]} finish={finish} />
            </VariedPlacement>
          )}
          {assembly.mouse && (
            <VariedPlacement
              base={[MOUSE_X - 0.06, 0, KEYBOARD_Z]}
              placement={variation.mouse}
            >
              <NormalizedModel model={MODELS[assembly.mouse]} finish={finish} />
            </VariedPlacement>
          )}
        </group>
      )}

      <MachineCables assembly={assembly} tileId={tileId} variation={variation} />

      <VariedPlacement placement={variation.machine}>
        <MachineIdentityMarkers assembly={assembly} tileId={tileId} />
      </VariedPlacement>
    </>
  );
}

export default function MachineAssembly({
  assembly,
  tileId,
  bootVideo,
  variation,
  onSettled,
  onError,
  onOpenInfo,
  onHoverInfo,
}: Props) {
  if (assembly.kind === 'covered') {
    return (
      <>
        <DustCover />
        <Settled onSettled={onSettled} />
      </>
    );
  }
  const fallback = (
    <>
      <DustCover />
      <Settled onSettled={onSettled} />
    </>
  );
  return (
    <ExhibitErrorBoundary fallback={fallback} onError={onError}>
      <Suspense fallback={<DustCover />}>
        <MachineParts
          assembly={assembly}
          tileId={tileId}
          bootVideo={bootVideo}
          variation={variation}
          onOpenInfo={onOpenInfo}
          onHoverInfo={onHoverInfo}
        />
        <Settled onSettled={onSettled} />
      </Suspense>
    </ExhibitErrorBoundary>
  );
}

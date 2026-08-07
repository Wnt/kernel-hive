import { useEffect, useMemo } from 'react';
import { CanvasTexture, DoubleSide, SRGBColorSpace } from 'three';
import { identityForTile, type ExhibitIdentity } from './machineIdentity';
import {
  MODELS,
  type Assembly,
  type MachineModel,
  type ModelKey,
} from './machines';
import type { Point3 } from './hallLayout';
import { identityBadgeSurface } from './machineBadge';

const DISPLAY_Z = -0.17;

const BODY_FRONT_DEPTH: Partial<Record<ModelKey, number>> = {
  towerA: 0.205,
  paramTower: 0.215,
  towerC: 0.225,
  towerD: 0.228,
  towerE: 0.215,
  modernTower: 0.225,
  modernD: 0.215,
  pizzaBoxA: 0.225,
  pizzaBoxB: 0.19,
  pizzaBoxC: 0.2,
  pizzaBoxD: 0.2,
  pizzaBoxE: 0.19,
  pizzaBoxF: 0.225,
  industrialBox: 0.09,
};

type LabelStyle = 'nameplate' | 'spec' | 'drive';

function useDecalTexture(
  identity: ExhibitIdentity,
  text: string,
  style: LabelStyle,
) {
  const texture = useMemo(() => {
    const canvas = document.createElement('canvas');
    canvas.width = style === 'drive' ? 256 : 512;
    canvas.height = style === 'spec' ? 256 : 128;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('2d canvas unavailable');

    if (style === 'spec') {
      context.fillStyle = '#d8d0bd';
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.strokeStyle = identity.accentTint;
      context.lineWidth = 18;
      context.strokeRect(9, 9, canvas.width - 18, canvas.height - 18);
      context.fillStyle = '#343533';
      context.font = '700 54px ui-monospace, monospace';
      context.textAlign = 'center';
      context.textBaseline = 'middle';
      const [first, second] = text.split(' • ');
      context.fillText(first, canvas.width / 2, canvas.height * 0.39);
      context.font = '600 42px ui-monospace, monospace';
      context.fillText(second ?? 'MUSEUM SET', canvas.width / 2, canvas.height * 0.65);
    } else {
      context.fillStyle = style === 'drive' ? '#393b3a' : identity.accentTint;
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.strokeStyle = '#ded8c9';
      context.globalAlpha = 0.62;
      context.lineWidth = 6;
      context.strokeRect(6, 6, canvas.width - 12, canvas.height - 12);
      context.globalAlpha = 1;
      context.fillStyle = '#f2eee4';
      context.font = style === 'drive'
        ? '700 58px ui-monospace, monospace'
        : '700 72px system-ui, sans-serif';
      context.textAlign = 'center';
      context.textBaseline = 'middle';
      context.fillText(text, canvas.width / 2, canvas.height / 2 + 2);
    }

    const next = new CanvasTexture(canvas);
    next.colorSpace = SRGBColorSpace;
    next.anisotropy = 8;
    return next;
  }, [identity, style, text]);
  useEffect(() => () => texture.dispose(), [texture]);
  return texture;
}

function Decal({
  height,
  identity,
  position,
  rotation = [0, 0, 0],
  style,
  text,
  width,
}: {
  height: number;
  identity: ExhibitIdentity;
  position: Point3;
  rotation?: Point3;
  style: LabelStyle;
  text: string;
  width: number;
}) {
  const texture = useDecalTexture(identity, text, style);
  return (
    <mesh
      name={`machine-decal:${style}:${text}`}
      position={position}
      rotation={rotation}
    >
      <planeGeometry args={[width, height]} />
      <meshStandardMaterial
        map={texture}
        polygonOffset
        polygonOffsetFactor={-2}
        roughness={style === 'nameplate' ? 0.42 : 0.74}
        side={DoubleSide}
      />
    </mesh>
  );
}

function ScreenNameplate({
  base = [0, 0, 0],
  identity,
  modelKey,
}: {
  base?: Point3;
  identity: ExhibitIdentity;
  modelKey: ModelKey;
}) {
  const screen = (MODELS[modelKey] as MachineModel).screen;
  if (!screen) return null;
  const width = 0.058;
  return (
    <Decal
      height={0.014}
      identity={identity}
      position={[
        base[0] + screen.center[0] + screen.size[0] / 2 - width / 2 - 0.008,
        base[1] + screen.center[1] - screen.size[1] / 2 - 0.014,
        base[2] + screen.center[2] + 0.028,
      ]}
      rotation={[screen.rot ?? 0, 0, 0]}
      style="nameplate"
      text={identity.badge}
      width={width}
    />
  );
}

function TowerPanel({
  body,
  identity,
  tileId,
}: {
  body: ModelKey;
  identity: ExhibitIdentity;
  tileId: string;
}) {
  const height = MODELS[body].targetH;
  const front = -0.03 + (BODY_FRONT_DEPTH[body] ?? 0.21) + 0.004;
  const showSpec = stableUnit(tileId, 431) > 0.42;
  return (
    <group>
      <mesh position={[0.62, -0.72 + height * 0.58, front - 0.003]}>
        <boxGeometry args={[0.055, 0.006, 0.004]} />
        <meshStandardMaterial color={identity.accentTint} roughness={0.5} />
      </mesh>
      <Decal
        height={0.012}
        identity={identity}
        position={[0.62, -0.72 + height * 0.48, front]}
        style="nameplate"
        text={identity.badge}
        width={0.055}
      />
      <Decal
        height={0.009}
        identity={identity}
        position={[0.62, -0.72 + height * 0.82, front]}
        style="drive"
        text="5¼ DRIVE"
        width={0.043}
      />
      <Decal
        height={0.008}
        identity={identity}
        position={[0.62, -0.72 + height * 0.72, front]}
        style="drive"
        text="3½ DISK"
        width={0.038}
      />
      {showSpec && identity.spec && (
        <Decal
          height={0.042}
          identity={identity}
          position={[0.62, -0.72 + height * 0.3, front]}
          style="spec"
          text={identity.spec}
          width={0.042}
        />
      )}
    </group>
  );
}

function PizzaBoxPanel({
  body,
  identity,
}: {
  body: ModelKey;
  identity: ExhibitIdentity;
}) {
  const front = DISPLAY_Z + 0.02 + (BODY_FRONT_DEPTH[body] ?? 0.2) + 0.004;
  return (
    <group>
      <Decal
        height={0.012}
        identity={identity}
        position={[-0.09, MODELS[body].targetH * 0.5, front]}
        style="nameplate"
        text={identity.badge}
        width={0.055}
      />
      <Decal
        height={0.008}
        identity={identity}
        position={[0.08, MODELS[body].targetH * 0.58, front]}
        style="drive"
        text="DISK"
        width={0.032}
      />
    </group>
  );
}

function WedgeBadge({
  body,
  identity,
}: {
  body: ModelKey;
  identity: ExhibitIdentity;
}) {
  return (
    <Decal
      height={0.016}
      identity={identity}
      position={[-0.14, MODELS[body].targetH + 0.01, 0.025]}
      rotation={[-Math.PI / 2, 0, -0.025]}
      style="nameplate"
      text={identity.badge}
      width={0.06}
    />
  );
}

function PhoneDockBadge({ identity }: { identity: ExhibitIdentity }) {
  return (
    <Decal
      height={0.015}
      identity={identity}
      position={[0, 0.008, 0.075]}
      rotation={[-Math.PI / 2, 0, 0]}
      style="nameplate"
      text={identity.badge}
      width={0.058}
    />
  );
}

function stableUnit(id: string, salt: number) {
  let hash = 2166136261 ^ salt;
  for (let index = 0; index < id.length; index += 1) {
    hash = Math.imul(hash ^ id.charCodeAt(index), 16777619);
  }
  return (hash >>> 0) / 0xffffffff;
}

export default function MachineIdentityMarkers({
  assembly,
  tileId,
}: {
  assembly: Assembly;
  tileId: string;
}) {
  const identity = identityForTile(tileId);
  const badgeSurface = identityBadgeSurface(assembly);

  if (assembly.kind === 'towerSetup') {
    return (
      <>
        {badgeSurface === 'bezel' && assembly.monitor && (
          <ScreenNameplate
            base={[-0.12, 0, DISPLAY_Z]}
            identity={identity}
            modelKey={assembly.monitor}
          />
        )}
        {badgeSurface === 'case' && assembly.body && (
          <TowerPanel body={assembly.body} identity={identity} tileId={tileId} />
        )}
      </>
    );
  }
  if (assembly.kind === 'pizzaBox') {
    return (
      <>
        {badgeSurface === 'bezel' && assembly.monitor && (
          <ScreenNameplate
            base={[0, 0, DISPLAY_Z]}
            identity={identity}
            modelKey={assembly.monitor}
          />
        )}
        {badgeSurface === 'case' && assembly.body && (
          <PizzaBoxPanel body={assembly.body} identity={identity} />
        )}
      </>
    );
  }
  if (assembly.kind === 'homeMicro') {
    return (
      <>
        {badgeSurface === 'case' && assembly.body && (
          <WedgeBadge body={assembly.body} identity={identity} />
        )}
        {badgeSurface === 'bezel' && assembly.monitor && (
          <ScreenNameplate
            base={[0, 0, DISPLAY_Z - 0.04]}
            identity={identity}
            modelKey={assembly.monitor}
          />
        )}
      </>
    );
  }
  if (assembly.kind === 'allInOne' && assembly.body) {
    return (
      <ScreenNameplate
        base={[0, 0, DISPLAY_Z]}
        identity={identity}
        modelKey={assembly.body}
      />
    );
  }
  if (assembly.kind === 'terminal' && assembly.body) {
    return (
      <ScreenNameplate
        base={[0, 0, -0.02]}
        identity={identity}
        modelKey={assembly.body}
      />
    );
  }
  if (assembly.kind === 'industrial') {
    return (
      <>
        {badgeSurface === 'bezel' && assembly.monitor && (
          <ScreenNameplate
            base={[-0.12, 0, DISPLAY_Z]}
            identity={identity}
            modelKey={assembly.monitor}
          />
        )}
        {badgeSurface === 'case' && assembly.body && (
          <>
            <Decal
              height={0.01}
              identity={identity}
              position={[
                0.42,
                0.057,
                DISPLAY_Z + 0.02 + (BODY_FRONT_DEPTH[assembly.body] ?? 0.09),
              ]}
              style="nameplate"
              text={identity.badge}
              width={0.055}
            />
            {identity.spec && (
              <Decal
                height={0.038}
                identity={identity}
                position={[
                  0.42,
                  0.025,
                  DISPLAY_Z + 0.02 + (BODY_FRONT_DEPTH[assembly.body] ?? 0.09),
                ]}
                style="spec"
                text={identity.spec}
                width={0.038}
              />
            )}
          </>
        )}
      </>
    );
  }
  if (assembly.kind === 'phoneDock' && badgeSurface === 'dock') {
    return <PhoneDockBadge identity={identity} />;
  }
  if (assembly.kind === 'combo' && assembly.combo) {
    return <ScreenNameplate identity={identity} modelKey={assembly.combo} />;
  }
  return null;
}

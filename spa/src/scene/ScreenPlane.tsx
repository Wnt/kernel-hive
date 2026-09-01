import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { invalidate, useFrame, useThree, type ThreeEvent } from '@react-three/fiber';
import { useLocation, useNavigate } from 'react-router-dom';
import {
  CanvasTexture,
  LinearFilter,
  Mesh,
  SRGBColorSpace,
  Texture,
  TextureLoader,
  VideoTexture,
  type Group,
  Vector3,
} from 'three';
import { posterFor } from '../data/posterIndex';
import type { MachineModel } from './machines';
import {
  registerScreen,
  type ScreenTier,
} from './screenTiers';
import { getCurrentRailT, requestRailApproach } from './railNavigation';
import { noteHallOpen } from './hallEngagement';
import { useFocusedLiveTexture } from './useFocusedLiveTexture';

interface Props {
  tileId: string;
  bootVideo?: string;
  screen: NonNullable<MachineModel['screen']>;
  onOpenInfo?: () => void;
  onHoverInfo?: (pointerType: string | null) => void;
}

interface VideoSource {
  video: HTMLVideoElement;
  texture: VideoTexture;
  ready: boolean;
}

const SCREEN_OFFSET = 0.0015;

export default function ScreenPlane({
  tileId,
  bootVideo,
  screen,
  onOpenInfo,
  onHoverInfo,
}: Props) {
  const group = useRef<Group>(null);
  const shimmer = useRef<Mesh>(null);
  const [tier, setTier] = useState<ScreenTier>('culled');
  const [liveFocused, setLiveFocused] = useState(false);
  const poster = usePosterTexture(posterFor(tileId)?.hero);
  const video = useBootVideo(bootVideo);
  const live = useFocusedLiveTexture(tileId, liveFocused);
  const hintTexture = useMemo(createUseHintTexture, []);
  const navigate = useNavigate();
  const location = useLocation();
  const { gl } = useThree();
  const screenMode = import.meta.env.DEV
    ? new URLSearchParams(window.location.search).get('screens')
    : null;
  const debug = screenMode === 'debug';
  const animated = !!bootVideo;
  const focused = tier === 'focused';
  const hintHeight = Math.min(0.036, screen.size[1] * 0.28);
  const connecting = focused
    && live.streamable
    && live.phase !== 'live'
    && live.phase !== 'error';
  const surfaceZ = screen.surfaceOffset ?? 0;

  const updateTier = useCallback((next: ScreenTier) => setTier(next), []);
  const updateLiveFocus = useCallback((next: boolean) => setLiveFocused(next), []);
  useLayoutEffect(() => {
    if (!group.current) return undefined;
    return registerScreen(group.current, tileId, animated, updateTier, updateLiveFocus);
  }, [animated, tileId, updateLiveFocus, updateTier]);
  useEffect(() => () => hintTexture.dispose(), [hintTexture]);

  const videoActive = (tier === 'focused' || tier === 'near') && live.phase !== 'live';
  useEffect(() => {
    if (!video) return;
    if (!videoActive) {
      video.video.pause();
      return;
    }
    video.video.preload = 'auto';
    void video.video.play().catch(() => undefined);
  }, [video, videoActive]);

  useVideoInvalidation(video, live.phase === 'live' ? 'culled' : tier);
  useFrame(({ clock }) => {
    if (!connecting || !shimmer.current) return;
    const width = screen.size[0];
    shimmer.current.position.x =
      -width * 0.58 + (clock.elapsedTime * 0.16 % (width * 1.16));
    const material = shimmer.current.material;
    if (!Array.isArray(material)) material.opacity = 0.12;
    invalidate();
  });

  const attractTexture = videoActive && video?.ready ? video.texture : poster;
  const texture = focused && live.texture ? live.texture : attractTexture;
  if (screenMode === 'off') return null;

  const onClick = (event: ThreeEvent<MouseEvent>) => {
    event.stopPropagation();
    if (event.delta > 5) return;
    if (!focused) {
      const point = group.current?.getWorldPosition(new Vector3());
      if (point) requestRailApproach(point.toArray());
      onOpenInfo?.();
      return;
    }
    preserveMuseumRailPosition(location.state);
    // Before the navigate, not after: this unmounts the hall, and the episode
    // has to know the machine was opened before it settles its counts.
    noteHallOpen(tileId);
    navigate(`/os/${tileId}`, { state: { fromMuseum: true } });
  };
  const onPointerOver = (event: ThreeEvent<PointerEvent>) => {
    event.stopPropagation();
    gl.domElement.style.cursor = 'pointer';
    onHoverInfo?.(event.pointerType);
  };
  const onPointerOut = () => {
    if (gl.domElement.style.cursor === 'pointer') gl.domElement.style.cursor = '';
    onHoverInfo?.(null);
  };

  return (
    <group
      ref={group}
      position={screen.center}
      rotation={[screen.rot ?? 0, 0, 0]}
      onClick={onClick}
      onPointerOver={onPointerOver}
      onPointerOut={onPointerOut}
    >
      <mesh
        position={[0, 0, surfaceZ + SCREEN_OFFSET]}
        onClick={onClick}
        onPointerOver={onPointerOver}
        onPointerOut={onPointerOut}
      >
        <planeGeometry args={screen.size} />
        {debug ? (
          <meshBasicMaterial color="#ff00ff" />
        ) : videoActive ? (
          <meshStandardMaterial
            color="#a4b0aa"
            map={texture}
            emissive="#a4d0b5"
            emissiveMap={texture}
            emissiveIntensity={0.36}
            roughness={0.34}
          />
        ) : (
          <meshStandardMaterial
            color="#56635e"
            emissive="#86aa91"
            emissiveIntensity={0.12}
            emissiveMap={texture}
            map={texture}
            metalness={0.03}
            roughness={0.32}
          />
        )}
      </mesh>
      <mesh
        position={[0, 0, surfaceZ + SCREEN_OFFSET * 8]}
        onClick={onClick}
        onPointerOver={onPointerOver}
        onPointerOut={onPointerOut}
      >
        <planeGeometry args={screen.size} />
        <meshBasicMaterial
          transparent
          opacity={0}
          depthWrite={false}
          colorWrite={false}
        />
      </mesh>
      {connecting && (
        <mesh ref={shimmer} position={[0, 0, surfaceZ + SCREEN_OFFSET * 2]}>
          <planeGeometry args={[screen.size[0] * 0.18, screen.size[1] * 0.98]} />
          <meshBasicMaterial
            color="#d8ffe5"
            transparent
            opacity={0.12}
            depthWrite={false}
          />
        </mesh>
      )}
      {focused && live.phase === 'live' && (
        <mesh
          position={[
            0,
            -screen.size[1] / 2 + hintHeight / 2 + screen.size[1] * 0.08,
            surfaceZ + SCREEN_OFFSET * 7,
          ]}
        >
          <planeGeometry
            args={[
              Math.min(0.2, Math.max(0.09, screen.size[0] * 0.88)),
              hintHeight,
            ]}
          />
          <meshStandardMaterial map={hintTexture} color="#eee5cd" roughness={0.82} />
        </mesh>
      )}
    </group>
  );
}

function preserveMuseumRailPosition(locationState: unknown) {
  const state = window.history.state;
  const routerState = typeof state === 'object' && state !== null ? state : {};
  const prior = typeof locationState === 'object' && locationState !== null ? locationState : {};
  window.history.replaceState(
    {
      ...routerState,
      usr: { ...prior, museumRailT: getCurrentRailT() },
    },
    '',
  );
}

function usePosterTexture(url?: string) {
  const fallback = useMemo(createStandbyTexture, []);
  const [texture, setTexture] = useState<Texture>(fallback);

  useEffect(() => () => fallback.dispose(), [fallback]);
  useEffect(() => {
    if (!url) return undefined;
    let cancelled = false;
    let loaded: Texture | null = null;
    new TextureLoader().load(
      url,
      (next) => {
        if (cancelled) {
          next.dispose();
          return;
        }
        loaded = downsamplePoster(next);
        next.dispose();
        setTexture(loaded);
        invalidate();
      },
      undefined,
      () => undefined,
    );
    return () => {
      cancelled = true;
      loaded?.dispose();
    };
  }, [url]);

  return texture;
}

function useBootVideo(src?: string) {
  const [source, setSource] = useState<VideoSource | null>(null);

  useEffect(() => {
    if (!src) return undefined;
    const video = document.createElement('video');
    video.src = src;
    video.muted = true;
    video.loop = true;
    video.playsInline = true;
    video.preload = 'metadata';
    const texture = configureTexture(new VideoTexture(video));
    const markReady = () => {
      setSource({ video, texture, ready: true });
      invalidate();
    };
    video.addEventListener('loadeddata', markReady);
    setSource({ video, texture, ready: false });
    return () => {
      video.removeEventListener('loadeddata', markReady);
      video.pause();
      video.removeAttribute('src');
      video.load();
      texture.dispose();
    };
  }, [src]);

  return source;
}

function useVideoInvalidation(source: VideoSource | null, tier: ScreenTier) {
  useEffect(() => {
    if (!source?.ready) return undefined;
    const { video, texture } = source;
    if (tier === 'near') {
      const timer = window.setInterval(() => {
        texture.needsUpdate = true;
        invalidate();
      }, 100);
      return () => window.clearInterval(timer);
    }
    if (tier !== 'focused') return undefined;

    let cancelled = false;
    let callback = 0;
    const update = () => {
      if (cancelled) return;
      texture.needsUpdate = true;
      invalidate();
      callback = video.requestVideoFrameCallback(update);
    };
    callback = video.requestVideoFrameCallback(update);
    return () => {
      cancelled = true;
      video.cancelVideoFrameCallback(callback);
    };
  }, [source, tier]);
}

function configureTexture<T extends Texture>(texture: T): T {
  texture.colorSpace = SRGBColorSpace;
  texture.minFilter = LinearFilter;
  texture.magFilter = LinearFilter;
  return texture;
}

function downsamplePoster(source: Texture) {
  const image = source.image as CanvasImageSource & { width: number; height: number };
  const canvas = document.createElement('canvas');
  canvas.width = 320;
  canvas.height = Math.max(1, Math.round(320 * image.height / image.width));
  canvas.getContext('2d')?.drawImage(image, 0, 0, canvas.width, canvas.height);
  return configureTexture(new CanvasTexture(canvas));
}

function createStandbyTexture() {
  const canvas = document.createElement('canvas');
  canvas.width = 320;
  canvas.height = 240;
  const context = canvas.getContext('2d');
  if (context) {
    context.fillStyle = '#06100b';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = '#62b47b';
    context.fillRect(24, 198, 10, 18);
  }
  return configureTexture(new CanvasTexture(canvas));
}

function createUseHintTexture() {
  const canvas = document.createElement('canvas');
  canvas.width = 512;
  canvas.height = 96;
  const context = canvas.getContext('2d');
  if (context) {
    context.fillStyle = '#e9dfc5';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.strokeStyle = '#635d50';
    context.lineWidth = 8;
    context.strokeRect(6, 6, canvas.width - 12, canvas.height - 12);
    context.fillStyle = '#282b27';
    context.font = '600 38px system-ui, sans-serif';
    context.textAlign = 'center';
    context.textBaseline = 'middle';
    context.fillText('CLICK TO USE', canvas.width / 2, canvas.height / 2 + 1);
  }
  return configureTexture(new CanvasTexture(canvas));
}

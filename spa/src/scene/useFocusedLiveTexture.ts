import { useEffect, useMemo, useRef, useState } from 'react';
import { invalidate, useFrame } from '@react-three/fiber';
import {
  LinearFilter,
  SRGBColorSpace,
  VideoFrameTexture,
} from 'three';
import { useMuseum } from '../state/store';
import { bindingFromManifest } from '../three/archetypeRegistry';
import { StreamClient, type StreamClientStats } from '../three/streamClient';
import { streamhostSignalFor } from '../three/streamSignal';

type FocusedLivePhase = 'idle' | 'connecting' | 'live' | 'error';

interface FocusedLiveResult {
  texture: VideoFrameTexture | null;
  phase: FocusedLivePhase;
  streamable: boolean;
}

interface LiveScreenDebug {
  tileId: string | null;
  phase: FocusedLivePhase;
  framesPresented: number;
  client: StreamClientStats | null;
}

let liveDebug: LiveScreenDebug = {
  tileId: null,
  phase: 'idle',
  framesPresented: 0,
  client: null,
};

if (import.meta.env.DEV && typeof window !== 'undefined') {
  (window as typeof window & {
    __museumLiveScreenDebug?: () => LiveScreenDebug;
  }).__museumLiveScreenDebug = () => ({ ...liveDebug });
}

/**
 * A view-only, single-attempt stream sink for the focused museum desk.
 * StreamClient retains ownership of signaling, WebTransport, WebCodecs and ABR;
 * this hook only swaps its newest decoded VideoFrame onto a three.js texture.
 */
export function useFocusedLiveTexture(
  tileId: string,
  active: boolean,
): FocusedLiveResult {
  const vm = useMuseum((state) => state.vms.find((entry) => entry.id === tileId));
  const binding = useMemo(() => vm ? bindingFromManifest(vm) : undefined, [vm]);
  const streamable = binding?.transport === 'streamhost';
  const [texture, setTexture] = useState<VideoFrameTexture | null>(null);
  const [phase, setPhase] = useState<FocusedLivePhase>('idle');
  const queuedFrame = useRef<VideoFrame | null>(null);
  const displayedFrame = useRef<VideoFrame | null>(null);
  const clientRef = useRef<StreamClient | null>(null);
  const textureRef = useRef<VideoFrameTexture | null>(null);
  const framesPresented = useRef(0);

  useFrame(() => {
    const frame = queuedFrame.current;
    const liveTexture = textureRef.current;
    if (!active || !frame || !liveTexture) return;
    queuedFrame.current = null;
    liveTexture.setFrame(frame);
    closeFrame(displayedFrame.current);
    displayedFrame.current = frame;
    framesPresented.current += 1;
    liveDebug.framesPresented = framesPresented.current;
    liveDebug.client = clientRef.current?.getStats() ?? null;
    invalidate();
  });

  useEffect(() => {
    if (!active) {
      setTexture(null);
      setPhase('idle');
      return undefined;
    }
    if (!binding || !streamable || typeof VideoDecoder === 'undefined') {
      setTexture(null);
      setPhase('error');
      return undefined;
    }

    let stopped = false;
    let firstFrame = true;
    let firstFrameTimer = 0;
    const liveTexture = new VideoFrameTexture();
    liveTexture.colorSpace = SRGBColorSpace;
    liveTexture.minFilter = LinearFilter;
    liveTexture.magFilter = LinearFilter;
    liveTexture.generateMipmaps = false;
    textureRef.current = liveTexture;
    framesPresented.current = 0;
    setPhase('connecting');
    liveDebug = {
      tileId,
      phase: 'connecting',
      framesPresented: 0,
      client: null,
    };

    const releaseFramesAndTexture = () => {
      closeFrame(queuedFrame.current);
      closeFrame(displayedFrame.current);
      queuedFrame.current = null;
      displayedFrame.current = null;
      if (textureRef.current === liveTexture) textureRef.current = null;
      liveTexture.dispose();
      setTexture(null);
    };

    const stop = (nextPhase: 'idle' | 'error') => {
      if (stopped) return;
      stopped = true;
      if (firstFrameTimer) window.clearTimeout(firstFrameTimer);
      const client = clientRef.current;
      clientRef.current = null;
      client?.dispose();
      releaseFramesAndTexture();
      setPhase(nextPhase);
      liveDebug = {
        tileId: null,
        phase: nextPhase,
        framesPresented: framesPresented.current,
        client: null,
      };
      invalidate();
    };

    const client = new StreamClient({
      signalEndpoint: streamhostSignalFor(binding),
      onVideoFrame: (frame) => {
        if (stopped) {
          closeFrame(frame);
          return;
        }
        closeFrame(queuedFrame.current);
        queuedFrame.current = frame;
        if (firstFrame) {
          firstFrame = false;
          if (firstFrameTimer) window.clearTimeout(firstFrameTimer);
          setTexture(liveTexture);
          setPhase('live');
          liveDebug.phase = 'live';
        }
        invalidate();
      },
      onState: (connected) => {
        if (stopped) return;
        if (!connected) stop('error');
      },
    });
    clientRef.current = client;
    liveDebug.client = client.getStats();
    firstFrameTimer = window.setTimeout(() => stop('error'), 15000);
    void client.connect().catch(() => stop('error'));

    const leave = () => stop('idle');
    const hide = () => {
      if (document.visibilityState === 'hidden') leave();
    };
    window.addEventListener('pagehide', leave);
    document.addEventListener('visibilitychange', hide);
    return () => {
      window.removeEventListener('pagehide', leave);
      document.removeEventListener('visibilitychange', hide);
      stop('idle');
    };
  }, [active, binding, streamable, tileId]);

  return { texture, phase, streamable };
}

function closeFrame(frame: VideoFrame | null) {
  try {
    frame?.close();
  } catch {
    // Already closed by a racing decoder teardown.
  }
}

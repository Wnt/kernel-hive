import { useEffect, useMemo, useRef, useState } from 'react';
import StreamView from '../ui/grid/StreamView';
import type { OSBinding } from '../three/archetypeRegistry';
import type { EnrichedVM } from '../types';
import type { WalkinClaim } from '../data/walkinTypes';
import { posterFor } from '../data/posterIndex';
import {
  POSTER_FALLBACK_CAPTION,
  heroCaption,
  pickMediaSize,
  statusCells,
  type HeroRunState,
  type MediaSize,
} from './heroStatus';
import { heroBlockedLine } from './heroPolicy';
import { stationCopy } from './stations';
import { ConversionGate } from './gate/ConversionGate';
import { ChromeDockContext } from '../ui/chromeDock';
import type { HeroSession } from './useHeroSession';

// ============================================================================
//  landing/HeroStage — the running machine, which is the page.
//  ---------------------------------------------------------------------------
//  Above the fold there is one object and it is a computer. The status strip
//  above it and the caption below it exist to make the claim it is making
//  checkable ("that really is a live 1993 machine, and those really are my
//  keystrokes"); everything else on the page is arranged around it.
//
//  HOW THE STREAM IS MOUNTED. Exactly the way walkin/WalkinPlay.tsx does it,
//  because that is the proven path: a CLAIM comes back with the clone's own
//  signaling endpoint, that endpoint is wrapped in a synthetic OSBinding, and
//  StreamView is mounted on it — keyed by the clone, so a switch is a new
//  mount and never a re-render that would leave the previous machine's last
//  frame on screen. The only difference here is cosmetic: display name,
//  archetype, accent and era label come from the manifest row when we have
//  one, so the hero says "Windows 3.11" rather than "win311".
//
//  WHY THE CANVAS IS EMPTY. StreamView floats its chrome in the picture's own
//  corners, which is right when the picture is the whole screen and wrong here:
//  a 44px pill laid on a 400x300 rendering of a 1024x768 desktop covers a tenth
//  of the exhibit, and the on-screen keyboard — a sibling below the stage —
//  took its whole height out of a fixed 4:3 box and squeezed the guest into a
//  letterbox slit. So this page hands StreamView two nodes BELOW the canvas
//  (ui/chromeDock) and every control portals itself into one of them. The
//  canvas shows the guest and nothing on top of it, and the picture does not
//  move when the keyboard opens. The one thing still laid over it is the
//  conversion wall, which is meant to cover the frozen frame.
//
//  WHY THE ELEMENT IS MEMOISED. This subtree re-renders once a second (the
//  countdown, the grace clock). StreamView is the heaviest component in the
//  app. Holding its ELEMENT identity across those ticks is what keeps the
//  1 Hz clock from re-rendering the whole streaming client with it.
// ============================================================================

/** The station shown when there is nothing live to show. The door's first
 *  machine, so a browser that cannot stream still sees what it is missing. */
const POSTER_STATION = 'win311';

/** The station view's binding for a clone: the STATION's identity, the CLONE's
 *  endpoint. Functionally identical to WalkinPlay's `cloneBinding` — the extra
 *  fields are the manifest's own cosmetics and nothing that changes behaviour. */
function heroBinding(station: string, claim: WalkinClaim, vm: EnrichedVM | undefined): OSBinding {
  return {
    osId: station,
    displayName: vm?.displayName ?? stationCopy(station).name,
    archetypeId: vm?.archetypeId ?? 'beige-tower-crt',
    transport: 'streamhost',
    accentColor: vm?.accent ?? stationCopy(station).accent,
    eraLabel: vm?.eraLabel ?? 'your own copy',
    signalEndpoint: claim.signalEndpoint,
  };
}

/**
 * The decoded picture's real size, read off whatever the stream mounted.
 *
 * There is no resolution in the gallery manifest and no prop on StreamView that
 * would carry one out (the file is at its 600-line hard cap and may not grow),
 * so the strip asks the picture itself: a `<video>` knows its videoWidth once a
 * frame has decoded, and Firefox's direct-paint `<canvas>` knows its width. A
 * non-zero answer is also the page's proof that frames are ARRIVING, which is
 * what lets the strip say RUNNING without inferring it from a log.
 */
function useDecodedSize(ref: React.RefObject<HTMLElement | null>, clone: string | null): MediaSize | null {
  const [size, setSize] = useState<MediaSize | null>(null);
  useEffect(() => {
    if (clone === null) { setSize(null); return; }
    const read = () => {
      const root = ref.current;
      if (!root) return;
      const video = root.querySelector('video');
      const canvas = root.querySelector('canvas');
      const next = pickMediaSize([
        { width: video?.videoWidth, height: video?.videoHeight },
        { width: canvas?.width, height: canvas?.height },
      ]);
      setSize((prev) => (prev?.width === next?.width && prev?.height === next?.height ? prev : next));
    };
    read();
    const timer = setInterval(read, 1000);
    return () => clearInterval(timer);
  }, [ref, clone]);
  return size;
}

/** A trusted press or key on the stage — the thing that stops the aggressive
 *  release. Untrusted events are ignored: a dispatched click is software, and
 *  "somebody is here" is a fact about a person. */
function useStageInput(ref: React.RefObject<HTMLElement | null>, note: () => void, live: boolean) {
  useEffect(() => {
    if (!live) return;
    const el = ref.current;
    if (!el) return;
    const onEdge = (event: Event) => { if (event.isTrusted) note(); };
    const opts = { capture: true, passive: true } as const;
    for (const type of ['pointerdown', 'touchstart', 'wheel'] as const) {
      el.addEventListener(type, onEdge, opts);
    }
    // Keys never reach the stage element — StreamView forwards them to the
    // guest from the window — so they are counted at the window instead, minus
    // anything typed into a real form field further down the page.
    const onKey = (event: KeyboardEvent) => {
      if (!event.isTrusted) return;
      const focused = document.activeElement?.tagName ?? '';
      if (focused === 'INPUT' || focused === 'TEXTAREA' || focused === 'SELECT') return;
      note();
    };
    window.addEventListener('keydown', onKey, opts);
    return () => {
      for (const type of ['pointerdown', 'touchstart', 'wheel'] as const) {
        el.removeEventListener(type, onEdge, opts);
      }
      window.removeEventListener('keydown', onKey, opts);
    };
  }, [ref, note, live]);
}

function runStateOf(hero: HeroSession, size: MediaSize | null): HeroRunState {
  if (!hero.playable) return 'poster';
  switch (hero.phase.kind) {
    case 'live':
      return size ? 'running' : 'connecting';
    case 'claiming':
      return 'connecting';
    case 'queued':
      return 'queued';
    case 'stopped':
      return 'stopped';
    default:
      return 'poster';
  }
}

export function HeroStage({
  hero,
  vm,
  onRegistered,
  onSignedIn,
}: {
  hero: HeroSession;
  vm: EnrichedVM | undefined;
  onRegistered: (handle: string) => void;
  onSignedIn: () => void;
}) {
  const stageRef = useRef<HTMLDivElement>(null);
  // Callback refs, not useRef: the dock nodes have to be STATE, or the chrome
  // renders once against a null dock before finding its home. They are mounted
  // in the same commit as the canvas and long before a claim comes back, so a
  // control has never yet been painted in the stage on the way past.
  const [controlsEl, setControlsEl] = useState<HTMLDivElement | null>(null);
  const [keysEl, setKeysEl] = useState<HTMLDivElement | null>(null);
  const dock = useMemo(() => ({ controls: controlsEl, keys: keysEl }), [controlsEl, keysEl]);
  const phase = hero.phase;
  const claim = phase.kind === 'live' ? phase.claim : null;
  const station = hero.station;
  const size = useDecodedSize(stageRef, claim?.clone ?? null);
  useStageInput(stageRef, hero.noteInput, claim !== null);

  const state = runStateOf(hero, size);
  const shown = station ?? POSTER_STATION;
  const copy = stationCopy(shown);
  const poster = posterFor(shown)?.hero;
  const stop = phase.kind === 'stopped' ? phase.reason : undefined;

  // See the header: element identity, not just render output, is what keeps a
  // 1 Hz clock from re-rendering the streaming client every second.
  const stream = useMemo(() => {
    if (!station || !claim) return null;
    return (
      <StreamView
        key={claim.clone}
        os={heroBinding(station, claim, vm)}
        onExit={hero.stop}
        playBootVideo={false}
      />
    );
    // `hero.stop` is stable (useCallback in useHeroSession); depending on the
    // `hero` OBJECT instead would rebuild this element on every tick and defeat
    // the memo entirely.
  }, [station, claim, vm, hero.stop]);

  return (
    <ChromeDockContext.Provider value={dock}>
    <div className="landing-hero__machine">
      <div className="landing-strip" role="status">
        {statusCells({ state, size, lineage: vm?.lineage, station: station ?? undefined })
          .map((cell, index) => (
            <span
              key={cell}
              className={`landing-strip__cell${index === 0 ? ` landing-strip__cell--state landing-strip__cell--${state}` : ''}`}
            >
              {cell}
            </span>
          ))}
      </div>

      <div className="landing-stage" ref={stageRef} style={{ ['--station-accent' as string]: copy.accent }}>
        {stream ?? (
          <div className="landing-stage__poster">
            {poster && <img className="landing-stage__shot" src={poster} alt={`${copy.name} on screen`} />}
            <div className="landing-stage__veil">
              <p className="landing-stage__veil-line">
                {hero.playable ? heroCaption(state, copy.name, stop) : heroBlockedLine(hero.caps)}
              </p>
              {hero.playable && state !== 'connecting' && (
                <button
                  type="button"
                  className="landing-btn landing-btn--primary"
                  onClick={() => { hero.notePresence(); hero.take(null); }}
                >
                  {state === 'queued' ? 'Try another machine' : 'Start a machine'}
                </button>
              )}
            </div>
          </div>
        )}

        {hero.remainingSeconds !== null && hero.budgetSeconds !== null && (
          <ConversionGate
            remainingSeconds={hero.remainingSeconds}
            budgetSeconds={hero.budgetSeconds}
            expired={hero.expired}
            stationTitle={copy.name}
            onRegistered={onRegistered}
            onSignedIn={onSignedIn}
          />
        )}
      </div>

      <p className="landing-caption">
        {hero.playable ? heroCaption(state, station ? copy.name : null, stop) : POSTER_FALLBACK_CAPTION}
        {state === 'running' && !hero.driven && hero.graceLeft > 0 && (
          <span className="landing-caption__grace">
            {' '}Touch it within {hero.graceLeft}s or it goes back to the pool for the next visitor.
          </span>
        )}
      </p>

      {/* Everything StreamView would otherwise float on the picture: the back
          and ☰ buttons, the right-click arm, the keyboard opener, and the
          connection/device notices. Both nodes collapse when empty. */}
      <div className="landing-dock" ref={setControlsEl} />
      <div className="landing-keys" ref={setKeysEl} />
    </div>
    </ChromeDockContext.Provider>
  );
}

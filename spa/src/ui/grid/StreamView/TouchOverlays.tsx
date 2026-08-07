import type { RefObject } from 'react';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import type { GestureState } from './types';
import type { TouchControl } from './useTouchControl';
import type { PresentAspect } from '../presentAspect';
import { TouchControlBadge } from './TouchControlBadge';
import { Coachmark } from './Coachmark';
import { OnScreenCursor } from './OnScreenCursor';

// ---------------------------------------------------------------------------
//  TouchOverlays — the mobile stage's touch affordance stack, split out of
//  StreamView (which is at its line budget). Mounted only while mobile + live.
//    - DIRECT (absolute): the armed-state badge (one-shot right-click arm).
//    - TRACKPAD (relative): abs tiles get the OnScreenCursor sprite (T-3);
//      rel tiles need none (the guest draws its own cursor).
//  The one-time coachmark is always present.
// ---------------------------------------------------------------------------

export function TouchOverlays({
  touch,
  gestureRef,
  control,
  pointerRel,
  onPan,
  presentAspect = null,
}: {
  touch: TouchControl;
  gestureRef: RefObject<GestureState>;
  control: StreamControlHandle | null;
  pointerRel: boolean;
  /** Commit the sprite's edge-follow pan into the view transform (followPan). */
  onPan: (p: { x: number; y: number }) => void;
  // Era-correct 4:3 display aspect for the trackpad sprite's box (presentAspect.ts);
  // null keeps the sprite on the object-fit:contain picture rect.
  presentAspect?: PresentAspect | null;
}) {
  const trackpad = touch.trackpadMode;
  const absTrackpad = trackpad && !pointerRel;

  return (
    <>
      {/* BOTH models right-click through the arm. The trackpad used to use a
          long-press, but a hold is how you take hold of something — it is the
          drag gesture — so the two could not share a still finger. */}
      <TouchControlBadge state={touch.badge} onArm={touch.setArm} />
      <Coachmark open={touch.helpOpen} onClose={touch.dismissHelp} trackpad={trackpad} />
      {absTrackpad && (
        <OnScreenCursor
          cursorRef={touch.cursorRef}
          heldRef={touch.heldRef}
          control={control}
          gestureRef={gestureRef}
          onPan={onPan}
          presentAspect={presentAspect}
        />
      )}
    </>
  );
}

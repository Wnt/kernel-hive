import { useEffect } from 'react';
import { invalidate, useFrame } from '@react-three/fiber';
import {
  Frustum,
  Matrix4,
  Vector3,
} from 'three';
import {
  applyScreenTier,
  clearFocusedScreen,
  screenRegistrations,
  setFocusedScreenNdc,
  setScreenVisibilityDebug,
  updateFocusedScreen,
  type ScreenRegistration,
} from './screenTiers';

const NEAR_DISTANCE = 4;
const MAX_PLAYING_VIDEOS = 6;
const FOCUS_WINDOW_X = 0.55;
const FOCUS_WINDOW_Y = 0.65;

/**
 * One small demand-loop coordinator for every screen. It chooses exactly one
 * visible focus, limits decoded boot loops to six, and only changes React
 * state when a screen crosses a tier boundary.
 */
export default function ScreenTierManager() {
  const point = new Vector3();
  const ndcPoint = new Vector3();
  const toScreen = new Vector3();
  const direction = new Vector3();
  const projection = new Matrix4();
  const frustum = new Frustum();

  useFrame(({ camera }) => {
    camera.updateMatrixWorld();
    projection.multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse);
    frustum.setFromProjectionMatrix(projection);
    camera.getWorldDirection(direction);

    const visible: Array<{
      registration: ScreenRegistration;
      distance: number;
      ndcX: number;
      ndcY: number;
    }> = [];
    for (const registration of screenRegistrations.values()) {
      registration.object.getWorldPosition(point);
      const inFront = toScreen.subVectors(point, camera.position).dot(direction) > 0;
      if (inFront && frustum.containsPoint(point)) {
        ndcPoint.copy(point).project(camera);
        visible.push({
          registration,
          distance: camera.position.distanceTo(point),
          ndcX: ndcPoint.x,
          ndcY: ndcPoint.y,
        });
      } else {
        applyScreenTier(registration, 'culled');
      }
    }

    visible.sort((a, b) => a.distance - b.distance);
    if (import.meta.env.DEV) {
      setScreenVisibilityDebug(visible.map(({ registration, distance, ndcX, ndcY }) => ({
        tileId: registration.tileId,
        distance,
        ndc: [ndcX, ndcY],
      })));
    }
    const focusable = visible.filter(({ ndcX, ndcY }) =>
      Math.abs(ndcX) <= FOCUS_WINDOW_X && Math.abs(ndcY) <= FOCUS_WINDOW_Y,
    );
    focusable.sort((a, b) =>
      Math.hypot(a.ndcX, a.ndcY) - Math.hypot(b.ndcX, b.ndcY)
      || a.distance - b.distance,
    );
    const focused = focusable[0]?.registration ?? visible[0]?.registration ?? null;
    let playingVideos = 0;
    visible.forEach(({ registration, distance }) => {
      if (registration === focused) {
        applyScreenTier(registration, 'focused');
        if (registration.animated) playingVideos += 1;
        return;
      }
      const canAnimate = !registration.animated || playingVideos < MAX_PLAYING_VIDEOS;
      if (distance <= NEAR_DISTANCE && canAnimate) {
        applyScreenTier(registration, 'near');
        if (registration.animated) playingVideos += 1;
      } else {
        applyScreenTier(registration, 'far');
      }
    });
    updateFocusedScreen(focused);
    if (focused) {
      focused.object.getWorldPosition(point).project(camera);
      setFocusedScreenNdc([point.x, point.y]);
    } else {
      setFocusedScreenNdc(null);
    }
  });

  useEffect(() => {
    const onVisibility = () => {
      if (document.visibilityState === 'hidden') clearFocusedScreen();
      else invalidate();
    };
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      clearFocusedScreen();
    };
  }, []);

  return null;
}

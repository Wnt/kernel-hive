# Live screens Phase B wiring plan

Phase A deliberately stops at boot loops and posters. The local Vite origin
does not expose production `/signal/<tile>.json` or `/boot/` media, and the
streamhost fleet must not be changed merely to validate a presentation-layer
patch. Focused live video should be added as a read-only viewer in this order.

## Focus ownership

Extend the existing screen registration in `spa/src/scene/screenTiers.ts` with
`tileId`, then have `ScreenTierManager` publish the one registration assigned
`focused`. A tiny external-store subscription is preferable to React context:
there is one focus value, and changing it must not rerender all 22 exhibits.

The focus store should expose `{ tileId, texture }`, where `texture` is null
until the first decoded frame. `ScreenPlane` keeps showing its Phase A content
until that texture is ready. A focus change must synchronously dispose the old
viewer before opening the next one, so there can never be two live sessions.

## Decode-to-texture path

Add a `useFocusedLiveTexture(tileId, focused)` hook alongside the existing
`useLiveStream` seam:

1. Resolve the registry binding and reject showcase entries.
2. Construct one `VideoFrameTexture` and configure sRGB/linear filtering.
3. Construct `StreamClient` with
   `streamhostSignalFor(binding)` and an `onVideoFrame` sink.
4. Keep only the newest not-yet-presented `VideoFrame`; close any superseded
   queued frame immediately.
5. In a `useFrame` callback, call `texture.setFrame(queuedFrame)`, close the
   previously displayed frame, clear the queue, and `invalidate()`. The current
   displayed frame remains open until replacement because three.js uploads it
   during the render that follows the callback.
6. On focus loss/unmount: `StreamClient.dispose()`, close queued and displayed
   frames, dispose the texture, and clear the focus-store texture.

This bypasses `useStreamhostSession`'s canvas/capture-stream path without
forking transport, signaling, codec, ABR, or retry behavior. The first
implementation should be view-only: no control handle and audio disabled.

## Tier and failure behavior

- Only `focused` may own a `StreamClient`.
- A live frame replaces the boot/poster texture only after the first successful
  decode; connecting and errors remain visually silent.
- On focus loss, the screen returns immediately to its Phase A boot/poster
  policy.
- On transport/decode failure, dispose the viewer and retain the poster. A
  later focus change may retry; do not add an independent reconnect loop around
  `StreamClient`.
- Page hide and route unmount must leave zero clients and zero open frames.

### Implementation note (Phase B)

The shipped requirement added a subtle connecting shimmer after this plan was
written, so connecting is no longer completely visually silent. The underlying
boot/poster remains seated on the glass until frame one; only a low-opacity
sweep is layered over it. Errors still return to an unadorned attract state.

The focused viewer intentionally makes one transport attempt per focus
acquisition rather than inheriting `useStreamhostSession`'s session retry loop.
It still reuses `StreamClient` for manifest signaling, WebTransport, WebCodecs,
ABR and teardown. This is the required “retry only on re-focus” behavior and
keeps a failing desk from repeatedly waking a live tile.

Phase B verification also found that Phase A's unweighted “closest frustum
point" focus picked edge-of-view desks across most of the rail, making centered
desks such as TinyCore and HelenOS impossible to focus. Focus now means the most
visually centered screen inside a central NDC acquisition window, with physical
distance as its tiebreak and the original nearest-visible rule as the fallback
when that window is empty. This keeps a closer desk at the edge from stealing
focus from the desk the rail is looking at.
Near/far/culled tiering and the six-attract-video budget are otherwise
unchanged. Click-to-approach likewise chooses the rail sample whose gaze is
closest to the clicked glass, with a small distance tiebreak; physical proximity
alone could park beside a desk while the rail looked down another aisle.

## Production-safe verification

Validate from the deployed HTTPS origin with normal viewer connections only.
Do not restart, reconfigure, restore, or power-cycle any tile or streamhost.
Record: one client in browser telemetry, old-client teardown on three rapid
focus changes, first-frame time, 60-second decoded FPS/drop metrics, and no open
client after leaving `/museum`.

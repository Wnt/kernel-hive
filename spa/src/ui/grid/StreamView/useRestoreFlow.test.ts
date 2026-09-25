// The `resetKeepsStream` branch (D4's ctl-socket reset — nokia9300 and any
// future station whose fixture declares SH_RESET_CTL_SOCK): the hook must
// NOT tear down/reconnect the WebTransport, must settle its telemetry on the
// next painted frame instead of a `phase` transition, and must fall back to
// the ordinary teardown/reconnect path if no frame ever changes. Also covers
// U1 finding B1: a failed restore POST must surface in the page, not just the
// console, on every station (resetKeepsStream or not).
import { createElement } from 'react';
import { act, create } from 'react-test-renderer';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../../analytics', () => ({
  beginFlow: vi.fn(),
  startTiming: vi.fn(),
}));

import { beginFlow, startTiming } from '../../../analytics';
import type { FlowHandle } from '../../../analytics/flows';
import type { Timing } from '../../../analytics/metrics';
import type { LivePhase } from '../../../three/streamSessionTypes';
import { FRAME_WATCH_POLL_MS, FRAME_WATCH_TIMEOUT_MS, useRestoreFlow } from './useRestoreFlow';

// vitest runs these in a node environment; useRestoreFlow schedules its
// polls/timeouts on `window` (same convention as sessionResume.test.ts /
// useTouchGestures.test.ts) — delegate to the real (fake-able) timers.
(globalThis as unknown as { window: unknown }).window ??= {
  setTimeout: (fn: () => void, ms: number) => setTimeout(fn, ms),
  clearTimeout: (id: number) => clearTimeout(id),
  setInterval: (fn: () => void, ms: number) => setInterval(fn, ms),
  clearInterval: (id: number) => clearInterval(id),
};

function flowHandle(): FlowHandle {
  return { step: vi.fn(), ok: vi.fn(), fail: vi.fn(), close: vi.fn(), tag: vi.fn() };
}
function timing(): Timing {
  return { stop: vi.fn(), abandon: vi.fn() };
}

function mount(opts: {
  resetKeepsStream?: boolean;
  frameEpoch?: { current: number };
  phase: LivePhase;
}) {
  const setRestoreState = vi.fn();
  const setRestoreError = vi.fn();
  const restoreTimer = { current: 0 };
  const restoreErrorTimer = { current: 0 };
  const beginRestoreReconnect = vi.fn();
  const finishRestoreReconnect = vi.fn();
  let api: { restoreToGolden: () => void } | null = null;
  function Probe({ phase }: { phase: LivePhase }) {
    const r = useRestoreFlow({
      osId: 'nokia9300',
      restoreState: 'idle',
      setRestoreState,
      setRestoreError,
      restoreErrorTimer,
      beginRestoreReconnect,
      finishRestoreReconnect,
      restoreTimer,
      phase,
      resetKeepsStream: opts.resetKeepsStream,
      frameEpoch: opts.frameEpoch,
    });
    api = r;
    return null;
  }
  let renderer: ReturnType<typeof create>;
  act(() => { renderer = create(createElement(Probe, { phase: opts.phase })); });
  return {
    restoreToGolden: () => act(() => { api!.restoreToGolden(); }),
    setRestoreState, setRestoreError, beginRestoreReconnect, finishRestoreReconnect,
    rerender: (phase: LivePhase) => act(() => { renderer.update(createElement(Probe, { phase })); }),
  };
}

async function flushMicrotasks() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  });
}

describe('useRestoreFlow', () => {
  let handle: FlowHandle;

  beforeEach(() => {
    vi.useFakeTimers();
    handle = flowHandle();
    vi.mocked(beginFlow).mockReturnValue(handle);
    vi.mocked(startTiming).mockReturnValue(timing());
    globalThis.fetch = vi.fn();
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.clearAllMocks();
  });

  it('resetKeepsStream: skips beginRestoreReconnect/finishRestoreReconnect entirely on a successful POST', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValue({ ok: true, status: 200 } as Response);
    const frameEpoch = { current: 5 };
    const h = mount({ resetKeepsStream: true, frameEpoch, phase: 'live' });
    h.restoreToGolden();
    await flushMicrotasks();
    expect(h.beginRestoreReconnect).not.toHaveBeenCalled();
    expect(h.finishRestoreReconnect).not.toHaveBeenCalled();
    expect(h.setRestoreState).toHaveBeenCalledWith('ok');
  });

  it('resetKeepsStream: settles the telemetry flow on the next painted frame, not on `phase`', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValue({ ok: true, status: 200 } as Response);
    const frameEpoch = { current: 5 };
    const h = mount({ resetKeepsStream: true, frameEpoch, phase: 'live' });
    h.restoreToGolden();
    await flushMicrotasks();
    expect(handle.ok).not.toHaveBeenCalled();
    // A frame paints (useStreamhostSession's frameEpoch ref bumps on decode).
    frameEpoch.current++;
    await act(async () => { await vi.advanceTimersByTimeAsync(FRAME_WATCH_POLL_MS); });
    expect(handle.ok).toHaveBeenCalledTimes(1);
    // Still never fell back to a teardown/reconnect.
    expect(h.beginRestoreReconnect).not.toHaveBeenCalled();
    expect(h.finishRestoreReconnect).not.toHaveBeenCalled();
  });

  it('resetKeepsStream: falls back to the teardown/reconnect path if no frame ever changes', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValue({ ok: true, status: 200 } as Response);
    const frameEpoch = { current: 5 };
    const h = mount({ resetKeepsStream: true, frameEpoch, phase: 'live' });
    h.restoreToGolden();
    await flushMicrotasks();
    expect(h.beginRestoreReconnect).not.toHaveBeenCalled();
    await act(async () => { await vi.advanceTimersByTimeAsync(FRAME_WATCH_TIMEOUT_MS); });
    expect(h.beginRestoreReconnect).toHaveBeenCalledTimes(1);
    expect(h.finishRestoreReconnect).toHaveBeenCalledTimes(1);
    expect(handle.ok).not.toHaveBeenCalled(); // settling is left to the ordinary `phase` effect now
  });

  it('without resetKeepsStream, the old teardown/reconnect path runs unchanged', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValue({ ok: true, status: 200 } as Response);
    const h = mount({ resetKeepsStream: false, phase: 'connecting' });
    h.restoreToGolden();
    // Called synchronously, before the fetch resolves — same as before this branch existed.
    expect(h.beginRestoreReconnect).toHaveBeenCalledTimes(1);
    await flushMicrotasks();
    expect(h.finishRestoreReconnect).toHaveBeenCalledTimes(1);
  });

  it('a station with resetKeepsStream declared but no frameEpoch (session not open yet) falls back too', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValue({ ok: true, status: 200 } as Response);
    const h = mount({ resetKeepsStream: true, frameEpoch: undefined, phase: 'connecting' });
    h.restoreToGolden();
    expect(h.beginRestoreReconnect).toHaveBeenCalledTimes(1);
    await flushMicrotasks();
    expect(h.finishRestoreReconnect).toHaveBeenCalledTimes(1);
  });

  // U1 finding B1: the restore POST's 404/error used to be console-only — the
  // visitor saw the controls panel close and nothing else. Applies regardless
  // of resetKeepsStream, since the failure is in the fetch, before either
  // branch's completion signal is even reached.
  it('a 404 from the restore POST surfaces an in-page error, not just the console', async () => {
    vi.mocked(globalThis.fetch).mockResolvedValue({ ok: false, status: 404 } as Response);
    const h = mount({ resetKeepsStream: false, phase: 'live' });
    h.restoreToGolden();
    await flushMicrotasks();
    expect(h.setRestoreError).toHaveBeenCalledWith(expect.stringContaining('404'));
    expect(h.setRestoreState).toHaveBeenCalledWith('err');
    expect(handle.fail).toHaveBeenCalledWith('resetFailed');
  });

  it('a network error from the restore POST also surfaces in-page (resetKeepsStream branch)', async () => {
    vi.mocked(globalThis.fetch).mockRejectedValue(new Error('network down'));
    const frameEpoch = { current: 0 };
    const h = mount({ resetKeepsStream: true, frameEpoch, phase: 'live' });
    h.restoreToGolden();
    await flushMicrotasks();
    expect(h.setRestoreError).toHaveBeenCalledWith(expect.stringContaining('network down'));
    // Never began a reconnect it did not need — the transport is still live.
    expect(h.beginRestoreReconnect).not.toHaveBeenCalled();
  });
});

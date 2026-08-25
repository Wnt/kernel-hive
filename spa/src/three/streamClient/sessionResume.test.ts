// The Mode D fix, pinned (STREAM-DEBUGGING.md): a session whose retry ladder
// exhausted used to park in `phase error` FOREVER, even after the network came
// back. These guard the recovery probe: parked + signaling reachable →
// reconnect; parked + unreachable → keep quietly probing, bounded; not parked
// → no probes at all.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('./signal', () => ({ fetchSignal: vi.fn() }));
vi.mock('../clientDebug', () => ({ logClientEvent: vi.fn() }));

import { fetchSignal } from './signal';
import { logClientEvent } from '../clientDebug';
import {
  attachSessionResume,
  RECOVERY_PROBE_MS,
  MAX_RECOVERY_ROUNDS,
  type ResumeWatcherDeps,
} from './sessionResume';

const fetchSignalMock = vi.mocked(fetchSignal);
const logMock = vi.mocked(logClientEvent);

// vitest runs in a node environment; give sessionResume the browser surface it
// guards on. Delegating wrappers (not captured references) so fake timers work.
type Handler = () => void;
let onlineHandlers: Handler[];
beforeEach(() => {
  vi.useFakeTimers();
  onlineHandlers = [];
  vi.stubGlobal('window', {
    setInterval: (fn: Handler, ms: number) => setInterval(fn, ms),
    clearInterval: (id: number) => clearInterval(id),
    setTimeout: (fn: Handler, ms: number) => setTimeout(fn, ms),
    clearTimeout: (id: number) => clearTimeout(id),
    addEventListener: (type: string, fn: Handler) => { if (type === 'online') onlineHandlers.push(fn); },
    removeEventListener: () => undefined,
  });
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
  vi.clearAllMocks();
});

const makeDeps = (over: Partial<Omit<ResumeWatcherDeps, 'reconnect'>> = {}) => ({
  isCancelled: () => false,
  isLiveReached: () => true,
  isParked: () => true,
  signalEndpoint: '/signal/win98se',
  getClient: () => null,
  reconnect: vi.fn(),
  ...over,
});

describe('error-phase recovery probe', () => {
  it('reconnects once signaling answers, and says so in telemetry', async () => {
    fetchSignalMock.mockRejectedValueOnce(new Error('offline'));
    fetchSignalMock.mockResolvedValue({} as never);
    const deps = makeDeps();
    const detach = attachSessionResume(deps);

    await vi.advanceTimersByTimeAsync(RECOVERY_PROBE_MS); // probe 1: still offline
    expect(deps.reconnect).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(RECOVERY_PROBE_MS); // probe 2: reachable
    expect(deps.reconnect).toHaveBeenCalledTimes(1);
    expect(logMock).toHaveBeenCalledWith('recovery-reconnect', expect.stringContaining('restarting the ladder'));
    detach();
  });

  it('never probes while the session is not parked', async () => {
    const deps = makeDeps({ isParked: () => false });
    const detach = attachSessionResume(deps);
    await vi.advanceTimersByTimeAsync(RECOVERY_PROBE_MS * 5);
    expect(fetchSignalMock).not.toHaveBeenCalled();
    expect(deps.reconnect).not.toHaveBeenCalled();
    detach();
  });

  it('is bounded: stops probing after MAX_RECOVERY_ROUNDS and logs the give-up once', async () => {
    fetchSignalMock.mockRejectedValue(new Error('offline'));
    const deps = makeDeps();
    const detach = attachSessionResume(deps);
    await vi.advanceTimersByTimeAsync(RECOVERY_PROBE_MS * (MAX_RECOVERY_ROUNDS + 5));
    expect(fetchSignalMock).toHaveBeenCalledTimes(MAX_RECOVERY_ROUNDS);
    expect(logMock).toHaveBeenCalledWith('recovery-giveup', expect.stringContaining('unreachable'));
    expect(logMock.mock.calls.filter(([ev]) => ev === 'recovery-giveup')).toHaveLength(1);
    expect(deps.reconnect).not.toHaveBeenCalled();
    detach();
  });

  it('the online event probes immediately — no waiting out the interval', async () => {
    fetchSignalMock.mockResolvedValue({} as never);
    const deps = makeDeps();
    const detach = attachSessionResume(deps);
    expect(onlineHandlers).toHaveLength(1);
    onlineHandlers[0]();
    await vi.advanceTimersByTimeAsync(0); // let the probe's microtasks settle
    expect(deps.reconnect).toHaveBeenCalledTimes(1);
    detach();
  });

  it('detach stops the probe loop', async () => {
    fetchSignalMock.mockRejectedValue(new Error('offline'));
    const deps = makeDeps();
    const detach = attachSessionResume(deps);
    await vi.advanceTimersByTimeAsync(RECOVERY_PROBE_MS);
    expect(fetchSignalMock).toHaveBeenCalledTimes(1);
    detach();
    await vi.advanceTimersByTimeAsync(RECOVERY_PROBE_MS * 3);
    expect(fetchSignalMock).toHaveBeenCalledTimes(1);
  });
});

import { describe, expect, it } from 'vitest';
import { stationAttrs } from './stationAttrs';

describe('stationAttrs — the grouping dimensions attached to station-scoped spans', () => {
  it('returns nothing for a missing source, rather than throwing', () => {
    expect(stationAttrs(undefined)).toEqual({});
    expect(stationAttrs(null)).toEqual({});
  });

  it('maps every field to its kh.station.* name', () => {
    expect(
      stationAttrs({ osId: 'beos', emulatorFamily: 'QEMU', uiKind: 'desktop', resetMode: 'loadvm' }),
    ).toEqual({
      'kh.station.id': 'beos',
      'kh.station.emulatorFamily': 'QEMU',
      'kh.station.ui': 'desktop',
      'kh.station.resetMode': 'loadvm',
    });
  });

  it('omits a field the source does not have — a poster row has no resetMode', () => {
    expect(stationAttrs({ osId: 'riscos', emulatorFamily: 'RPCEmu' })).toEqual({
      'kh.station.id': 'riscos',
      'kh.station.emulatorFamily': 'RPCEmu',
    });
  });
});

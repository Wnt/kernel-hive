import { describe, expect, it } from 'vitest';
import { pinnedStation, stationPath, urlCorrection } from './stationUrl';

const KNOWN = ['win311', 'os2warp', 'rhapsody'] as const;

describe('pinnedStation', () => {
  it('pins a station the door actually offers', () => {
    expect(pinnedStation('win311', KNOWN)).toBe('win311');
  });

  it('falls back to the broker for a station we do not serve', () => {
    // A stale bookmark must not turn into a claim for a machine that is gone.
    expect(pinnedStation('amiga4000', KNOWN)).toBeNull();
  });

  it('treats a missing or empty param as unpinned', () => {
    expect(pinnedStation(undefined, KNOWN)).toBeNull();
    expect(pinnedStation('', KNOWN)).toBeNull();
  });

  it('does not let visitor-controlled text through', () => {
    expect(pinnedStation('../../etc/passwd', KNOWN)).toBeNull();
    expect(pinnedStation('win311 ', KNOWN)).toBeNull();
  });
});

describe('urlCorrection', () => {
  it('publishes the broker-picked station onto the root URL', () => {
    expect(urlCorrection('/', 'os2warp')).toBe('/walkin/os2warp');
  });

  it('leaves the URL alone once it already names the live station', () => {
    expect(urlCorrection('/walkin/os2warp', 'os2warp')).toBeNull();
  });

  it('follows a switch to another station', () => {
    expect(urlCorrection('/walkin/os2warp', 'rhapsody')).toBe('/walkin/rhapsody');
  });

  it('publishes nothing while no machine is on screen', () => {
    // A refusal, a closed door or a spent budget must not mint an address that
    // promises a machine the visitor never got.
    expect(urlCorrection('/', null)).toBeNull();
    expect(urlCorrection('/walkin/win311', null)).toBeNull();
  });

  it('refuses to rewrite a route that is not the landing page', () => {
    expect(urlCorrection('/museum', 'win311')).toBeNull();
    expect(urlCorrection('/os/irix', 'win311')).toBeNull();
    expect(urlCorrection('/admin/walkin', 'win311')).toBeNull();
  });
});

describe('stationPath', () => {
  it('is the address the router matches and the gate opens', () => {
    expect(stationPath('rhapsody')).toBe('/walkin/rhapsody');
  });
});

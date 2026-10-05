// Tests for analytics/telemetryPaths: the one list of our own telemetry
// endpoints, and the pathname matcher khFetch.ts derives from it.

import { describe, expect, it } from 'vitest';
import { IGNORE_URL_PATTERNS, KH_TELEMETRY_PATHS } from './telemetryPaths';

describe('IGNORE_URL_PATTERNS', () => {
  it('matches the bare pathname of every telemetry endpoint', () => {
    for (const path of KH_TELEMETRY_PATHS) {
      expect(IGNORE_URL_PATTERNS.some((re) => re.test(path))).toBe(true);
    }
  });

  it('matches below an endpoint too — the whole subtree is our own plumbing', () => {
    expect(IGNORE_URL_PATTERNS.some((re) => re.test('/analytics/report.json'))).toBe(true);
  });

  it('is anchored for a pathname, so it never matches a full URL', () => {
    for (const path of KH_TELEMETRY_PATHS) {
      expect(IGNORE_URL_PATTERNS.some((re) => re.test(`https://kernelhive.madekivi.fi${path}`))).toBe(false);
    }
  });

  it('matches no real app route', () => {
    for (const real of ['/auth/state', '/gallery-manifest.json', '/boot/index.json', '/signal/solaris.json']) {
      expect(IGNORE_URL_PATTERNS.some((re) => re.test(real))).toBe(false);
    }
  });

  it('is derived one-to-one from the endpoint list', () => {
    expect(IGNORE_URL_PATTERNS).toHaveLength(KH_TELEMETRY_PATHS.length);
  });
});

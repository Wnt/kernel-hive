/*
 * The About page renders whatever /release-notes.json says, so the only logic
 * worth pinning down is the transform in releaseNotesView.ts. Three contracts
 * matter to a reader of /about and are easy to regress:
 *   1. weeks are shown NEWEST FIRST regardless of the order in the document,
 *      and only the newest one is expanded by default (older weeks carry
 *      hundreds of bullets);
 *   2. the in-progress week is flagged — it is the week that is still filling
 *      up, and the generator's --check deliberately ignores it;
 *   3. a "collapsed" Dependencies section renders as a count line only. The
 *      generator sends it with an EMPTY entries list, so the count field is the
 *      only source of the number — reading entries.length would silently print 0.
 */
import { describe, expect, it } from 'vitest';
import type { ReleaseNotesDoc, ReleaseSection, ReleaseWeek } from '../data/releaseNotes';
import { releaseWeekViews } from './releaseNotesView';

function week(number: number, overrides: Partial<ReleaseWeek> = {}): ReleaseWeek {
  return {
    number,
    start: `2026-08-${String(2 + number * 7).padStart(2, '0')}T09:00:00+03:00`,
    end: `2026-08-${String(9 + number * 7).padStart(2, '0')}T09:00:00+03:00`,
    startDate: `2026-08-${String(2 + number * 7).padStart(2, '0')}`,
    endDate: `2026-08-${String(9 + number * 7).padStart(2, '0')}`,
    inProgress: false,
    commitCount: 3,
    sections: [],
    ...overrides,
  };
}

function doc(weeks: ReleaseWeek[]): ReleaseNotesDoc {
  return {
    cutoff: 'Sunday 09:00 Europe/Helsinki',
    epoch: '2026-08-07T14:37:08+03:00',
    generatedFrom: '9ac042b',
    weeks,
  };
}

const STATIONS: ReleaseSection = {
  title: 'Stations',
  count: 2,
  entries: [
    { scope: 'tru64', text: 'Web browser applied to the live golden', sha: 'abcdef1', date: '2026-08-23' },
    { scope: 'hpuxvue', text: 'NCSA Mosaic on the retronet web plane', sha: '1234567', date: '2026-08-23' },
  ],
};

const DEPENDENCIES: ReleaseSection = { title: 'Dependencies', count: 4, entries: [], collapsed: true };

describe('releaseWeekViews', () => {
  it('presents weeks newest-first even when the document is oldest-first', () => {
    const views = releaseWeekViews(doc([week(1), week(2), week(3)]));
    expect(views.map((v) => v.number)).toEqual([3, 2, 1]);
    expect(views.map((v) => v.heading)).toEqual(['Week 3', 'Week 2', 'Week 1']);
  });

  it('expands only the newest week', () => {
    const views = releaseWeekViews(doc([week(3), week(2), week(1)]));
    expect(views.map((v) => v.defaultOpen)).toEqual([true, false, false]);
  });

  it('flags the in-progress week and carries its commit count', () => {
    const views = releaseWeekViews(doc([week(2, { inProgress: true, commitCount: 26 }), week(1)]));
    expect(views[0].inProgress).toBe(true);
    expect(views[0].commits).toBe('26 commits');
    expect(views[1].inProgress).toBe(false);
    expect(views[1].commits).toBe('3 commits');
  });

  it('formats the week range with both boundary TIMES, so the exclusive end is unambiguous', () => {
    // Week N ends and week N+1 starts at the same Sunday 09:00; bare dates made
    // both weeks look like they contained that day.
    const views = releaseWeekViews(doc([week(1, {
      start: '2026-08-16T09:00:00+03:00',
      end: '2026-08-23T09:00:00+03:00',
      startDate: '2026-08-16',
      endDate: '2026-08-23',
    })]));
    expect(views[0].range).toBe('16 Aug 09:00 – 23 Aug 09:00 2026');
  });

  it('keeps week 1 honest: it starts at the first commit, not at 09:00', () => {
    const views = releaseWeekViews(doc([week(1, {
      start: '2026-08-07T14:37:08+03:00',
      end: '2026-08-09T09:00:00+03:00',
      startDate: '2026-08-07',
      endDate: '2026-08-09',
    })]));
    expect(views[0].range).toBe('7 Aug 14:37 – 9 Aug 09:00 2026');
  });

  it('renders a collapsed Dependencies section as a count line with no entries', () => {
    const views = releaseWeekViews(doc([week(1, { sections: [DEPENDENCIES] })]));
    const section = views[0].sections[0];
    expect(section.collapsed).toBe(true);
    expect(section.summary).toBe('4 dependency bumps');
    expect(section.entries).toEqual([]);
    expect(section.defaultOpen).toBe(false);
  });

  it('labels Stations entries with their station id and links each sha', () => {
    const views = releaseWeekViews(doc([week(1, { sections: [STATIONS] })]));
    const section = views[0].sections[0];
    expect(section.summary).toBe('2 changes');
    expect(section.defaultOpen).toBe(true);
    expect(section.entries[0].station).toBe('tru64');
    expect(section.entries[0].href).toBe('https://github.com/Wnt/kernel-hive/commit/abcdef1');
    expect(section.entries[0].text).toBe('Web browser applied to the live golden');
  });

  it('does not label non-Stations entries with a scope pill', () => {
    const other: ReleaseSection = {
      title: 'Gallery UI',
      count: 1,
      entries: [{ scope: 'spa', text: 'Installable PWA', sha: '9ac042b', date: '2026-08-23' }],
    };
    const views = releaseWeekViews(doc([week(1, { sections: [other] })]));
    expect(views[0].sections[0].entries[0].station).toBeNull();
  });

  it('sections of an older week stay collapsed', () => {
    const views = releaseWeekViews(doc([week(2), week(1, { sections: [STATIONS] })]));
    expect(views[1].sections[0].defaultOpen).toBe(false);
  });
});

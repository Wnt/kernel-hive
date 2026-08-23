/*
 * The About page renders whatever /release-notes.json says, so the only logic
 * worth pinning down is the transform in releaseNotesView.ts. Three contracts
 * matter to a reader of /about and are easy to regress:
 *   1. weeks are shown NEWEST FIRST regardless of the order in the document,
 *      and only the newest one is expanded by default;
 *   2. a week carrying a `source` prints the "before the repository was public"
 *      note, and the trigger is that FIELD, not the week number — week 0 is
 *      merely today's only such week;
 *   3. the date range prints both boundary TIMES, because the span is
 *      half-open and consecutive weeks share their boundary instant.
 */
import { describe, expect, it } from 'vitest';
import type { ReleaseNotesDoc, ReleaseWeek } from '../data/releaseNotes';
import { releaseWeekViews } from './releaseNotesView';

function week(number: number, overrides: Partial<ReleaseWeek> = {}): ReleaseWeek {
  const day = (offset: number) => String(2 + number * 7 + offset).padStart(2, '0');
  return {
    week: number,
    title: `Week ${number} happened`,
    start: `2026-08-${day(0)}T09:00:00+03:00`,
    end: `2026-08-${day(7)}T09:00:00+03:00`,
    startDate: `2026-08-${day(0)}`,
    endDate: `2026-08-${day(7)}`,
    commitCount: 3,
    codeLines: 1234,
    summary: [
      { theme: 'New stations', text: 'A machine arrived.' },
      { theme: 'Major features', text: 'Something new works.' },
      { theme: 'Quality improvements', text: 'Something got faster.' },
    ],
    bullets: ['A thing landed', 'Another thing landed'],
    ...overrides,
  };
}

function doc(weeks: ReleaseWeek[]): ReleaseNotesDoc {
  return { cutoff: 'Sunday 09:00 Europe/Helsinki', weeks };
}

describe('releaseWeekViews', () => {
  it('presents weeks newest-first even when the document is oldest-first', () => {
    const views = releaseWeekViews(doc([week(0), week(1), week(2), week(3)]));
    expect(views.map((v) => v.number)).toEqual([3, 2, 1, 0]);
    expect(views.map((v) => v.heading)).toEqual(['Week 3', 'Week 2', 'Week 1', 'Week 0']);
  });

  it('expands only the newest week', () => {
    const views = releaseWeekViews(doc([week(3), week(2), week(1)]));
    expect(views.map((v) => v.defaultOpen)).toEqual([true, false, false]);
  });

  it('carries the title, commit count, summary paragraphs and bullets through', () => {
    const views = releaseWeekViews(doc([week(3, {
      title: 'The retronet signs on',
      commitCount: 336,
      codeLines: 35569,
      summary: [
        { theme: 'New stations', text: 'Seven new machines came online.' },
        { theme: 'Major features', text: 'The museum got its own internet.' },
        { theme: 'Quality improvements', text: 'Restores got faster.' },
      ],
      bullets: ['The retronet gateway is live', 'Seven stations installed from sourced media'],
    })]));
    expect(views[0].title).toBe('The retronet signs on');
    expect(views[0].code).toBe('35,569 lines of code');
    expect(views[0].summary.map((s) => s.theme)).toEqual([
      'New stations',
      'Major features',
      'Quality improvements',
    ]);
    expect(views[0].summary[1].text).toBe('The museum got its own internet.');
    expect(views[0].bullets).toHaveLength(2);
  });

  it('formats the code-line count with thousands separators', () => {
    expect(releaseWeekViews(doc([week(1, { codeLines: 1 })]))[0].code).toBe('1 line of code');
    expect(releaseWeekViews(doc([week(1, { codeLines: 35569 })]))[0].code).toBe('35,569 lines of code');
  });

  it('notes a week summarised from another repository, naming that source', () => {
    const views = releaseWeekViews(doc([week(1), week(0, { source: 'osgallery' })]));
    expect(views[1].sourceNote).toBe(
      'Before the repository was public — summarised from the private osgallery history.',
    );
  });

  it('leaves a week with no source unnoted — the week NUMBER is never the trigger', () => {
    // A hypothetical week 0 with no `source` must not claim a provenance it
    // does not declare, and a sourced week 4 must get the note.
    const views = releaseWeekViews(doc([week(4, { source: 'elsewhere' }), week(0)]));
    expect(views[0].sourceNote).toContain('elsewhere');
    expect(views[1].sourceNote).toBeNull();
  });

  it('formats the week range with both boundary TIMES, so the exclusive end is unambiguous', () => {
    // Week N ends and week N+1 starts at the same Sunday 09:00; bare dates made
    // both weeks look like they contained that day.
    const views = releaseWeekViews(doc([week(3, {
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

  it('spells the year on BOTH ends of a range that crosses new year', () => {
    const views = releaseWeekViews(doc([week(1, {
      start: '2026-12-27T09:00:00+02:00',
      end: '2027-01-03T09:00:00+02:00',
      startDate: '2026-12-27',
      endDate: '2027-01-03',
    })]));
    expect(views[0].range).toBe('27 Dec 2026 09:00 – 3 Jan 2027 09:00');
  });
});

import type { ReleaseNotesDoc, ReleaseSection, ReleaseWeek } from '../data/releaseNotes';

// Pure view model for the About page's release notes. It lives beside
// About.tsx rather than inside it so the ordering / range / note rules are
// testable under vitest's plain-Node environment (vitest.config.ts collects
// src/**/*.test.ts only, and never renders a DOM).
//
// The rules, in one place:
//   * weeks are PRESENTED newest-first — the generator already emits them that
//     way, but sorting here means a hand-edited or reordered document cannot
//     show week 1 at the top;
//   * only the newest week is expanded by default, so the page opens on what
//     changed this week rather than on a wall of history;
//   * a week carrying a `source` is one summarised from a DIFFERENT history
//     than this repository's, and says so. The field's presence is the test,
//     never the week number — week 0 is today's only such week, but the shape
//     does not promise it stays that way.

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export interface WeekView {
  key: string;
  number: number;
  /** "Week 3" — the ordinal alone; `title` carries the headline. */
  heading: string;
  title: string;
  range: string;
  /** e.g. "35,569 lines of code" — the week's size, as the page prints it. */
  code: string;
  defaultOpen: boolean;
  /** Set when the week came from another repository's history; null otherwise. */
  sourceNote: string | null;
  summary: ReleaseSection[];
  bullets: string[];
}

/** "2026-08-16" -> "16 Aug 2026"; anything unparseable is passed through. */
function formatDay(isoDate: string, withYear: boolean): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDate);
  if (!match) return isoDate;
  const [, year, month, day] = match;
  const name = MONTHS[Number(month) - 1] ?? month;
  return `${Number(day)} ${name}${withYear ? ` ${year}` : ''}`;
}

/** "2026-08-16T09:00:00+03:00" -> "09:00"; the offset is already Helsinki. */
function formatTime(iso: string): string {
  const match = /T(\d{2}:\d{2})/.exec(iso);
  return match ? match[1] : '';
}

// Both ends carry their TIME, and deliberately: the span is half-open, so week
// N ends and week N+1 starts at the same Sunday 09:00. Printing bare dates made
// two consecutive weeks both look like they contained that Sunday.
function formatRange(week: ReleaseWeek): string {
  const sameYear = week.startDate.slice(0, 4) === week.endDate.slice(0, 4);
  const from = `${formatDay(week.startDate, !sameYear)} ${formatTime(week.start)}`.trim();
  const to = `${formatDay(week.endDate, !sameYear)} ${formatTime(week.end)}`.trim();
  return sameYear ? `${from} – ${to} ${week.endDate.slice(0, 4)}` : `${from} – ${to}`;
}

function sourceNote(week: ReleaseWeek): string | null {
  if (typeof week.source !== 'string' || week.source === '') return null;
  return `Before the repository was public — summarised from the private ${week.source} history.`;
}

/** The weeks of a release-notes document, newest first, ready to render. */
export function releaseWeekViews(doc: ReleaseNotesDoc): WeekView[] {
  const weeks = [...doc.weeks].sort((a, b) => b.week - a.week);
  return weeks.map((week, index) => ({
    key: `week-${week.week}`,
    number: week.week,
    heading: `Week ${week.week}`,
    title: week.title,
    range: formatRange(week),
    code: `${week.codeLines.toLocaleString('en-US')} line${week.codeLines === 1 ? '' : 's'} of code`,
    defaultOpen: index === 0,
    sourceNote: sourceNote(week),
    summary: week.summary,
    bullets: week.bullets,
  }));
}

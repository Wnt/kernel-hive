import type { ReleaseNotesDoc, ReleaseSection, ReleaseWeek } from '../data/releaseNotes';

// Pure view model for the About page's release-notes list. It lives beside
// About.tsx rather than inside it so the ordering / badge / collapse rules are
// testable under vitest's plain-Node environment (vitest.config.ts collects
// src/**/*.test.ts only, and never renders a DOM).
//
// The rules, in one place:
//   * weeks are PRESENTED newest-first — the generator already emits them that
//     way, but sorting here means a hand-edited or older document cannot show
//     week 1 at the top;
//   * only the newest week is expanded by default (an archive week can carry
//     300+ bullets, so opening them all would bury the page);
//   * a "collapsed" section (Dependencies) is a count line only. The generator
//     deliberately sends it with an empty `entries` list, so the count — not
//     the list length — is the number to render;
//   * one row per commit, even when a rebase landed the same subject twice —
//     each row is its own commit link. docs/RELEASE-NOTES.md, which is prose
//     read top-to-bottom, merges those into one bullet carrying both shas.

const COMMIT_URL = 'https://github.com/Wnt/kernel-hive/commit/';
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

interface EntryView {
  key: string;
  /** Station id for the Stations section, so the reader sees which station. */
  station: string | null;
  text: string;
  sha: string;
  href: string;
  date: string;
}

export interface SectionView {
  title: string;
  /** "12 changes", or "4 dependency bumps" for the collapsed Dependencies section. */
  summary: string;
  collapsed: boolean;
  defaultOpen: boolean;
  entries: EntryView[];
}

export interface WeekView {
  key: string;
  number: number;
  heading: string;
  range: string;
  commits: string;
  inProgress: boolean;
  defaultOpen: boolean;
  sections: SectionView[];
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

function plural(count: number, one: string, many: string): string {
  return `${count} ${count === 1 ? one : many}`;
}

function sectionView(section: ReleaseSection, weekIsNewest: boolean): SectionView {
  const collapsed = section.collapsed === true;
  return {
    title: section.title,
    summary: collapsed
      ? plural(section.count, 'dependency bump', 'dependency bumps')
      : plural(section.count, 'change', 'changes'),
    collapsed,
    // Only the newest week opens its sections; a collapsed section has nothing
    // to open, so it never claims to be expanded.
    defaultOpen: weekIsNewest && !collapsed,
    entries: collapsed
      ? []
      : section.entries.map((entry) => ({
        key: `${entry.sha}:${entry.text}`,
        station: section.title === 'Stations' ? entry.scope : null,
        text: entry.text,
        sha: entry.sha,
        href: `${COMMIT_URL}${entry.sha}`,
        date: entry.date,
      })),
  };
}

/** The weeks of a release-notes document, newest first, ready to render. */
export function releaseWeekViews(doc: ReleaseNotesDoc): WeekView[] {
  const weeks = [...doc.weeks].sort((a, b) => b.number - a.number);
  return weeks.map((week, index) => ({
    key: `week-${week.number}`,
    number: week.number,
    heading: `Week ${week.number}`,
    range: formatRange(week),
    commits: plural(week.commitCount, 'commit', 'commits'),
    inProgress: week.inProgress,
    defaultOpen: index === 0,
    sections: week.sections.map((section) => sectionView(section, index === 0)),
  }));
}

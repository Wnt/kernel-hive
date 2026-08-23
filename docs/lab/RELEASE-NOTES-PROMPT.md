# Writing the weekly release notes

The release notes are **written, not generated**. A week's prose comes from one
Claude Code pass over that week's commits; `scripts/release-notes.py` only lays
the result out. There is no cron, no hook and no CI job behind it — the trigger
is you, by hand, on a Sunday after **09:00 Europe/Helsinki** (the moment the
week closes).

## 1. Run this first

```sh
python3 scripts/release-notes.py brief
```

That prints everything the authoring pass needs: the week number, its
start/end in Helsinki, the commit count, the full `git log --no-merges`
subject list for the window, an **EMULATOR FORKS** section carrying the same
week's commits from the public emulator forks (§1.1), the output contract, and
the exact file to write. With no arguments it picks the **oldest closed week
that has no summary yet**; `--week 2026-08-16` picks a specific one by the
Sunday it closed.

`brief` is the only subcommand that touches the network (it shells out to `gh`
for the forks). `render` and `check` stay offline and deterministic.

Oldest first, because **week numbers must run contiguously from 0**: `render`
refuses an archive with a hole in it. Miss a Sunday and the recovery is to
write the missed week — `brief --week <the Sunday it closed>` — before or
alongside the newer one; `brief` warns when an older week is still unwritten,
and names it. Week 0 is the pre-public era and is never offered by `brief`; it
is hand-written, and it must exist before any other week renders.

`python3 scripts/release-notes.py status` answers "which weeks are still
unwritten?" without printing a brief.

## 1.1 The emulator forks — half the week is not in this repo

Most of what a visitor actually notices in a given week is a patch to an
**emulator**, and those patches do not live here: they are pushed to public
forks and consumed as submodules and build pins. A brief cut from `git log`
alone would report the week with its most interesting half missing, so `brief`
gathers the forks too, from one hand-written declaration:

    registry/release-notes/sources.json

**The rule, and it is deliberate:**

- **Only our commits** — GitHub author login `Wnt` or `jonni-reaktor`
  (`ourAuthors`). Everything else on those branches is upstream
  MAME/VICE/QEMU/es40 work this project merely carries; it is not ours to
  announce.
- **A commit with no GitHub account is never dropped.** GitHub can only attach
  a login to a commit whose author email belongs to an account, so work pushed
  straight from the lab box arrives with no login at all and `ourAuthors`
  cannot see it. `ourCommitAuthors` declares the plain git author names that
  count as ours anyway; anything still unattributed is printed under a
  **`DECIDE BY HAND`** block. Read each one — if it is ours, write it up, and
  add its author name to `ourCommitAuthors` so it counts by itself next week.
- **Only the branch each build actually pins.** Every branch entry cites the
  file that pins it (`pinnedBy`) — `.gitmodules`, a build script's
  `*FORK_BRANCH=`, or, for es40, the station registry entry's
  `emulator.source`. `check` **parses the pin** out of each cited file rather
  than searching it for the branch name (the old name lives on in comments and
  echo lines long after a repoint), and sweeps the same three formats across
  the tree in the other direction, so a branch the build pins but nobody
  declared goes red too.
- **No trial branches.** `Wnt/mame` `irix-experimental` and `Wnt/es40`
  `tlb-hint-experimental` are real, published, working patches that the default
  stack does **not** run. A visitor reading about them would be reading about a
  capability the gallery does not have. Each exclusion records its own `why` in
  sources.json: read it before removing one, and never "helpfully" widen the
  list.
- **No commit whose own subject says `[experimental, not shipped]`.**
- `Wnt/forwarder` is out of scope on purpose: TLS and relay plumbing for the
  public ingress, not an emulator patch anyone would notice from the floor.

A fork commit older than this repository's first public commit belongs to the
pre-public era — week 0 — which is hand-written and never offered by `brief`.

**If the brief prints a `WARNING — … COULD NOT BE REACHED`**, `gh` is missing,
unauthenticated or failing, and that fork's commits are **absent from the
brief**. Do not write the week up as if those forks were idle: run `gh auth
login` (or install `gh`), re-run `brief`, and only then author. The warning
names each unreachable fork and prints the exact `gh api` line that failed, so
it can be re-run verbatim. `brief` also exits **2** in this case — the brief
itself still prints in full, but a wrapper reading only `$?` must not mistake a
short week for a complete one.

To add a fork, or to move a build to a different branch, edit sources.json —
that is the single hand-written home for the fact — and keep `pinnedBy`
pointing at the file that really pins it.

## 2. Paste this prompt

Paste the brief output, then this block, into Claude Code:

---

> Write the Kernel Hive release notes for the week in the brief above. Read the
> commit subjects; where a subject is too terse to be trustworthy, read the
> commit itself (`git show`) rather than guessing what it did.
>
> **Voice — enthusiastic.** This is a personal "living computer museum" the
> operator is proud of, and the notes should read like someone genuinely
> delighted to show you what got built this week. Concrete enthusiasm, not
> marketing filler: the excitement comes from the actual achievements (a 1994
> workstation dialling out to a period web server; a boot that went from 40
> seconds to instant), never from adjectives bolted onto nothing.
>
> **Hard constraints on the voice:**
>
> - Never invent a fact, a number, a date or a capability. Every claim must
>   trace to a commit. If you are unsure whether something landed or was only
>   attempted, say what the commits say or leave it out. An enthusiastic wrong
>   claim is the worst possible output here.
> - No hype words with no referent ("revolutionary", "game-changing",
>   "blazing").
> - Do not state station counts or totals unless you verified them from the
>   registry (`python3 scripts/stations-registry.py count`).
> - **Write for a VISITOR, never for the operator.** The reader has never seen
>   the inside of this system and never will. Two people are reading: someone
>   curious who might go and try one of these machines, and an enthusiast who
>   follows the project because they love old computers. Every sentence has to
>   earn its place with one of them — does it tell them something they can see,
>   try, or find delightful? If it only means something to whoever maintains
>   the system, cut it. Three vivid sentences beat eight accurate ones nobody
>   finishes.
> - **Never name an internal.** Banned outright: component and module names
>   (`era-press`, `streamhost`, `ctlsock`, `vicectl`, `shmfb`, `warpd`, and the
>   internal senses of "golden", "checkpoint", "tile", "kiosk", "bridge"),
>   container and network plumbing, build tooling and cache-hit rates, crawl
>   throughput and byte budgets, model names, pixel/byte/keystroke counts,
>   `strace` and instruction traces, commit shas, file paths, code identifiers.
>   These are real examples of what NOT to write:
>
>       the retronet gateway is live: a Debian container on a bridge with no uplink
>       zero non-loopback connections under strace, and 2473 aborted misses
>       took the corpus build from about 2 pages a minute to about 92
>       the CBM 8032 shed 36% of its pixels for the same picture
>
>   The same week's good version was already in the facts: *sign into ICQ on
>   Windows 98 and message someone at a Solaris workstation, then browse 1998
>   web pages in Internet Explorer 5 exactly as they were.*
> - **State an improvement as the visitor feels it**, never as its mechanism:
>   "comes back in three seconds instead of eighty", not what was missing from
>   the saved state. Name the machine and its year when it helps ("a 1991 MIPS
>   laptop", "Apple's strangest hybrid").
> - **Bullets must carry material the paragraphs do NOT.** This is the rule that
>   matters most, and the one the first draft broke. The paragraphs carry the
>   story; the bullets carry what the paragraphs had no room for — the machines
>   the prose could only gesture at, the smaller wins, the specific delight. A
>   bullet that restates a sentence from the summary is deleted, not reworded:
>   a reader who finds the first three bullets already familiar stops reading
>   the rest, and everything you buried down there goes with them. Fewer,
>   genuinely additive bullets beat twenty echoes — if a week only supports six,
>   write six.
> - **One word for one thing.** In prose, a thing a visitor can open is a
>   **machine** — never a "station", "exhibit" or "tile" (the section heading
>   `New stations` is fixed and stays, but the prose must not use four words for
>   one idea). If you refer to the grid or the floor, gloss it once or avoid it.
> - **Never state an internal count.** "sixty-one exhibit notes", "24 targets
>   out of 24", "nine more exhibits", "101 photographs, 41 captions wrong" are
>   work-item tallies measured against a baseline the reader does not have.
> - **Cover the emulator forks.** The EMULATOR FORKS section of the brief is
>   part of the week, not an appendix: weave that work into the summary
>   alongside the repository's own commits, in the same voice, and say what the
>   patch means for the machine on the floor ("the C64's checkpoint now restores
>   without resizing the screen"), not what it means for the emulator's source
>   tree. If a fork commit is the most interesting thing that happened, it leads.
>   If the brief carried a WARNING that a fork could not be reached, stop and fix
>   that first — never write the week up from an incomplete brief.
> - `commitCount` is this repository's own commit count, exactly as the brief
>   prints it. Fork commits are context for the prose; they are never added to
>   it, and no other field records them.
>
> **Scrubbing rule, absolute.** This repository is public. Never write a real
> IP, hostname, MAC address, serial number or domain into the notes —
> placeholders only (`192.0.2.10`, `labhost`, `example.com`). Describe rather
> than quote when a commit message carries a real value.
>
> **Hard limits.**
>
> - `summary`: **exactly 3 themed sections, in this order** — `New stations`,
>   `Major features`, `Quality improvements` — **300-400 words in total** across
>   the three. The themes are the same every week and are enforced: a reader who
>   learns the shape once should never have to learn it again. If a theme is
>   thin this week, write a short honest section; never pad it, and never drop
>   it.
> - `bullets`: **1 to 20 entries**, each a **single line of at most 160
>   characters**, with no leading dash and no trailing period required.
> - `title`: 2-6 words, specific to this week, and it must **not** contain the
>   week number — the heading already prints it.
> - `codeLines`: copied verbatim from the brief. It is the week's size as the
>   pages print it — added lines of hand-written source, with docs, generated
>   files and vendored trees excluded. `commitCount` is still recorded for
>   provenance but is no longer displayed anywhere: a raw commit count is a
>   developer metric, and the 16-vs-713 swing made the week this project was
>   open-sourced look like its quietest. Never mention either number in prose.
>
> **Markup — use it, the same way in every sentence.** Four constructs, and
> nothing else (anything outside this is refused by the validator):
>
> | Write | For | Renders as |
> |---|---|---|
> | `[Windows 3.11](station:win311)` | a machine the reader can go and use | a link to that station |
> | `**ICQ**` | software and product names that are not stations | bold |
> | `*68040*` | hardware, chips, eras | italic |
> | `<u>...</u>` | **exactly one per week**, the week's headline | underline |
>
> Link a machine the **first time it is named in each section**, and use the
> station's real id — `registry/stations/*.json` is the list, and an id that
> does not exist fails the gate rather than publishing a dead link. Underline is
> rationed to one per week on purpose: underlined text that is not a link reads
> as a broken one, and on the About page the station names really are links.
>
> **Write exactly one file**, at `registry/release-notes/<end-date>.json`,
> named after the Sunday the week closed (the brief prints the path):
>
> ```json
> {
>   "week": 3,
>   "title": "The retronet signs on",
>   "start": "2026-08-16T09:00:00+03:00",
>   "end":   "2026-08-23T09:00:00+03:00",
>   "commitCount": 336,
>   "codeLines": 35569,
>   "summary": [
>     { "theme": "New stations",         "text": "..." },
>     { "theme": "Major features",       "text": "..." },
>     { "theme": "Quality improvements", "text": "..." }
>   ],
>   "bullets": ["<highlight>", "<highlight>"]
> }
> ```
>
> `start`, `end` and `commitCount` are copied verbatim from the brief — a
> slipped `start` is refused, because consecutive weeks must abut (week N
> starts exactly where week N-1 ended). The schema is locked: no other keys,
> and every one of these is required. Do not touch README.md,
> docs/RELEASE-NOTES.md or spa/public/release-notes.json — those are rendered.

---

## 3. Finish

```sh
python3 scripts/release-notes.py render     # or: make release-notes
python3 scripts/release-notes.py check      # or: make release-notes-check
git diff README.md                          # read the week you just published
```

If `render` refuses with "week numbers must run contiguously from 0", a week
is missing rather than malformed: `status` names it, `brief --week <end-date>`
cuts it, and nothing publishes until it exists.

`render` writes the three committed outputs — the README's "Release notes"
section, `docs/RELEASE-NOTES.md` and `spa/public/release-notes.json`. `check`
re-validates every summary file against the locked schema and asserts the three
outputs are byte-identical to a fresh render, so it is fully deterministic: no
git history is read for content, and a red `check` always means "run `render`
and commit", never "someone else pushed".

Read the README diff before committing. This is the one output a stranger sees
first, and the pass that wrote it cannot tell whether a sentence is true — you
can. Then commit the summary file and the three rendered outputs together.

## Week 0 is a one-off

Week 0 is the pre-public era — the month the museum was built in the private
predecessor repo, before any of this was published — and it is the ONE week
written to a wider budget: **4-5 themed sections** (a leading `The story so far`
before the usual three) and **600-700 words**, because it is somebody's first
contact with the project and has to say what this actually is. Its
`commitCount` is that repo's own non-merge count, and it carries
`"source": "osgallery"`, which is what makes the archive print the "before the
repository was public" note. A normal week does not get any of this: three
sections, 300-400 words. Do not copy week 0's shape into week N.

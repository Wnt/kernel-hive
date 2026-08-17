# qwenit — offloading heavy work to a cheap open-weight model

**Codeword: `qwenit`.** When the user says it, Claude stays orchestrator — briefs,
review, merge, decisions, user comms — and substantial work runs as headless
[OpenCode](https://opencode.ai) sessions driving an open-weight model through
OpenRouter. The point is cost: a task that would consume Claude quota costs
cents instead.

Mechanism: [`scripts/dev/qwen-task.sh`](../../scripts/dev/qwen-task.sh). It wraps
`opencode run --format json` with the same shape the lab expects from any
long-running job — per-task directory, setsid process-group kills, git-worktree
isolation by default, an event log, an extracted final message, and safety caps
that preserve partial work when they trip.

---

## The one-minute version

```bash
scripts/dev/qwen-task.sh run <name> --prompt-file brief.md
scripts/dev/qwen-task.sh ls
scripts/dev/qwen-task.sh status <name>
scripts/dev/qwen-task.sh result <name>
scripts/dev/qwen-task.sh clean <name>
```

Launch through Bash `run_in_background` so completion re-invokes the session.
`qwen-task.sh --help` prints the full flag list; it is self-documenting and the
flags are deliberately not duplicated here.

## Watching a run

`status` is a snapshot; [`scripts/dev/qwen-watch.py`](../../scripts/dev/qwen-watch.py)
is the live view — an irssi-style TUI where each task is a channel and channel 0
is the aggregate feed. **←/→ switch channel** (wrapping at both ends), `0`..`9`
jump straight to one, PgUp/PgDn scroll, End follows, `q` quits.

```bash
scripts/dev/qwen-watch.py                    # curses TUI
scripts/dev/qwen-watch.py --plain            # line stream (also used when piped)
scripts/dev/qwen-watch.py --tasks ql-demo    # filter; named tasks join regardless of age
```

**The title bar carries live spend against the cap** — `$0.67/$5.00  11.1k/300k
tok` — which is the number you actually want while a task is running, and the one
the Codex-era watcher could not show because Codex never reported cost. Tasks are
aggregated from the main checkout and every Claude worktree (labeled
`<task>@<worktree>`); only active ones join, meaning RUNNING or an event log that
moved in the last 30 minutes.

A long `bash` step emits nothing for minutes — a silent channel on a RUNNING task
is normal, not a hang. Check the wall clock in `status` before assuming otherwise.

## What it costs

The default model is `openrouter/qwen/qwen3.8-27b` — 262 144-token context,
**$0.45 per M input, $3.20 per M output**. A small read-and-answer task measured
at **$0.006**. The dominant cost is *input*: OpenCode's system prompt plus
`AGENTS.md` runs 8–10k input tokens per step before your brief is read, and a
multi-step task pays that on every step. Cache reads absorb most of it on later
steps, but budget by step count, not by output length.

Override per task with `--model` (any `provider/model` OpenCode knows —
`opencode models` lists them) or globally with `QWEN_TASK_MODEL`.

## Safety caps

Every launch and resume runs under a watchdog. Defaults, each overridable by
flag or environment variable:

| Cap | Default | Env |
|---|---|---|
| Wall time | 7200 s | `QWEN_MAX_WALL` |
| Cumulative output tokens | 300 000 | `QWEN_MAX_OUT_TOKENS` |
| Cumulative cost | $5.00 | `QWEN_MAX_COST` |

A trip writes `.claude/qwen-tasks/<name>/killed` with the reason and value, then
kills the process group. **`last.md` and worktree edits survive** — use `status`
to read the trip reason and `result` to salvage, then `resume` or relaunch.

The cost cap is the one that matters. OpenCode reports per-step `cost` directly
in its event stream, so the accounting is the provider's own number, not an
estimate.

## Three facts that mislead if you don't know them

- **There is no sandbox, but there IS a permission gate — and headless it is
  lethal.** `opencode run` executes bash and writes files with no gate; Codex's
  `--sandbox read-only` has no equivalent. But *some* tool calls do ask, and the
  set is not the one you would guess: a **read** of a path matching an env-file
  pattern raises a permission request. Headless there is nobody to answer, so
  opencode auto-**rejects** and **the run ends mid-task** — no error, just a
  final message that stops in the middle of a sentence. The `ql-demo` task died
  this way on `streamhost/stations/sinclairql/station.env.fixture`
  (2026-08-17), a perfectly ordinary committed file. `qwen-task.sh` therefore
  launches with `--auto`, which widens nothing bash did not already allow. The
  git worktree and the dev container remain the entire containment: scope a task
  with its brief.

  **A truncated final message is the signature.** If `result` ends mid-thought,
  read `stderr.log` for `permission requested: … auto-rejecting` before assuming
  the model wandered off.

- **Token usage is per-step, not cumulative.** `step_finish.part.tokens` reports
  that step only; totals are summed across events. Anything reading a single
  event's `tokens.output` as a running total will under-report by the number of
  steps.

- **The final message is not written for you.** `opencode run` has no `-o` flag.
  `last.md` is extracted from the event stream after the process exits — the last
  `type=text` part with non-whitespace content. Intermediate steps emit
  whitespace-only text parts between tool calls; those are dropped. This means
  `result` is empty until the run ends or is stopped.

## This repo is public

`kernel-hive` is a public GitHub repository. Two consequences for qwenit:

- **Task state never reaches it.** `.claude/*` is gitignored (`.gitignore:51`,
  with only `hooks/` re-included), so task dirs, briefs, event logs and model
  transcripts are ignored by construction. Do not add an exception.
- **A qwenit brief must carry the scrubbed-placeholder rule explicitly.** Every
  IP, hostname, MAC, serial and domain in this repo is a placeholder; real values
  live only in gitignored `registry/local.env`. A 27B model following a 6 KB
  `AGENTS.md` holds that line less reliably than Claude does. **Default to
  no-push**: qwenit tasks commit to their `qwen/<name>` branch, and landing is a
  reviewed step, not the task's job.

## The API key

Lives at `~/.config/openrouter/api-key` (mode 0600, directory 0700) and is
exported as `OPENROUTER_API_KEY` from `~/.bashrc`. OpenCode picks it up from the
environment — OpenRouter is a native provider, so no `opencode.json` credential
block exists and none should be created. **The key is never in this repo, in any
form, including an env-var reference in a committed config.**

`qwen-task.sh` validates both the binary and the key before launching, rather
than failing deep inside a run.

**An agent-launched shell is non-interactive and never sources `~/.bashrc`**, so
neither the installer's PATH entry for `~/.opencode/bin` nor the exported key is
present — the first agent to try this hit `'opencode' not on PATH` on a box
where opencode was installed and working. `require_opencode` therefore falls
back to `~/.opencode/bin/opencode` and reads the key file itself; override
either with `OPENCODE_HOME` / `OPENROUTER_KEY_FILE`. **Do not re-export these in
a brief or a wrapper** — if the fallback ever stops working, fix it there once.

## Deliberately not built

`harvest` and `land` subcommands. The predecessor repo's equivalent accumulated
103 stale `codex/*` branches and is logged as tech debt there. Land a qwenit
branch by hand until the volume justifies automation — and if it does, fix the
staleness problem in the design rather than porting it.

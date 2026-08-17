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

- **There is no sandbox.** `opencode run` executes bash and writes files with no
  permission gate — verified: the `--auto` flag exists but is *not required* for
  either. Codex's `--sandbox read-only` has no equivalent here. The git worktree
  and the dev container are the entire containment. Scope a task with its brief,
  not with a flag that does not exist.

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

`qwen-task.sh` refuses to launch if `OPENROUTER_API_KEY` is unset rather than
failing deep inside a run.

## Deliberately not built

`harvest` and `land` subcommands. The predecessor repo's equivalent accumulated
103 stale `codex/*` branches and is logged as tech debt there. Land a qwenit
branch by hand until the volume justifies automation — and if it does, fix the
staleness problem in the design rather than porting it.

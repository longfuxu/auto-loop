# auto-loop

**English** · [简体中文](README.zh-CN.md)

**Run a list of coding tasks unattended with an agent CLI (Claude Code or OpenAI Codex), sleep through usage-limit windows automatically, and have an independent auditor verify each task is actually done — with a small local web UI for non-coders and a one-command way to jump into any task interactively.**

<p align="center">
  <img src="docs/ui-status.png" alt="auto-loop web UI — live task status with an independent auditor" width="820">
  <br>
  <em>The local web UI. Tasks advance one at a time; when a worker claims a task is done, a separate auditor re-checks every “done” criterion before it can turn <code>complete</code> — that's the <code>review</code> row.</em>
</p>

---

## Why this exists

Agent CLIs like **Claude Code** and **Codex** are great at doing one bounded chunk of work at a time. But two things get in the way of leaving them to grind through a real backlog:

1. **Usage limits.** Every plan has a rolling window (Claude resets on a ~5-hour cycle; Codex has its own quota). Hit the limit and the agent just stops. If you're not sitting there to restart it when the window reopens, you lose hours.
2. **"Grading its own homework."** When an agent says *"done,"* nothing checked it. Left alone, an agent will happily declare victory on a task it only half-finished — a well-known failure mode of autonomous loops.

`auto-loop` is a small, auditable Bash harness that solves both:

- It advances your tasks **one at a time**, and when the agent gets rate-limited it **sleeps exactly until the window resets** (reading the reset time from Claude's own events), then **resumes the same session** so the agent continues instead of starting over.
- When a task's worker claims completion, a **separate, independent auditor agent** re-checks every "done" criterion — runs the tests, reads the diff — before the task is allowed to be marked complete.

The whole thing is ~400 lines of Bash plus a dependency-free Python UI. You can read all of it.

## What it is *not*

It is not a replacement for judgment. It's for tasks that are **well-specified, verifiable, and safe to run unattended on a feature branch**. It is not for tasks that need live decisions, send messages, publish, or require secrets typed in by hand.

---

## How it works

```
tasks.json ──► auto-loop.sh ──► agent CLI (claude | codex)  ──► commits on a feature branch
    ▲               │  ▲            (non-interactive, one bounded increment per run)
    │               │  └── usage-limited? sleep until the window resets, then resume same session
  edit via          │
  UI or $EDITOR     ├── worker says TASK_COMPLETE? ──► independent AUDITOR agent verifies "done"
                    │                                    ├─ PASS ─► complete
                    │                                    └─ FAIL ─► back to in_progress (worker reworks)
                    └── writes state.json + a markdown report each window
```

**One task per run, resumable sessions.** Each task keeps its own agent session id. The loop finishes a task across as many windows as it takes before moving to the next.

**Optional summary-based resume for token management.** By default, Claude tasks resume the same session with `--resume`. Set `CLAUDE_RESUME_MODE=summary` to make rate-limit recovery lighter: after a Claude task hits a usage-limit window, auto-loop marks the next worker run to start a fresh Claude session seeded with a local task summary from `summaries/<task>.md`, instead of forcing the full prior transcript back through resume. Set `CLAUDE_RESUME_MODE=fresh` to always use the summary/fresh-session path when a summary exists.

**Two engines, one harness.** Set `"engine": "claude"` or `"engine": "codex"` per task (or a global default). The harness normalizes both:

| | Claude Code | Codex |
|---|---|---|
| non-interactive call | `claude -p --output-format json` | `codex exec --json` |
| resume a session | `--resume <id>` | `exec resume <id>` |
| summary resume | `CLAUDE_RESUME_MODE=summary` starts fresh from `summaries/<task>.md` after a rate-limit pause | not implemented |
| skip approvals (unattended) | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` |
| usage-limit reset | precise `resetsAt` epoch → sleep to it | no epoch exposed → back off `CODEX_COOLDOWN` (default 1h) |

**Independent auditor (the important part).** After a worker emits `TASK_COMPLETE`, the task goes to `review`. A *fresh* auditor agent — no shared session with the worker — is told to distrust the claim, run the exact verification commands in your `done` field, inspect the git diff, and answer `AUDIT_PASS` or `AUDIT_FAIL: <reason>`. Only `AUDIT_PASS` marks the task complete; a fail sends it back to `in_progress` with the reason, so the next worker run fixes it. Toggle with `AUDIT=0`.

**Interactive pickup.** The loop is non-interactive by design (reliable rate-limit and sentinel detection). But because it stores a resumable session id per task, you can open the **normal interactive TUI** on any task at any time:

```bash
./auto-loop.sh stop            # so the loop won't fight you for the session
./auto-loop.sh attach <task>   # opens `claude --resume <id>` (or `codex resume <id>`) in the task's dir
# …inspect, chat, steer, fix by hand, then exit the TUI…
nohup ./auto-loop.sh >> logs/nohup.log 2>&1 &   # let the loop carry on
```

**Web UI for non-coders.** `./auto-loop.sh ui` serves a local page to add/edit tasks (with validation), watch live status, start/stop the loop, and read the per-window reports — without touching the terminal. The CLI is still the engine; the UI just calls it.

<p align="center">
  <img src="docs/ui-tasks.png" alt="auto-loop web UI — add and edit tasks with validation" width="820">
  <br>
  <em>Add / edit tasks in the browser — id, repo path, goal, checkable “done” criteria, and optional engine/model per task. Saving writes <code>tasks.json</code> and runs the CLI validator.</em>
</p>

---

## Install

Requirements: `bash`, `jq`, `git`, `python3` (for the UI), and at least one agent CLI:
- **Claude Code** — `claude` on PATH, logged in.
- **Codex** — `codex` on PATH, logged in (`codex login`).

```bash
git clone <your-fork-url> auto-loop && cd auto-loop
cp tasks.md.example tasks.md
$EDITOR tasks.md            # human-friendly; multiline text is fine
./auto-loop.sh prepare      # writes canonical tasks.json
./auto-loop.sh validate     # check your tasks before running
```

## Task format

Prefer editing `tasks.md`; `tasks.json` is the generated canonical file used by
the runner. This avoids JSON escaping mistakes such as raw newlines inside
strings or trailing commas.

`tasks.md`:

```md
## my-feature

dir: /absolute/path/to/a/git/repo
engine: claude

goal:
One concrete objective. This can be multiple paragraphs and does not need JSON
escaping.

done:
Concrete, auditable completion criteria. Name files and commands, e.g.
`npm test` passes and `FEATURE_PLAN.md` exists.
```

Run `./auto-loop.sh prepare` to compile that Markdown into:

```json
{
  "tasks": [
    {
      "id": "my-feature",
      "dir": "/absolute/path/to/a/git/repo",
      "goal": "One concrete objective.",
      "done": "Checkable criteria WITH commands, e.g. 'npm run build passes; tests green; committed on a branch'.",
      "engine": "claude",
      "model": "claude-opus-4-8"
    }
  ]
}
```

`prepare` first parses the Markdown deterministically, then asks the configured
LLM to clean up task wording and make `done` criteria more objective. The output
is still validated locally before the loop can start. Set `TASK_PREPARE_LLM=off`
for deterministic-only generation, or `TASK_PREPARE_LLM=required` if missing LLM
optimization should be a hard failure.

- `id` — slug, `^[a-z0-9-]+$`, unique.
- `dir` — absolute path to a **git repo** (the worker commits its work).
- `goal` / `done` — the more concrete and *verifiable* `done` is, the better the auditor works. Name the exact commands.
- `engine` *(optional)* — `claude` | `codex`. Defaults to `$ENGINE` (default `claude`).
- `model` *(optional)* — precedence: task `model` → env `MODEL` → the engine's account default.

Put credentials in the **environment** (e.g. `VERCEL_TOKEN`), never in `tasks.json`, logs, or reports.

## Usage

```bash
./auto-loop.sh              # run the loop (foreground)
./auto-loop.sh prepare      # compile tasks.md -> tasks.json, with LLM cleanup when available
./auto-loop.sh doctor       # preview prepared JSON without writing tasks.json
./auto-loop.sh status       # per-task status table + whether the loop is running
./auto-loop.sh validate     # prepare if needed, then lint tasks.json — non-zero exit on hard errors
./auto-loop.sh edit         # $EDITOR tasks.md if present, else tasks.json, then re-validate
./auto-loop.sh sessions     # task -> engine -> session_id -> dir
./auto-loop.sh attach <id>  # interactive TUI on a task's stored session
./auto-loop.sh report       # write a status report now (reports/report-<ts>.md)
./auto-loop.sh ui [port]    # local web UI (default 127.0.0.1:8787)
./auto-loop.sh stop         # stop a running loop (uses the PID lock)

# unattended background run:
nohup ./auto-loop.sh >> logs/nohup.log 2>&1 &

# optional Claude token-management mode:
CLAUDE_RESUME_MODE=summary ./auto-loop.sh
```

**Reports** are deterministic markdown digests (no extra agent quota spent) written at each rate-limit window end, when the loop goes idle, and on demand: per-task status/runs/errors/last sentinel + recent commits in each task repo.

### Environment overrides

`ENGINE` `MODEL` `PERM_FLAGS` `IDLE_SLEEP` `RESET_BUFFER` `MAX_ERRORS` `CLAUDE_BIN` `CLAUDE_RESUME_MODE` `CODEX_BIN` `CODEX_COOLDOWN` `REQUIRE_GIT` `AUDIT` `AUDIT_MODEL` `AUDIT_ENGINE` `UI_PORT` `EDITOR`.

`CLAUDE_RESUME_MODE`:

- `full` (default): keep using Claude Code's normal `--resume <session_id>` behavior.
- `summary`: use normal `--resume` until a Claude task hits a rate-limit window; after the sleep, start a fresh session with the local summary in `summaries/<task>.md`.
- `fresh`: always start a fresh Claude session seeded with the local summary when one exists.

Claude Code's interactive `/resume` can offer to summarize stale large sessions. The non-interactive CLI currently exposes `--resume` but not a documented `--summary` flag, so auto-loop's summary mode is implemented at the harness layer: it preserves continuity with a small local task summary and repo state instead of relying on a hidden Claude flag.

---

## Safety

This tool runs agents **unattended with approvals skipped** (`--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`). That is deliberate — an unattended loop cannot answer permission prompts — but it means **you are trusting the agent to edit and run commands in the task's repo without asking**. Use it only where that trust is acceptable. The design contains the blast radius:

- **Worker guardrails (in the system prompt):** edit only inside the task's `dir`; commit only on a **feature branch**; **never** touch `main`/`master`, never force-push, never merge; never print secrets; keep the repo runnable. *(These are instructions to the model, not a sandbox — see "Honest limitations".)*
- **Independent verification:** completion is not self-attested. A separate auditor agent must confirm the `done` criteria before a task is `complete` (`AUDIT=1`, on by default).
- **Startup validation gate:** the loop refuses to start on a malformed spec — missing fields, non-absolute `dir`, a `dir` that isn't a git repo, duplicate ids (`REQUIRE_GIT=0` opts out).
- **Single-runner lock:** a PID lock file prevents two loops from running the same task list and forking a session; stale locks (dead PID) are ignored.
- **Secret hygiene:** credentials come from the environment. `state.json`, `logs/`, `reports/`, and the lock file are git-ignored. Full per-run transcripts are saved under `logs/` (plaintext on disk) — keep the repo private if your prompts or code are sensitive.
- **The web UI binds to `127.0.0.1` only.** It can edit tasks and start the loop, so treat it as a local admin panel: **do not** port-forward it or expose it to a network. Path names for report files are validated to prevent traversal.

### Honest limitations

- The worker guardrails are **prompt-level**, not an OS sandbox. Skipping approvals means a misbehaving or prompt-injected agent *could* act outside them. Point it only at repos you're willing to let an agent modify, prefer disposable branches, and keep backups. If you want a real sandbox for Codex, run without the bypass flag (you'll then need to handle approvals).
- The auditor is another LLM. It catches "the tests don't actually pass / the file was never written" far better than trusting the worker, but it is not a formal proof. Write `done` criteria as concrete commands so the auditor has something objective to run.
- Codex has no precise reset-time signal like Claude, so its back-off is a fixed cooldown (`CODEX_COOLDOWN`), not a to-the-second wake-up.

---

## Files

```
auto-loop.sh        # the harness: engines, rate-limit sleep, auditor, subcommands
scripts/prepare_tasks.py  # tasks.md -> tasks.json compiler with optional LLM cleanup
ui-server.py        # local web UI backend (Python stdlib only; calls auto-loop.sh)
ui.html             # single-file UI (Tasks / Status / Reports)
tasks.md.example    # human-friendly task template
tasks.md            # your human-edited task list (you create this; git-ignored)
tasks.example.json  # copy to tasks.json
tasks.json          # canonical generated task list (git-ignored)
state.json          # runtime state (git-ignored, auto-created)
logs/               # main.log + per-run/audit JSON transcripts (git-ignored)
reports/            # markdown window reports (git-ignored)
summaries/          # per-task context summaries for CLAUDE_RESUME_MODE=summary (git-ignored)
```

## License

Apache-2.0 — see `LICENSE` and `NOTICE`.

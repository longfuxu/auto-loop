# auto-loop

**English** · [简体中文](README.zh-CN.md)

Local task queue for Claude Code and OpenAI Codex CLI: define a backlog in Markdown, run one task at a time, sleep or switch engines when a usage limit is hit, keep per-engine sessions, and require an independent auditor before a task can be marked complete.

`auto-loop` is intentionally small: one readable Bash runner, one stdlib Python UI, one Markdown-to-JSON task compiler. It is for people who still want local CLI control instead of handing every backlog item to a cloud service.

<p align="center">
  <img src="docs/ui-status.png" alt="auto-loop web UI - live task status with an independent auditor" width="820">
  <br>
  <em>Tasks advance one at a time. A worker can only move a task to review; a separate auditor must verify the done criteria before completion.</em>
</p>

## Why It Exists

Agent CLIs are useful for bounded coding tasks, but unattended use has three practical problems:

1. **Usage windows stop progress.** If Claude hits a quota window while you are away, the task stalls. Codex has its own quota behavior.
2. **One provider is not enough.** A task should be able to continue with Codex when Claude is limited, or vice versa, without losing repo context.
3. **The worker should not grade itself.** A model saying "done" is not verification.

`auto-loop` handles those directly:

- It runs a concrete task list sequentially, across as many windows as needed.
- It stores sessions per task and per engine, so `claude` and `codex` never share a resume id.
- It can switch to `fallback_engine` when the active engine is rate-limited.
- It writes local summaries so a fallback run can continue from the repo state and the last known task context.
- It runs a separate auditor pass before completion.

## How It Works

```
tasks.md -> prepare -> tasks.json
                         |
                         v
                   auto-loop.sh
                         |
        +----------------+----------------+
        |                                 |
  worker engine                     state/reports
  claude or codex                   sessions per engine
        |
        +-- limit hit? switch to fallback engine if configured
        |
        +-- TASK_COMPLETE? -> independent auditor -> pass/fail
```

The runner is local. It does not bypass usage limits. It either waits until the known reset time or continues with the configured fallback engine.

## Quick Start

Requirements: `bash`, `jq`, `git`, `python3`, and at least one logged-in CLI:

- `claude` for Claude Code.
- `codex` for OpenAI Codex CLI.

```bash
git clone <your-fork-url> auto-loop
cd auto-loop
cp tasks.md.example tasks.md
$EDITOR tasks.md
TASK_PREPARE_LLM=off ./auto-loop.sh prepare
./auto-loop.sh validate
./auto-loop.sh run
```

## Task Format

Prefer editing `tasks.md`. `tasks.json` is generated and used by the runner.

```md
## build-settings-panel

dir: /absolute/path/to/a/git/repo

<!--
Engine options:
- engine: claude
- engine: codex

Model examples, passed through to the selected CLI:
- Claude: claude-opus-4-8, claude-opus-4-6, claude-sonnet-4-5
- Codex: gpt-5-codex, gpt-5

Leave engine/model blank to use the global default/account default.
Use fallback_engine/fallback_model when you want continuation after a usage limit.
-->
engine: claude
model:
fallback_engine: codex
fallback_model:

goal:
Build the settings panel described in docs/settings-plan.md.

done:
Create and commit the implementation on a feature branch. `npm test` and
`npm run build` pass. Update HANDOFF.md with the changed files and next command.
```

Fields:

- `id`: taken from the `##` heading unless `id:` is provided. Must match `^[a-z0-9-]+$`.
- `dir`: absolute path to a git repo or worktree.
- `goal`: concrete objective.
- `done`: objective verification criteria. Name commands and artifacts.
- `engine`: optional primary engine, `claude` or `codex`. Defaults to `$ENGINE`, then `claude`.
- `model`: optional model for the primary engine. Blank means `$MODEL`, then the account default.
- `fallback_engine`: optional second engine used when the active engine is rate-limited.
- `fallback_model`: optional model for the fallback engine. Blank means `$MODEL`, then the account default.

Compile and validate:

```bash
./auto-loop.sh prepare
./auto-loop.sh validate
```

`prepare` parses Markdown deterministically. If enabled, it asks the configured CLI to polish `goal` and `done`, but the deterministic parser remains the source of truth for ids, directories, engines, models, and task count. Set `TASK_PREPARE_LLM=off` for deterministic-only output.

## Engine Fallback

When a task hits a usage limit:

- Claude: the runner reads `resetsAt` when the CLI exposes it.
- Codex: the runner uses `CODEX_COOLDOWN` because no precise reset epoch is exposed.
- If `fallback_engine` is configured and available, the task continues immediately on that engine instead of sleeping.
- `state.json` stores separate sessions under `sessions.claude` and `sessions.codex`.
- The fallback run receives the local task summary and must inspect the repo state before continuing.

Example:

```md
engine: claude
model: claude-opus-4-8
fallback_engine: codex
fallback_model: gpt-5-codex
```

This means: start with Claude, use that model if available, and continue with Codex if Claude is limited.

## Summary Resume

Claude can resume the same non-interactive session with `--resume`. Long sessions can become expensive in context. `auto-loop` adds harness-level summary resume:

```bash
CLAUDE_RESUME_MODE=summary ./auto-loop.sh run
```

Modes:

- `full`: default, keep using the stored session id.
- `summary`: use normal resume until a Claude usage limit occurs; next Claude run starts fresh from `summaries/<task>.md`.
- `fresh`: always use the local summary when one exists.

The summary file contains task goal, done criteria, last result, active engine, sessions by engine, and recent commits.

## Independent Audit

When a worker prints `TASK_COMPLETE`, the task moves to `review`, not `complete`.

The auditor is a fresh CLI run with a different prompt. It must inspect the repo, run the commands named in `done`, and answer:

- `AUDIT_PASS`
- `AUDIT_FAIL: <reason>`

Only `AUDIT_PASS` marks the task complete. Disable with `AUDIT=0` only when you are deliberately accepting self-attested completion.

## Local UI

```bash
./auto-loop.sh ui 8787
```

The UI binds to `127.0.0.1`, edits tasks, validates them through the CLI, starts/stops the loop, and reads reports. It is a local admin panel; do not expose it to a network.

<p align="center">
  <img src="docs/ui-tasks.png" alt="auto-loop web UI - task editor" width="820">
  <br>
  <em>The UI supports primary engine/model plus fallback engine/model.</em>
</p>

## Commands

```bash
./auto-loop.sh run          # foreground run
./auto-loop.sh prepare      # tasks.md -> tasks.json
./auto-loop.sh doctor       # preview prepared JSON without writing
./auto-loop.sh validate     # validate tasks, preparing first if needed
./auto-loop.sh edit         # edit tasks.md or tasks.json, then validate
./auto-loop.sh status       # task status, engine spec, active engine
./auto-loop.sh sessions     # per-task sessions by engine
./auto-loop.sh attach <id>  # interactive pickup on the active engine session
./auto-loop.sh report       # write reports/report-<ts>.md
./auto-loop.sh stop         # stop the lock-file PID
```

Useful environment variables:

```bash
ENGINE=claude              # default primary engine when a task omits engine
MODEL=                     # default model when a task omits model
CLAUDE_RESUME_MODE=summary # full | summary | fresh
CODEX_COOLDOWN=3600        # fallback wait for Codex usage limits
AUDIT=1                    # require independent audit
AUDIT_ENGINE=              # override auditor engine
AUDIT_MODEL=               # override auditor model
REQUIRE_GIT=1              # task dir must be a git repo
```

## Positioning

`auto-loop` is not trying to be the biggest agent platform. Its edge is the narrow local workflow:

| Type | Representative examples | How they work | auto-loop difference |
|---|---|---|---|
| Task queue / rate-limit loop | `claude-queue`, queue-style runners | Python workers, priorities/dependencies, plan-limit monitoring, pause near quota | More focused on Claude+Codex dual engine, per-task sessions, and independent audit |
| Continuous loop tool | `Ralph` | Repeatedly calls coding agents with exit signals, circuit breakers, resume, logs | Do not compete on "infinite loop"; position as task list + quota sleep/fallback + audit |
| PR/CI workflow | `Continuous Claude`-style tools | Shared notes, PR creation, CI waiting, merge flow | Lighter, local-first, better for a personal backlog before PR machinery |
| Graphical command center | CloudCLI, Codexia, async-code-style tools | Web/mobile/desktop control, sessions, parallel tasks, worktrees, remote control | Smaller and more readable: Bash runner plus local stdlib UI |
| Official async agents | Claude Code on web, Claude routines, OpenAI Codex | Cloud sandbox, GitHub repo access, automatic PRs, parallel tasks | For users who still want local Claude Code/Codex CLI control and local files |
| Safety/guardrail layer | CC Safety Net-style tools | Hooks block dangerous commands | Complementary; auto-loop's guardrails are prompt-level plus audit, not an OS sandbox |

## Safety

This tool runs unattended with skipped approvals:

- Claude: `--dangerously-skip-permissions`
- Codex: `--dangerously-bypass-approvals-and-sandbox`

Use it only for repos where that is acceptable.

Guardrails:

- The worker prompt says to edit only inside the task `dir`.
- The worker must commit on a feature branch.
- The worker must not touch `main`/`master`, merge, force-push, or print secrets.
- Startup validation rejects malformed tasks and non-git dirs unless `REQUIRE_GIT=0`.
- A PID lock prevents two loops from running the same queue.
- Credentials should live in the environment, never in task files, logs, reports, or handoff docs.

Honest limitation: prompt-level rules are not a sandbox. A misbehaving or prompt-injected run can still execute local commands with the permissions you gave it. Keep backups, use disposable branches, and write concrete `done` checks.

## Files

```
auto-loop.sh              # runner: engines, fallback, sessions, audit, reports
scripts/prepare_tasks.py  # tasks.md -> tasks.json compiler
ui-server.py              # dependency-free local UI backend
ui.html                   # local UI
tasks.md.example          # human-friendly task template
tasks.example.json        # JSON schema example
tasks.md                  # local task source, git-ignored
tasks.json                # generated task list, git-ignored
state.json                # runtime state, git-ignored
logs/                     # transcripts and main log, git-ignored
reports/                  # markdown reports, git-ignored
summaries/                # context summaries, git-ignored
```

## License

Apache-2.0. See `LICENSE` and `NOTICE`.

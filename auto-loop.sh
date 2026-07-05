#!/usr/bin/env bash
# auto-loop — advance a fixed list of coding tasks SEQUENTIALLY with an agent CLI
# (Claude Code or OpenAI Codex), automatically waiting out usage-limit windows.
#
# How it works:
#   * Each task is handed to an agent CLI in NON-INTERACTIVE mode. When the agent hits
#     the account's usage limit, the loop sleeps until the window resets, then resumes
#     the SAME session for that task (so it continues, it does not restart).
#       - Claude: reads the rate_limit_event.resetsAt and sleeps to that exact moment.
#       - Codex:  no precise reset epoch is exposed, so it backs off CODEX_COOLDOWN.
#   * Tasks run one-by-one: finish the current task (across as many windows as it takes)
#     before starting the next.
#   * INDEPENDENT AUDIT: when a worker claims TASK_COMPLETE, a separate fresh auditor
#     agent must independently verify every "done" criterion before the task is marked
#     complete (no grading-its-own-homework). Toggle with AUDIT=0.
#   * INTERACTIVE PICKUP: every task keeps a resumable session_id, so you can jump into
#     the normal interactive TUI at any point with `./auto-loop.sh attach <id>`.
#   * A tiny local web UI (`./auto-loop.sh ui`) lets non-coders load tasks, watch status,
#     and read reports — the CLI is still the engine behind it.
#
# Usage:
#   ./auto-loop.sh [run]           # run the loop in the foreground
#   ./auto-loop.sh prepare         # compile tasks.md -> tasks.json and validate it
#   ./auto-loop.sh doctor          # preview prepared tasks.json without writing it
#   ./auto-loop.sh status          # print each task's state and exit
#   ./auto-loop.sh validate        # lint tasks.json without running anything
#   ./auto-loop.sh edit            # open tasks.md if present, else tasks.json, then re-validate
#   ./auto-loop.sh sessions        # list task -> engine -> session_id -> dir
#   ./auto-loop.sh attach <id>     # open the INTERACTIVE agent TUI on a task's session
#   ./auto-loop.sh report          # (re)generate a status report on demand
#   ./auto-loop.sh ui [port]       # launch the local web UI (default 127.0.0.1:8787)
#   ./auto-loop.sh stop            # stop a running loop (via lock file PID)
#   nohup ./auto-loop.sh >> logs/nohup.log 2>&1 &   # unattended background run
#
# Config: tasks.json (see tasks.example.json). Runtime state: state.json.
# Logs: logs/. Reports: reports/. Lock: .auto-loop.lock.
# Env overrides: ENGINE, MODEL, EFFORT, USAGE_LIMIT_THRESHOLD, PERM_FLAGS,
#   IDLE_SLEEP, RESET_BUFFER, MAX_ERRORS, CLAUDE_BIN, CLAUDE_RESUME_MODE,
#   CODEX_BIN, CODEX_COOLDOWN, REQUIRE_GIT, AUDIT, AUDIT_MODEL, AUDIT_ENGINE,
#   AUDIT_EFFORT, UI_PORT, EDITOR, TASKS_MD,
#   TASK_PREPARE_LLM, PREPARE_MODEL.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS="${TASKS_FILE:-$ROOT/tasks.json}"
TASKS_MD="${TASKS_MD:-$ROOT/tasks.md}"
STATE="${STATE_FILE:-$ROOT/state.json}"
LOGDIR="$ROOT/logs"
REPORTDIR="$ROOT/reports"
SUMMARYDIR="$ROOT/summaries"
LOCKFILE="$ROOT/.auto-loop.lock"
PREPARE_SCRIPT="$ROOT/scripts/prepare_tasks.py"
mkdir -p "$LOGDIR" "$REPORTDIR" "$SUMMARYDIR"

ENGINE="${ENGINE:-claude}"             # default agent engine: claude | codex
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_RESUME_MODE="${CLAUDE_RESUME_MODE:-full}"  # full | summary | fresh
CODEX_BIN="${CODEX_BIN:-codex}"
MODEL="${MODEL:-}"                     # empty -> per-task model, else account default
EFFORT="${EFFORT:-}"                   # empty -> per-task/default CLI effort
USAGE_LIMIT_THRESHOLD="${USAGE_LIMIT_THRESHOLD:-0.90}"  # reserve quota once utilization reaches this fraction
PERM_FLAGS="${PERM_FLAGS:---dangerously-skip-permissions}"  # claude: unattended, no prompts
IDLE_SLEEP="${IDLE_SLEEP:-20}"         # seconds between runs, avoids hammering
RESET_BUFFER="${RESET_BUFFER:-120}"    # extra seconds after resetsAt before retrying
CODEX_COOLDOWN="${CODEX_COOLDOWN:-3600}"  # codex back-off when usage-limited (no reset epoch)
MAX_ERRORS="${MAX_ERRORS:-3}"          # consecutive non-limit errors before parking a task
REQUIRE_GIT="${REQUIRE_GIT:-1}"        # 1 => a task dir must be a git repo (worker commits)
AUDIT="${AUDIT:-1}"                    # 1 => independent auditor must confirm TASK_COMPLETE
AUDIT_MODEL="${AUDIT_MODEL:-}"         # model for the auditor (default: task/global/default)
AUDIT_ENGINE="${AUDIT_ENGINE:-}"      # engine for the auditor (default: task engine)
AUDIT_EFFORT="${AUDIT_EFFORT:-}"       # effort for the auditor (default: task/global/default)
UI_PORT="${UI_PORT:-8787}"

ts(){ date '+%F %T'; }
log(){ printf '%s | %s\n' "$(ts)" "$*" | tee -a "$LOGDIR/main.log" >&2; }
die(){ log "FATAL: $*"; exit 1; }

command -v jq >/dev/null || die "jq not found on PATH"
[ -f "$TASKS" ] || [ -f "$TASKS_MD" ] || die "missing $TASKS — copy tasks.md.example to tasks.md and run ./auto-loop.sh prepare (or copy tasks.example.json to tasks.json)"
case "$ENGINE" in claude|codex) : ;; *) die "ENGINE must be claude|codex, got '$ENGINE'";; esac
case "$CLAUDE_RESUME_MODE" in full|summary|fresh) : ;; *) die "CLAUDE_RESUME_MODE must be full|summary|fresh, got '$CLAUDE_RESUME_MODE'";; esac
awk -v t="$USAGE_LIMIT_THRESHOLD" 'BEGIN{exit !(t > 0 && t <= 1)}' >/dev/null 2>&1 \
  || die "USAGE_LIMIT_THRESHOLD must be a number > 0 and <= 1, got '$USAGE_LIMIT_THRESHOLD'"

engine_bin(){ case "$1" in claude) echo "$CLAUDE_BIN";; codex) echo "$CODEX_BIN";; *) echo "";; esac; }
require_engine(){ local b; b="$(engine_bin "$1")"; [ -n "$b" ] || die "unknown engine: '$1' (use claude|codex)"; command -v "$b" >/dev/null || die "$1 CLI not found ($b)"; }
require_prepare_tool(){ command -v python3 >/dev/null || die "python3 not found (needed for tasks.md prepare)"; [ -f "$PREPARE_SCRIPT" ] || die "missing $PREPARE_SCRIPT"; }

run_prepare(){
  require_prepare_tool
  python3 "$PREPARE_SCRIPT" --root "$ROOT" --markdown "$TASKS_MD" --json "$TASKS" "$@"
}

maybe_prepare_tasks(){
  [ -f "$TASKS_MD" ] || return 0
  if [ ! -f "$TASKS" ] || [ "$TASKS_MD" -nt "$TASKS" ] || ! jq -e . "$TASKS" >/dev/null 2>&1; then
    log "prepare: compiling $TASKS_MD -> $TASKS"
    run_prepare || die "prepare failed"
  fi
}

# --- state.json helpers ------------------------------------------------------
state_write(){ local tmp; tmp="$(mktemp)"; cat > "$tmp" && mv "$tmp" "$STATE"; }

init_state(){
  [ -f "$STATE" ] || echo '{}' > "$STATE"
  [ -f "$TASKS" ] || die "missing $TASKS — run ./auto-loop.sh prepare to generate it from $TASKS_MD"
  local count id
  count="$(jq -r '.tasks | length' "$TASKS")" || die "tasks.json: cannot read .tasks"
  [ "$count" -gt 0 ] || die "tasks.json has no tasks"
  while IFS= read -r id; do
    if [ "$(jq --arg id "$id" 'has($id)' "$STATE")" != "true" ]; then
      jq --arg id "$id" '.[$id]={status:"pending",session_id:null,sessions:{},active_engine:"",limited_engines:{},runs:0,errors:0,summary:"",last:"",resume_summary_next:false}' "$STATE" | state_write
    fi
  done < <(jq -r '.tasks[].id' "$TASKS")
  jq '
    to_entries
    | map(.value |= (
        .sessions = (.sessions // {})
        | .active_engine = (.active_engine // "")
        | .limited_engines = (.limited_engines // {})
        | .resume_summary_next = (.resume_summary_next // false)
      ))
    | from_entries
  ' "$STATE" | state_write
}

sget(){ jq -r --arg id "$1" ".[\$id].$2 // \"\"" "$STATE"; }   # sget <id> <field>
sset(){ local id="$1"; shift; jq --arg id "$id" "$@" "$STATE" | state_write; }  # sset <id> [jq args] <filter>
tget(){ jq -r --arg id "$1" ".tasks[]|select(.id==\$id)|.$2 // \"\"" "$TASKS"; }  # tget <id> <field>
task_engine(){ local e; e="$(tget "$1" engine)"; [ -z "$e" ] && e="$ENGINE"; echo "$e"; }
task_fallback_engine(){ local e; e="$(tget "$1" fallback_engine)"; echo "$e"; }
task_engine_spec(){
  local id="$1" primary fallback
  primary="$(task_engine "$id")"; fallback="$(task_fallback_engine "$id")"
  [ -n "$fallback" ] && [ "$fallback" != "$primary" ] && printf '%s->%s' "$primary" "$fallback" || printf '%s' "$primary"
}
task_engines(){
  local id="$1" primary fallback
  primary="$(task_engine "$id")"; fallback="$(task_fallback_engine "$id")"
  printf '%s\n' "$primary"
  [ -n "$fallback" ] && [ "$fallback" != "$primary" ] && printf '%s\n' "$fallback"
}
engine_ready(){
  local b; b="$(engine_bin "$1")"
  [ -n "$b" ] && command -v "$b" >/dev/null 2>&1
}
engine_limit_until(){ jq -r --arg id "$1" --arg e "$2" '.[$id].limited_engines[$e].until // 0' "$STATE"; }
engine_available(){
  local until
  until="$(engine_limit_until "$1" "$2")"
  [[ "$until" =~ ^[0-9]+$ ]] || return 0
  [ "$until" -le "$(date +%s)" ]
}
task_active_engine(){
  local id="$1" active e
  active="$(sget "$id" active_engine)"
  if [ -n "$active" ]; then
    while IFS= read -r e; do
      [ "$e" = "$active" ] && engine_available "$id" "$e" && { echo "$active"; return; }
    done < <(task_engines "$id")
  fi
  while IFS= read -r e; do
    engine_available "$id" "$e" && { echo "$e"; return; }
  done < <(task_engines "$id")
  [ -n "$active" ] && echo "$active" || task_engine "$id"
}
task_model_for_engine(){
  local id="$1" engine="$2" primary fallback model
  primary="$(task_engine "$id")"; fallback="$(task_fallback_engine "$id")"
  if [ "$engine" = "$fallback" ] && [ "$fallback" != "$primary" ]; then
    model="$(tget "$id" fallback_model)"
  else
    model="$(tget "$id" model)"
  fi
  [ -z "$model" ] && model="$MODEL"
  echo "$model"
}
normalize_effort_for_engine(){
  local engine="$1" raw="$2" effort
  effort="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[ _-]+/ /g; s/^ +//; s/ +$//')"
  [ -z "$effort" ] && return 0
  case "$engine" in
    claude)
      case "$effort" in
        low|medium|high|max) printf '%s\n' "$effort";;
        extra|"extra high"|xhigh) printf 'xhigh\n';;
        *) return 1;;
      esac
      ;;
    codex)
      case "$effort" in
        light|low) printf 'low\n';;
        medium|high) printf '%s\n' "$effort";;
        extra|"extra high"|xhigh) printf 'xhigh\n';;
        *) return 1;;
      esac
      ;;
    *) return 1;;
  esac
}
task_effort_for_engine(){
  local id="$1" engine="$2" primary fallback effort normalized
  primary="$(task_engine "$id")"; fallback="$(task_fallback_engine "$id")"
  if [ "$engine" = "$fallback" ] && [ "$fallback" != "$primary" ]; then
    effort="$(tget "$id" fallback_effort)"
    [ -z "$effort" ] && effort="$(tget "$id" effort)"
  else
    effort="$(tget "$id" effort)"
  fi
  [ -z "$effort" ] && effort="$EFFORT"
  [ -z "$effort" ] && return 0
  normalized="$(normalize_effort_for_engine "$engine" "$effort")" || return 1
  echo "$normalized"
}
task_effort_label_for_engine(){
  local effort
  effort="$(task_effort_for_engine "$1" "$2" 2>/dev/null)" || { echo "invalid"; return 0; }
  [ -n "$effort" ] && echo "$effort" || echo "-"
}
task_effort_spec(){
  local id="$1" primary fallback primary_eff fallback_eff
  primary="$(task_engine "$id")"; fallback="$(task_fallback_engine "$id")"
  primary_eff="$(task_effort_label_for_engine "$id" "$primary")"
  if [ -n "$fallback" ] && [ "$fallback" != "$primary" ]; then
    fallback_eff="$(task_effort_label_for_engine "$id" "$fallback")"
    printf '%s->%s' "$primary_eff" "$fallback_eff"
  else
    printf '%s' "$primary_eff"
  fi
}
session_get(){
  jq -r --arg id "$1" --arg e "$2" '.[$id].sessions[$e] // ""' "$STATE"
}
session_set(){
  local id="$1" engine="$2" sid="$3"
  sset "$id" --arg e "$engine" --arg s "$sid" '.[$id].sessions[$e]=$s|.[$id].session_id=$s|.[$id].active_engine=$e'
}
record_engine_limit(){
  local id="$1" engine="$2" until="$3" status="${4:-rejected}" util="${5:-}"
  sset "$id" --arg e "$engine" --argjson until "$until" --arg t "$(ts)" --arg status "$status" --arg util "$util" '
    .[$id].limited_engines[$e]={until:$until,last:$t,status:$status}
    | if $util != "" then .[$id].limited_engines[$e].utilization=($util|tonumber? // $util) else . end
    | .[$id].summary=(if $status=="soft_limit" then ("usage reserve reached on "+$e) else ("rate limited on "+$e) end)
  '
}
clear_engine_limit(){
  local id="$1" engine="$2"
  sset "$id" --arg e "$engine" 'del(.[$id].limited_engines[$e])'
}
switch_to_available_fallback(){
  local id="$1" limited_engine="$2" e
  while IFS= read -r e; do
    [ "$e" = "$limited_engine" ] && continue
    if engine_available "$id" "$e" && engine_ready "$e"; then
      sset "$id" --arg e "$e" '.[$id].active_engine=$e'
      log "[$id] $limited_engine is limited; continuing with fallback engine $e"
      return 0
    fi
    engine_available "$id" "$e" && log "[$id] fallback engine $e is configured but CLI is not available"
  done < <(task_engines "$id")
  return 1
}
task_next_reset_epoch(){
  local id="$1" now min="" e until
  now="$(date +%s)"
  while IFS= read -r e; do
    until="$(engine_limit_until "$id" "$e")"
    [[ "$until" =~ ^[0-9]+$ ]] || continue
    [ "$until" -le "$now" ] && continue
    if [ -z "$min" ] || [ "$until" -lt "$min" ]; then min="$until"; fi
  done < <(task_engines "$id")
  [ -n "$min" ] && echo "$min" || resolve_reset_epoch
}

next_task(){                       # first active task in file order
  local id st
  while IFS= read -r id; do
    st="$(sget "$id" status)"
    case "$st" in pending|in_progress|review) echo "$id"; return 0;; esac
  done < <(jq -r '.tasks[].id' "$TASKS")
  return 1
}

# --- task-spec validation ("check the spec, adjust so it runs best") ---------
validate_tasks(){
  local rc=0 n i id dir goal donc eng fallback effort fallback_effort primary_engine fallback_engine primary_effort fallback_effort_effective seen=""
  jq -e '.tasks | type=="array"' "$TASKS" >/dev/null 2>&1 || { log "VALIDATE: .tasks is not an array"; return 1; }
  n="$(jq -r '.tasks | length' "$TASKS")"
  [ "$n" -gt 0 ] || { log "VALIDATE: tasks.json has no tasks"; return 1; }
  for ((i=0; i<n; i++)); do
    id="$(jq -r ".tasks[$i].id // \"\"" "$TASKS")"
    dir="$(jq -r ".tasks[$i].dir // \"\"" "$TASKS")"
    goal="$(jq -r ".tasks[$i].goal // \"\"" "$TASKS")"
    donc="$(jq -r ".tasks[$i].done // \"\"" "$TASKS")"
    eng="$(jq -r ".tasks[$i].engine // \"\"" "$TASKS")"
    fallback="$(jq -r ".tasks[$i].fallback_engine // \"\"" "$TASKS")"
    effort="$(jq -r ".tasks[$i].effort // \"\"" "$TASKS")"
    fallback_effort="$(jq -r ".tasks[$i].fallback_effort // \"\"" "$TASKS")"
    if [ -z "$id" ]; then log "VALIDATE[#$i]: missing id"; rc=1; continue; fi
    [[ "$id" =~ ^[a-z0-9-]+$ ]] || { log "VALIDATE[$id]: id should match ^[a-z0-9-]+$ (slug)"; rc=1; }
    case " $seen " in *" $id "*) log "VALIDATE[$id]: duplicate id"; rc=1;; esac
    seen="$seen $id"
    [ -n "$goal" ] || { log "VALIDATE[$id]: empty goal"; rc=1; }
    [ -n "$donc" ] || { log "VALIDATE[$id]: empty done-criteria"; rc=1; }
    case "$eng" in ""|claude|codex) : ;; *) log "VALIDATE[$id]: engine must be claude|codex, got '$eng'"; rc=1;; esac
    case "$fallback" in ""|claude|codex) : ;; *) log "VALIDATE[$id]: fallback_engine must be claude|codex, got '$fallback'"; rc=1;; esac
    [ -n "$fallback" ] && [ "$fallback" = "${eng:-$ENGINE}" ] && log "VALIDATE[$id]: WARN fallback_engine matches primary engine: '$fallback'"
    primary_engine="${eng:-$ENGINE}"
    fallback_engine="${fallback:-$primary_engine}"
    primary_effort="${effort:-$EFFORT}"
    fallback_effort_effective="${fallback_effort:-${effort:-$EFFORT}}"
    if [ -n "$primary_effort" ] && ! normalize_effort_for_engine "$primary_engine" "$primary_effort" >/dev/null; then
      log "VALIDATE[$id]: invalid effort '$primary_effort' for engine '$primary_engine'"; rc=1
    fi
    if [ -n "$fallback_effort_effective" ] && ! normalize_effort_for_engine "$fallback_engine" "$fallback_effort_effective" >/dev/null; then
      log "VALIDATE[$id]: invalid fallback_effort '$fallback_effort_effective' for engine '$fallback_engine'"; rc=1
    fi
    if [ -z "$dir" ]; then log "VALIDATE[$id]: empty dir"; rc=1
    else
      case "$dir" in /*) : ;; *) log "VALIDATE[$id]: dir must be an absolute path: '$dir'"; rc=1;; esac
      if [ ! -d "$dir" ]; then log "VALIDATE[$id]: dir does not exist: '$dir'"; rc=1
      elif [ ! -d "$dir/.git" ] && ! ( cd "$dir" && git rev-parse --git-dir >/dev/null 2>&1 ); then
        if [ "$REQUIRE_GIT" = "1" ]; then log "VALIDATE[$id]: dir is not a git repo (worker must commit): '$dir'"; rc=1
        else log "VALIDATE[$id]: WARN dir is not a git repo: '$dir'"; fi
      fi
    fi
    printf '%s\n' "$donc" | grep -qiE '(npm|pnpm|yarn|pytest|uv |cargo|go test|make|build|test|passes|exit 0|http)' \
      || log "VALIDATE[$id]: WARN done-criteria has no obvious checkable command/artifact"
  done
  return "$rc"
}

detect_repo_hint(){
  local dir="$1" h=""
  [ -f "$dir/package.json" ]   && h="$h; node/npm (inspect package.json scripts for build/test)"
  { [ -f "$dir/pyproject.toml" ] || [ -f "$dir/uv.lock" ]; } && h="$h; python (try: uv run pytest -q)"
  [ -f "$dir/requirements.txt" ] && h="$h; python (pip/requirements.txt)"
  [ -f "$dir/Cargo.toml" ]     && h="$h; rust (cargo build && cargo test)"
  [ -f "$dir/go.mod" ]         && h="$h; go (go build ./... && go test ./...)"
  [ -f "$dir/Makefile" ]       && h="$h; make (check targets: build/test)"
  [ -n "$h" ] && printf 'Detected in this repo:%s.' "${h# ; }"
}

summary_file(){ printf '%s/%s.md' "$SUMMARYDIR" "$1"; }

task_context_summary(){
  local id="$1" f
  f="$(summary_file "$id")"
  [ -s "$f" ] && cat "$f"
}

write_task_summary(){
  local id="$1" dir goal donc f tmp sid result line branch sessions
  dir="$(tget "$id" dir)"; goal="$(tget "$id" goal)"; donc="$(tget "$id" done)"
  f="$(summary_file "$id")"; tmp="$f.tmp"
  sid="$SESSION_ID"; [ -z "$sid" ] || [ "$sid" = "null" ] && sid="$(session_get "$id" "$CUR_ENGINE")"
  sessions="$(jq -c --arg id "$id" '.[$id].sessions // {}' "$STATE")"
  result="$(printf '%s\n' "$RESULT_TEXT" | sed -e 's/[[:cntrl:]]//g' | head -c 4000)"
  line="$(printf '%s\n' "$RESULT_TEXT" | grep -oE 'TASK_(COMPLETE|BLOCKED|PROGRESS).*' | tail -1)"
  branch=""
  if [ -d "$dir/.git" ] || ( cd "$dir" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ); then
    branch="$(cd "$dir" && git branch --show-current 2>/dev/null)"
  fi
  {
    printf '# auto-loop context summary: %s\n\n' "$id"
    printf -- '- Updated: %s\n' "$(ts)"
    printf -- '- Task dir: `%s`\n' "$dir"
    printf -- '- Current branch: `%s`\n' "${branch:-unknown}"
    printf -- '- Active engine: `%s`\n' "${CUR_ENGINE:-$(task_active_engine "$id")}"
    printf -- '- Last known active session id: `%s`\n' "${sid:-unknown}"
    printf -- '- Sessions by engine: `%s`\n' "$sessions"
    printf -- '- Last sentinel: %s\n\n' "${line:-none}"
    printf '## Goal\n\n%s\n\n' "$goal"
    printf '## Done Criteria\n\n%s\n\n' "$donc"
    printf '## Last Worker Result\n\n%s\n\n' "${result:-No result text captured.}"
    if [ -d "$dir/.git" ] || ( cd "$dir" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ); then
      printf '## Recent Commits\n\n```\n'
      ( cd "$dir" && git log --oneline -5 2>/dev/null )
      printf '```\n'
    fi
  } > "$tmp" && mv "$tmp" "$f"
}

mark_summary_resume_next(){
  local id="$1"
  [ "$CLAUDE_RESUME_MODE" = "summary" ] || return 0
  [ "$CUR_ENGINE" = "claude" ] || return 0
  sset "$id" '.[$id].resume_summary_next=true'
  log "[$id] CLAUDE_RESUME_MODE=summary — next worker run will start fresh from $(summary_file "$id")"
}

clear_summary_resume_next(){
  local id="$1"
  [ "$CUR_ENGINE" = "claude" ] || return 0
  [ "$(sget "$id" resume_summary_next)" = "true" ] && sset "$id" '.[$id].resume_summary_next=false'
}

# --- lock --------------------------------------------------------------------
loop_pid(){ [ -f "$LOCKFILE" ] && cat "$LOCKFILE" 2>/dev/null; }
loop_running(){ local p; p="$(loop_pid)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
acquire_lock(){ if loop_running; then die "another auto-loop is already running (PID $(loop_pid)). Use './auto-loop.sh stop' first."; fi; echo "$$" > "$LOCKFILE"; trap 'release_lock' EXIT INT TERM; }
release_lock(){ [ -f "$LOCKFILE" ] && [ "$(cat "$LOCKFILE" 2>/dev/null)" = "$$" ] && rm -f "$LOCKFILE"; }

# --- low-level engine call ---------------------------------------------------
# llm_run <engine> <dir> <sid> <model> <effort> <instructions> <nudge> <outfile>
# Sets: LLM_TEXT LLM_SID LLM_EC LLM_RL(allowed|rejected|soft_limit) LLM_RESETS LLM_UTILIZATION LLM_ERR(true|false)
LLM_TEXT="" LLM_SID="" LLM_EC=0 LLM_RL="allowed" LLM_RESETS="" LLM_UTILIZATION="" LLM_ERR="false"
usage_over_threshold(){
  local util="$1"
  [ -n "$util" ] || return 1
  awk -v u="$util" -v t="$USAGE_LIMIT_THRESHOLD" 'BEGIN{exit !((u + 0) >= (t + 0))}' >/dev/null 2>&1
}
llm_run(){
  local engine="$1" dir="$2" sid="$3" model="$4" effort="$5" instr="$6" nudge="$7" out="$8"
  LLM_TEXT="" LLM_SID="" LLM_EC=0 LLM_RL="allowed" LLM_RESETS="" LLM_UTILIZATION="" LLM_ERR="false"
  if [ "$engine" = "claude" ]; then
    local -a a=(-p "$nudge" --output-format json --add-dir "$dir" --append-system-prompt "$instr")
    # shellcheck disable=SC2206
    a+=($PERM_FLAGS)
    [ -n "$model" ] && a+=(--model "$model")
    [ -n "$effort" ] && a+=(--effort "$effort")
    [ -n "$sid" ] && [ "$sid" != "null" ] && a+=(--resume "$sid")
    ( cd "$dir" && "$CLAUDE_BIN" "${a[@]}" ) > "$out" 2>&1 </dev/null; LLM_EC=$?
    LLM_RL="$(jq -r 'try ((if type=="array" then .[] else . end)|select(.type=="rate_limit_event")|.rate_limit_info.status) catch empty' "$out" 2>/dev/null | tail -1)"; [ -z "$LLM_RL" ] && LLM_RL="allowed"
    LLM_RESETS="$(jq -r 'try ((if type=="array" then .[] else . end)|select(.type=="rate_limit_event")|.rate_limit_info.resetsAt) catch empty' "$out" 2>/dev/null | tail -1)"
    LLM_UTILIZATION="$(jq -r 'try ((if type=="array" then .[] else . end)|select(.type=="rate_limit_event")|.rate_limit_info.utilization // empty) catch empty' "$out" 2>/dev/null | tail -1)"
    LLM_TEXT="$(jq -r 'try ((if type=="array" then .[] else . end)|select(.type=="result")|.result)   catch empty' "$out" 2>/dev/null | tail -1)"
    LLM_SID="$(jq -r 'try ((if type=="array" then .[] else . end)|select(.type=="result")|.session_id) catch empty' "$out" 2>/dev/null | tail -1)"
    [ "$(jq -r 'try ((if type=="array" then .[] else . end)|select(.type=="result")|.is_error) catch empty' "$out" 2>/dev/null | tail -1)" = "true" ] && LLM_ERR="true"
    if [ "$LLM_RL" != "rejected" ]; then
      if usage_over_threshold "$LLM_UTILIZATION"; then LLM_RL="soft_limit"; else LLM_RL="allowed"; fi
    fi
    [ "$LLM_EC" -ne 0 ] && [ "$LLM_RL" = "allowed" ] && LLM_ERR="true"
  else  # codex
    local last="$out.last"; : > "$last"
    local prompt="$instr

$nudge"
    local -a a=()
    if [ -n "$sid" ] && [ "$sid" != "null" ]; then a=(exec resume "$sid" --json --dangerously-bypass-approvals-and-sandbox -o "$last")
    else a=(exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -o "$last"); fi
    [ -n "$model" ] && a+=(-m "$model")
    [ -n "$effort" ] && a+=(-c "model_reasoning_effort=\"$effort\"")
    ( cd "$dir" && "$CODEX_BIN" "${a[@]}" "$prompt" ) > "$out" 2>&1 </dev/null; LLM_EC=$?
    LLM_SID="$(grep -m1 -oE '"thread_id":"[0-9a-fA-F-]+"' "$out" 2>/dev/null | head -1 | sed 's/.*:"//;s/"$//')"
    [ -s "$last" ] && LLM_TEXT="$(cat "$last")"
    if grep -qiE 'rate limit|usage limit|reached your usage|too many requests|429|quota|please try again later' "$out" "$last" 2>/dev/null; then LLM_RL="rejected"; fi
    [ "$LLM_EC" -ne 0 ] && [ "$LLM_RL" = "allowed" ] && LLM_ERR="true"
  fi
}

# --- one worker run ----------------------------------------------------------
RL_STATUS="" RESETS_AT="" USAGE_UTILIZATION="" IS_ERROR="" RESULT_TEXT="" SESSION_ID="" RUN_OUT="" CUR_ENGINE=""

run_task(){
  local id="$1" dir goal donc sid runs model effort engine primary candidate hint resume_sid resume_mode summary_text
  dir="$(tget "$id" dir)"; goal="$(tget "$id" goal)"; donc="$(tget "$id" done)"
  primary="$(task_engine "$id")"; engine="$(task_active_engine "$id")"
  if ! engine_ready "$engine"; then
    while IFS= read -r candidate; do
      if engine_available "$id" "$candidate" && engine_ready "$candidate"; then
        engine="$candidate"
        break
      fi
    done < <(task_engines "$id")
  fi
  CUR_ENGINE="$engine"
  RL_STATUS="" RESETS_AT="" USAGE_UTILIZATION="" IS_ERROR="" RESULT_TEXT="" SESSION_ID="" RUN_OUT=""
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    log "[$id] dir missing or not found: '$dir' — parking as error"
    sset "$id" --arg d "$dir" '.[$id].status="error"|.[$id].summary=("dir not found: "+$d)'; return 1
  fi
  if [ "$REQUIRE_GIT" = "1" ] && [ ! -d "$dir/.git" ] && ! ( cd "$dir" && git rev-parse --git-dir >/dev/null 2>&1 ); then
    log "[$id] dir is not a git repo but worker must commit: '$dir' — parking (set REQUIRE_GIT=0 to override)"
    sset "$id" --arg d "$dir" '.[$id].status="error"|.[$id].summary=("not a git repo: "+$d)'; return 1
  fi
  require_engine "$engine"
  sset "$id" --arg e "$engine" '.[$id].active_engine=$e'
  sid="$(session_get "$id" "$engine")"; runs="$(sget "$id" runs)"; resume_sid="$sid"; resume_mode="$CLAUDE_RESUME_MODE"
  model="$(task_model_for_engine "$id" "$engine")"
  effort="$(task_effort_for_engine "$id" "$engine")" || die "invalid effort for task '$id' on engine '$engine'"
  hint="$(detect_repo_hint "$dir")"

  local instr="You are an unattended coding agent advancing ONE task by a bounded, safe increment. No human is watching this run.
TASK: $goal
DONE WHEN: $donc
${hint:+REPO HINT: $hint}
Rules: edit only inside $dir; you may read explicitly referenced plan/context files outside $dir. Make real progress and COMMIT it on a feature branch; inspect git status before editing and before committing; do not stage unrelated pre-existing changes or untracked files. NEVER touch main/master, NEVER force-push, NEVER merge; never write or print secret values; keep the repo runnable. Do not wait for input — if a choice is needed, take the most reasonable option and record it. Keep each run to one coherent chunk; you will be invoked again to continue. An INDEPENDENT auditor will verify your work, so do not claim completion unless every done-criterion is objectively met.
Finish your FINAL message with EXACTLY ONE sentinel line:
TASK_COMPLETE — every done-criterion is met and you verified it
TASK_BLOCKED: <one-line reason> — you cannot proceed without a human decision/credential
TASK_PROGRESS: <one-line summary of what you did this run> — otherwise"
  local nudge="Advance this task by one meaningful, safe increment now. First inspect the current state (git status/log, recent files) so you continue rather than restart. Do the next chunk, verify it, commit on a branch. Then output your single sentinel line."

  if [ "$engine" = "claude" ]; then
    if [ "$resume_mode" = "fresh" ]; then
      resume_sid=""
      summary_text="$(task_context_summary "$id")"
    elif [ "$resume_mode" = "summary" ] && [ "$(sget "$id" resume_summary_next)" = "true" ]; then
      summary_text="$(task_context_summary "$id")"
      if [ -n "$summary_text" ]; then
        resume_sid=""
      else
        log "[$id] summary resume requested but no summary exists yet; falling back to full --resume"
      fi
    fi
    if [ -n "$summary_text" ] && [ -z "$resume_sid" ]; then
      nudge="Previous context summary for this task:

$summary_text

Use this summary and the repo state as continuity context. Do not assume the full previous transcript is available.

$nudge"
    fi
  fi
  if [ "$engine" != "$primary" ] && [ -z "$resume_sid" ]; then
    summary_text="$(task_context_summary "$id")"
    nudge="This task is continuing on fallback engine '$engine' because '$primary' was rate-limited. Use the repo state as the source of truth.${summary_text:+

Previous context summary for this task:

$summary_text}

$nudge"
  fi

  local out="$LOGDIR/${id}-$(date +%Y%m%d-%H%M%S).json"; RUN_OUT="$out"
  log "[$id] run #$((runs+1)) via $engine in $dir${model:+ model=$model}${effort:+ effort=$effort}${resume_sid:+ resume=$resume_sid}${summary_text:+ summary_context=1}"
  llm_run "$engine" "$dir" "$resume_sid" "$model" "$effort" "$instr" "$nudge" "$out"
  RL_STATUS="$LLM_RL"; RESETS_AT="$LLM_RESETS"; USAGE_UTILIZATION="$LLM_UTILIZATION"; IS_ERROR="$LLM_ERR"; RESULT_TEXT="$LLM_TEXT"; SESSION_ID="$LLM_SID"
  log "[$id] exit=$LLM_EC rate_limit=$RL_STATUS${USAGE_UTILIZATION:+ utilization=$USAGE_UTILIZATION threshold=$USAGE_LIMIT_THRESHOLD} is_error=$IS_ERROR"
}

limited(){
  case "$RL_STATUS" in rejected|soft_limit) return 0;; esac
  [ -n "$RUN_OUT" ] && [ -f "$RUN_OUT" ] && [ "$RL_STATUS" != "allowed" ] && grep -qiE 'usage limit reached|rate limit|limit will reset|resets? at' "$RUN_OUT" && return 0
  return 1
}
hard_limited(){
  [ "$RL_STATUS" = "rejected" ] && return 0
  [ -n "$RUN_OUT" ] && [ -f "$RUN_OUT" ] && [ "$RL_STATUS" != "allowed" ] && [ "$RL_STATUS" != "soft_limit" ] && grep -qiE 'usage limit reached|rate limit|limit will reset|resets? at' "$RUN_OUT" && return 0
  return 1
}
soft_limited(){ [ "$RL_STATUS" = "soft_limit" ]; }

resolve_reset_epoch(){
  local e="$RESETS_AT"
  [[ "$e" =~ ^[0-9]+$ ]] || e="$(grep -oE '[0-9]{10}' "$RUN_OUT" 2>/dev/null | tail -1)"
  if ! [[ "$e" =~ ^[0-9]+$ ]]; then
    if [ "$CUR_ENGINE" = "codex" ]; then e=$(( $(date +%s) + CODEX_COOLDOWN )); log "codex: no reset epoch; backing off ${CODEX_COOLDOWN}s"
    else e=$(( $(date +%s) + 5*3600 )); log "no resetsAt found; defaulting to +5h"; fi
  fi
  echo "$e"
}

sleep_until_reset(){
  sleep_until_epoch "$(resolve_reset_epoch)"
}

sleep_until_epoch(){
  local epoch="$1" now target wait
  now="$(date +%s)"; target=$(( epoch + RESET_BUFFER )); wait=$(( target - now ))
  [ "$wait" -lt 30 ] && wait=30
  log "LIMITED — sleeping ${wait}s (~$(( wait/60 ))m) until $(date -r "$target" '+%F %T %Z')"
  sleep "$wait"
}

handle_rate_limit(){
  local id="$1" epoch
  epoch="$(resolve_reset_epoch)"
  record_engine_limit "$id" "$CUR_ENGINE" "$epoch" "$RL_STATUS" "$USAGE_UTILIZATION"
  if [ "$RL_STATUS" = "soft_limit" ]; then
    log "[$id] $CUR_ENGINE utilization ${USAGE_UTILIZATION:-unknown} reached reserve threshold $USAGE_LIMIT_THRESHOLD"
  fi
  [ "$CUR_ENGINE" = "claude" ] && mark_summary_resume_next "$id"
  if switch_to_available_fallback "$id" "$CUR_ENGINE"; then
    write_report "rate-limit-fallback" >/dev/null
    return 0
  fi
  write_report "rate-limit-window-end" >/dev/null
  sleep_until_epoch "$(task_next_reset_epoch "$id")"
}

# --- independent auditor -----------------------------------------------------
AUDIT_VERDICT="" AUDIT_REASON=""
run_audit(){
  local id="$1" dir donc engine model effort out line
  dir="$(tget "$id" dir)"; donc="$(tget "$id" done)"
  engine="$AUDIT_ENGINE"; [ -z "$engine" ] && engine="$(task_active_engine "$id")"
  model="$AUDIT_MODEL"; [ -z "$model" ] && model="$(task_model_for_engine "$id" "$engine")"
  if [ -n "$AUDIT_EFFORT" ]; then
    effort="$(normalize_effort_for_engine "$engine" "$AUDIT_EFFORT")" || die "invalid AUDIT_EFFORT '$AUDIT_EFFORT' for engine '$engine'"
  else
    effort="$(task_effort_for_engine "$id" "$engine")" || die "invalid effort for audit task '$id' on engine '$engine'"
  fi
  CUR_ENGINE="$engine"; AUDIT_VERDICT=""; AUDIT_REASON=""
  require_engine "$engine"

  local instr="You are an INDEPENDENT completion auditor. A previous agent claims this task is done; do NOT trust that claim — verify it yourself, objectively and skeptically.
DONE WHEN (the ONLY thing that matters): $donc
Working dir: $dir
Verify EVERY criterion yourself: inspect git (status, log, and the diff on the feature branch), read the actually-changed files, and RUN the exact verification commands named in DONE WHEN (build/test/etc.) to confirm they pass right now. You MAY run commands to verify. You MUST NOT edit files, create/switch/commit branches, push, or change any state — verification only. If a required check cannot be run, or ANY criterion is unmet, ambiguous, or unverifiable, that is a FAIL.
Finish with EXACTLY ONE line:
AUDIT_PASS — every criterion objectively verified just now
AUDIT_FAIL: <one-line reason naming the unmet or unverifiable criterion>"
  local nudge="Audit this task now against DONE WHEN. Run the checks yourself. Output your single AUDIT_ line."

  out="$LOGDIR/${id}-audit-$(date +%Y%m%d-%H%M%S).json"; RUN_OUT="$out"
  log "[$id] AUDIT via $engine${model:+ model=$model}${effort:+ effort=$effort}"
  llm_run "$engine" "$dir" "" "$model" "$effort" "$instr" "$nudge" "$out"
  RL_STATUS="$LLM_RL"; RESETS_AT="$LLM_RESETS"; USAGE_UTILIZATION="$LLM_UTILIZATION"
  if limited; then AUDIT_VERDICT="ratelimited"; return; fi
  line="$(printf '%s\n' "$LLM_TEXT" | grep -oE 'AUDIT_(PASS|FAIL).*' | tail -1)"
  case "$line" in
    AUDIT_PASS*) AUDIT_VERDICT="pass"; AUDIT_REASON="$line";;
    AUDIT_FAIL*) AUDIT_VERDICT="fail"; AUDIT_REASON="$line";;
    *)           AUDIT_VERDICT="inconclusive"; AUDIT_REASON="auditor emitted no AUDIT_ sentinel";;
  esac
  log "[$id] AUDIT verdict=$AUDIT_VERDICT — ${AUDIT_REASON:0:80}"
}

# handle a task in 'review' state: audit it, then decide its fate
do_review(){
  local id="$1"
  if [ "$AUDIT" != "1" ]; then sset "$id" '.[$id].status="complete"'; log "[$id] COMPLETE (audit disabled)"; return; fi
  run_audit "$id"
  case "$AUDIT_VERDICT" in
    pass)         sset "$id" --arg l "$AUDIT_REASON" '.[$id].status="complete"|.[$id].summary=("AUDITED ✓ "+$l)'; log "[$id] COMPLETE (audit passed)";;
    fail)         sset "$id" --arg l "$AUDIT_REASON" '.[$id].status="in_progress"|.[$id].summary=("AUDIT FAILED: "+$l)'; log "[$id] audit FAILED — back to in_progress";;
    ratelimited)  handle_rate_limit "$id";;   # stay 'review', retry
    *)            sset "$id" --arg l "$AUDIT_REASON" '.[$id].status="in_progress"|.[$id].summary=("AUDIT INCONCLUSIVE: "+$l)'; log "[$id] audit inconclusive — back to in_progress";;
  esac
}

apply_result(){
  local id="$1" line
  [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "null" ] && session_set "$id" "$CUR_ENGINE" "$SESSION_ID"
  sset "$id" --arg t "$(ts)" '.[$id].runs=(.[$id].runs+1)|.[$id].last=$t'
  if [ "$IS_ERROR" = "true" ]; then
    local n; n=$(( $(sget "$id" errors) + 1 ))
    sset "$id" --argjson n "$n" '.[$id].errors=$n'
    if [ "$n" -ge "$MAX_ERRORS" ]; then sset "$id" '.[$id].status="error"'; log "[$id] error x$n — parking task"
    else log "[$id] error x$n — will retry next pass"; fi
    return
  fi
  sset "$id" '.[$id].errors=0'
  clear_engine_limit "$id" "$CUR_ENGINE"
  clear_summary_resume_next "$id"
  line="$(printf '%s\n' "$RESULT_TEXT" | grep -oE 'TASK_(COMPLETE|BLOCKED|PROGRESS).*' | tail -1)"
  case "$line" in
    TASK_COMPLETE*) sset "$id" --arg l "$line" '.[$id].status="review"|.[$id].summary=$l'; log "[$id] worker claims COMPLETE — queued for audit";;
    TASK_BLOCKED*)  sset "$id" --arg l "$line" '.[$id].status="blocked"|.[$id].summary=$l';  log "[$id] BLOCKED — $line";;
	    *)              sset "$id" --arg l "${line:-TASK_PROGRESS: (no sentinel emitted)}" '.[$id].status="in_progress"|.[$id].summary=$l'; log "[$id] progress — ${line:-<none>}";;
  esac
  write_task_summary "$id"
}

# --- reports -----------------------------------------------------------------
write_report(){
  local reason="${1:-manual}" f id st runs errs last summ dir eng effort active limits
  f="$REPORTDIR/report-$(date +%Y%m%d-%H%M%S).md"
  {
    printf '# auto-loop report\n\n- Generated: %s\n- Trigger: %s\n- Tasks file: `%s`\n\n' "$(ts)" "$reason" "$TASKS"
    printf '## Task status\n\n| task | engine spec | effort | active | status | runs | err | last | summary |\n|------|-------------|--------|--------|--------|------|-----|------|---------|\n'
    while IFS= read -r id; do
      st="$(sget "$id" status)"; runs="$(sget "$id" runs)"; errs="$(sget "$id" errors)"
      last="$(sget "$id" last)"; eng="$(task_engine_spec "$id")"; effort="$(task_effort_spec "$id")"; active="$(task_active_engine "$id")"; summ="$(sget "$id" summary | tr '|' '/' | cut -c1-90)"
      printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' "$id" "$eng" "$effort" "$active" "$st" "$runs" "$errs" "${last:-–}" "${summ:-–}"
    done < <(jq -r '.tasks[].id' "$TASKS")
    printf '\n## Limited engines\n\n'
    while IFS= read -r id; do
      limits="$(jq -c --arg id "$id" '.[$id].limited_engines // {}' "$STATE")"
      [ "$limits" = "{}" ] || printf -- '- `%s`: `%s`\n' "$id" "$limits"
    done < <(jq -r '.tasks[].id' "$TASKS")
    printf '\n## Recent commits per task repo\n\n'
    while IFS= read -r id; do
      dir="$(tget "$id" dir)"; printf '### %s — `%s`\n' "$id" "$dir"
      if [ -d "$dir/.git" ] || ( cd "$dir" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ); then
        printf '```\n'; ( cd "$dir" && git log --oneline -5 2>/dev/null ); printf '```\n\n'
      else printf '_not a git repo_\n\n'; fi
    done < <(jq -r '.tasks[].id' "$TASKS")
	    printf '\n_Logs: `%s`  •  transcripts: `%s/<task>-<ts>.json`  •  audits: `%s/<task>-audit-<ts>.json`  •  summaries: `%s/<task>.md`_\n' "$LOGDIR/main.log" "$LOGDIR" "$LOGDIR" "$SUMMARYDIR"
  } > "$f"
  log "report written: $f ($reason)"; echo "$f"
}

# --- subcommands -------------------------------------------------------------
cmd_status(){
	  init_state
	  printf 'claude resume mode: %s\n' "$CLAUDE_RESUME_MODE"
	  printf 'usage reserve threshold: %s\n' "$USAGE_LIMIT_THRESHOLD"
	  printf '\n%-24s %-14s %-10s %-7s %-12s %-5s %-4s %s\n' TASK ENGINE-SPEC EFFORT ACTIVE STATUS RUNS ERR SUMMARY
  printf '%-24s %-14s %-10s %-7s %-12s %-5s %-4s %s\n' ------------------------ -------------- ---------- ------- ------------ ----- ---- -------
  local id
  while IFS= read -r id; do
    printf '%-24s %-14s %-10s %-7s %-12s %-5s %-4s %s\n' "$id" "$(task_engine_spec "$id")" "$(task_effort_spec "$id")" "$(task_active_engine "$id")" "$(sget "$id" status)" "$(sget "$id" runs)" "$(sget "$id" errors)" "$(sget "$id" summary)"
  done < <(jq -r '.tasks[].id' "$TASKS")
  loop_running && printf '\nloop: RUNNING (PID %s)\n\n' "$(loop_pid)" || printf '\nloop: not running\n\n'
}

cmd_prepare(){ [ -f "$TASKS_MD" ] || die "missing $TASKS_MD (copy tasks.md.example or create it)"; run_prepare || die "prepare failed"; if validate_tasks; then log "validate: OK"; echo "tasks.json OK"; else die "validate: tasks.json has hard errors (see above)"; fi; }
cmd_doctor(){ [ -f "$TASKS_MD" ] || die "missing $TASKS_MD (copy tasks.md.example or create it)"; run_prepare --dry-run; }
cmd_validate(){ maybe_prepare_tasks; if validate_tasks; then log "validate: OK"; echo "tasks.json OK"; else die "validate: tasks.json has hard errors (see above)"; fi; }
cmd_edit(){
  local ed="${EDITOR:-vi}" target="$TASKS"
  [ -f "$TASKS_MD" ] && target="$TASKS_MD"
  "$ed" "$target" || die "editor exited nonzero"
  if [ "$target" = "$TASKS_MD" ]; then cmd_prepare
  else jq -e . "$TASKS" >/dev/null 2>&1 || die "tasks.json is no longer valid JSON"; cmd_validate; fi
}

cmd_sessions(){
  init_state
  printf '\n%-24s %-14s %-7s %-12s %-46s %s\n' TASK ENGINE-SPEC ACTIVE STATUS SESSIONS DIR
  local id st dir sessions
  while IFS= read -r id; do
    st="$(sget "$id" status)"; dir="$(tget "$id" dir)"; sessions="$(jq -c --arg id "$id" '.[$id].sessions // {}' "$STATE")"
    printf '%-24s %-14s %-7s %-12s %-46s %s\n' "$id" "$(task_engine_spec "$id")" "$(task_active_engine "$id")" "$st" "${sessions:-{}}" "$dir"
  done < <(jq -r '.tasks[].id' "$TASKS")
  printf '\nResume any task interactively:  ./auto-loop.sh attach <task>\n\n'
}

cmd_attach(){
  init_state
  local id="${1:-}" dir sid engine bin ans
  [ -n "$id" ] || die "usage: ./auto-loop.sh attach <task-id>  (see: ./auto-loop.sh sessions)"
  jq -e --arg id "$id" '.tasks[]|select(.id==$id)' "$TASKS" >/dev/null 2>&1 || die "no such task: $id"
  dir="$(tget "$id" dir)"; engine="$(task_active_engine "$id")"; sid="$(session_get "$id" "$engine")"; bin="$(engine_bin "$engine")"
  [ -d "$dir" ] || die "task dir not found: $dir"
  require_engine "$engine"
  if loop_running; then
    log "WARNING: the loop is RUNNING (PID $(loop_pid)). Attaching now can fork this task's session."
    printf 'The loop is running. Stop it first for a clean handoff: ./auto-loop.sh stop\nAttach anyway? [y/N] '
    read -r ans; case "$ans" in y|Y) : ;; *) die "aborted";; esac
  fi
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    log "[$id] attaching interactively ($engine) to session $sid in $dir"
    if [ "$engine" = "claude" ]; then ( cd "$dir" && exec "$bin" --resume "$sid" )
    else ( cd "$dir" && exec "$bin" resume "$sid" ); fi
  else
    log "[$id] no session yet — starting a fresh interactive $engine session in $dir"
    ( cd "$dir" && exec "$bin" )
  fi
}

cmd_stop(){ if loop_running; then local p; p="$(loop_pid)"; log "stopping loop PID $p"; kill "$p" 2>/dev/null && sleep 1; kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null; rm -f "$LOCKFILE"; echo "stopped"; else echo "no running loop"; fi; }
cmd_report(){ init_state; write_report manual; }
cmd_ui(){ local port="${1:-$UI_PORT}"; command -v python3 >/dev/null || die "python3 not found (needed for the web UI)"; log "UI on http://127.0.0.1:$port (Ctrl-C to stop)"; exec python3 "$ROOT/ui-server.py" "$port"; }

main(){
  maybe_prepare_tasks
  init_state
  validate_tasks || die "tasks.json has hard errors — fix them or run ./auto-loop.sh validate (set REQUIRE_GIT=0 to allow non-git dirs)"
  acquire_lock
  [ "$PERM_FLAGS" = "--dangerously-skip-permissions" ] && log "NOTE: claude runs with --dangerously-skip-permissions; codex runs with --dangerously-bypass-approvals-and-sandbox. Workers act unattended inside each task dir."
  [ "$AUDIT" = "1" ] && log "AUDIT: on — an independent agent must confirm each TASK_COMPLETE" || log "AUDIT: OFF — completion is self-attested"
  log "=== auto-loop start === default_engine=$ENGINE tasks=$(jq -r '[.tasks[].id]|join(",")' "$TASKS")"
  while :; do
    local id st
    if ! id="$(next_task)"; then log "=== no active tasks left — stopping ==="; write_report "loop-idle" >/dev/null; cmd_status; break; fi
    st="$(sget "$id" status)"
    if [ "$st" = "review" ]; then do_review "$id"; sleep "$IDLE_SLEEP"; continue; fi
    if ! run_task "$id"; then sleep "$IDLE_SLEEP"; continue; fi
    if hard_limited; then handle_rate_limit "$id"; continue; fi
    apply_result "$id"
    if soft_limited; then handle_rate_limit "$id"; continue; fi
    sleep "$IDLE_SLEEP"
  done
}

case "${1:-run}" in
  run)      main;;
  prepare)  cmd_prepare;;
  doctor)   cmd_doctor;;
  status)   cmd_status;;
  validate) cmd_validate;;
  edit)     cmd_edit;;
  sessions) cmd_sessions;;
  attach)   shift; cmd_attach "${1:-}";;
  report)   cmd_report;;
  ui)       shift; cmd_ui "${1:-}";;
  stop)     cmd_stop;;
  *)        die "unknown arg: '$1' (use: run | prepare | doctor | status | validate | edit | sessions | attach <id> | report | ui | stop)";;
esac

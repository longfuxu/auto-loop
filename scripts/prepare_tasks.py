#!/usr/bin/env python3
"""Prepare auto-loop tasks.json from a human-editable tasks.md file.

A task may be written in full (explicit `goal` + `done`) or as a `brief`: a
one-line description of intent. With the LLM prepare step on (the default),
a brief is expanded into a full Codex-`/goal`-style contract — Objective,
Scope, Constraints, Stop-if and a Token budget in `goal`, plus a verifiable
Done-when checklist in `done`. `id` and `dir` always stay human-owned; with the
LLM off a brief still degrades to a runnable goal/done so nothing hard-fails.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ENGINE_VALUES = {"claude", "codex"}
FIELD_RE = re.compile(
    r"^(id|dir|brief|goal|done|engine|model|effort|fallback_engine|fallback_model|fallback_effort)\s*:\s*(.*)$",
    re.I,
)
# A model string is passed straight to the CLI's --model flag: keep it to a safe token.
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# Bump whenever the prepared-task semantics change (e.g. brief -> /goal expansion),
# so caches written by an older prepare are not reused with new meaning.
CACHE_VERSION = 2
# Effort tokens auto-loop.sh normalize_effort_for_engine accepts verbatim (space-normalized).
# A value in this set is kept as written; anything else is rewritten to a canonical token
# via normalize_effort so the runner never rejects it.
RUNNER_EFFORTS = {
    "claude": {"low", "medium", "high", "max", "extra", "extra high", "xhigh"},
    "codex": {"light", "low", "medium", "high", "extra", "extra high", "xhigh"},
}


def normalize_effort(engine: str, raw: str) -> str | None:
    """Mirror auto-loop.sh normalize_effort_for_engine, plus forgiving synonyms so a
    slightly-off human/LLM value still resolves to a valid effort. Return None only
    when nothing sensible can be inferred."""
    if not raw:
        return None
    effort = re.sub(r"[ _-]+", " ", str(raw).strip().lower()).strip()
    if not effort:
        return None
    # Map common synonyms onto the canonical tiers before per-engine resolution.
    low_words = {"low", "light", "minimal", "min", "lowest", "quick", "fast"}
    med_words = {"medium", "med", "moderate", "normal", "default", "standard", "mid"}
    high_words = {"high"}
    top_words = {"extra", "extra high", "xhigh", "very high", "highest", "ultra", "max", "maximum", "deep", "thorough"}
    if engine == "claude":
        if effort in low_words:
            return "low"
        if effort in med_words:
            return "medium"
        if effort in high_words:
            return "high"
        if effort in top_words:
            return "max" if effort in {"max", "maximum"} else "xhigh"
        return None
    if engine == "codex":
        if effort in low_words:
            return "low"
        if effort in med_words:
            return "medium"
        if effort in high_words:
            return "high"
        if effort in top_words:
            return "xhigh"
        return None
    return None


def coerce_engine(raw: str) -> str | None:
    """Best-effort map a human/LLM engine value onto claude|codex. Recognizes the
    exact names and common signals (model families, providers). Returns None only
    when there is no reasonable signal, so the caller falls back to the default."""
    if not raw:
        return None
    value = str(raw).strip().lower()
    if value in ENGINE_VALUES:
        return value
    if re.search(r"codex|gpt|openai|\bo[134]\b|o[134]-", value):
        return "codex"
    if re.search(r"claude|anthropic|sonnet|opus|haiku|fable", value):
        return "claude"
    return None


def slugify(value: str, fallback: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    slug = re.sub(r"-+", "-", slug)
    return slug or fallback


def clean_block(lines: list[str]) -> str:
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines).strip()


def normalize_task(task: dict, index: int) -> dict:
    out: dict[str, str] = {}
    raw_id = str(task.get("id") or task.get("_heading") or f"task-{index}")
    out["id"] = slugify(raw_id, f"task-{index}")

    for key in (
        "dir",
        "brief",
        "goal",
        "done",
        "engine",
        "model",
        "effort",
        "fallback_engine",
        "fallback_model",
        "fallback_effort",
    ):
        value = task.get(key)
        if value is None:
            continue
        value = str(value).strip()
        if not value:
            continue
        if key == "dir":
            value = os.path.expanduser(re.sub(r"^//Users/", "/Users/", value))
            if len(value) > 1:
                value = value.rstrip("/")
        if key in {"engine", "fallback_engine"}:
            # Keep the raw (lowercased) value; coerce/validate later in sanitize_tasks
            # so a bad engine is repaired rather than silently dropped.
            value = value.lower()
        out[key] = value
    return out


# Deterministic done-criteria used only as a fallback when the user gave a brief but
# no explicit done and the LLM /goal expansion is unavailable (off / no key / errored).
# It keeps the task runnable and non-empty; the LLM path replaces it with a real,
# per-task checklist. Kept generic on purpose — a brief has no verifiable specifics.
BRIEF_FALLBACK_DONE = (
    "Implement exactly what the brief describes and COMMIT it on a feature branch; "
    "the repo still builds and its available test/lint command passes; "
    "the brief's stated intent is objectively satisfied (name the concrete artifact "
    "or command that proves it)."
)


def fill_from_brief(tasks: list[dict]) -> list[dict]:
    """Make a brief-only task runnable without an LLM: when a task carries a `brief`
    but is missing `goal`/`done`, seed provisional values from the brief so the
    deterministic path still validates. The LLM /goal expansion, when enabled,
    overwrites these with a proper Objective/Scope/Constraints/Done-when spec."""
    out: list[dict] = []
    for task in tasks:
        item = dict(task)
        brief = (item.get("brief") or "").strip()
        if brief:
            if not (item.get("goal") or "").strip():
                item["goal"] = brief
            if not (item.get("done") or "").strip():
                item["done"] = BRIEF_FALLBACK_DONE
        out.append(item)
    return out


def parse_markdown(text: str) -> list[dict]:
    tasks: list[dict] = []
    current: dict | None = None
    block_key: str | None = None
    block_lines: list[str] = []

    def flush_block() -> None:
        nonlocal block_key, block_lines, current
        if current is not None and block_key is not None:
            current[block_key] = clean_block(block_lines)
        block_key = None
        block_lines = []

    def finish_task() -> None:
        nonlocal current
        flush_block()
        if current is not None:
            tasks.append(current)
        current = None

    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading and not line.startswith("###"):
            finish_task()
            title = heading.group(1).strip()
            current = {"_heading": title}
            block_key = None
            block_lines = []
            continue

        if current is None:
            continue

        subheading = re.match(r"^###\s+(brief|goal|done)\s*$", stripped, re.I)
        if subheading:
            flush_block()
            block_key = subheading.group(1).lower()
            block_lines = []
            continue

        field = FIELD_RE.match(stripped)
        if field:
            key = field.group(1).lower()
            value = field.group(2)
            flush_block()
            if key in {"brief", "goal", "done"}:
                block_key = key
                block_lines = [value] if value else []
            else:
                current[key] = value.strip()
            continue

        if block_key is not None:
            block_lines.append(line)

    finish_task()
    return [normalize_task(task, i + 1) for i, task in enumerate(tasks)]


def extract_json_object(text: str) -> dict:
    candidates: list[str] = []
    stripped = text.strip()
    if stripped:
        candidates.append(stripped)

    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            candidates.append(line)
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict) and isinstance(obj.get("result"), str):
            candidates.append(obj["result"].strip())
        if isinstance(obj, list):
            for item in obj:
                if isinstance(item, dict) and isinstance(item.get("result"), str):
                    candidates.append(item["result"].strip())

    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    if fenced:
        candidates.append(fenced.group(1))

    first = text.find("{")
    last = text.rfind("}")
    if first != -1 and last > first:
        candidates.append(text[first : last + 1])

    for candidate in candidates:
        try:
            obj = json.loads(candidate)
        except Exception:
            continue
        if isinstance(obj, dict):
            return obj
    raise ValueError("LLM output did not contain a JSON object")


def validate_payload(payload: dict) -> list[dict]:
    tasks = payload.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise ValueError("payload must contain a non-empty tasks array")

    seen: set[str] = set()
    normalized: list[dict] = []
    for i, task in enumerate(tasks, 1):
        if not isinstance(task, dict):
            raise ValueError(f"task #{i} must be an object")
        item = normalize_task(task, i)
        for key in ("id", "dir", "goal", "done"):
            if not item.get(key):
                raise ValueError(
                    f"task #{i} missing required field: {key} "
                    "(provide goal+done explicitly, or a `brief` for /goal auto-expansion)"
                )
        if item["id"] in seen:
            raise ValueError(f"duplicate task id: {item['id']}")
        seen.add(item["id"])
        normalized.append(item)
    return normalized


def guard_llm_tasks(tasks: list[dict], draft_tasks: list[dict]) -> list[dict]:
    """Resolve precedence between the LLM output and the human draft: keep the LLM's
    improved goal/done/engine/model/effort, but never let it invent an id or a
    directory. Where the LLM left a field blank, fall back to the human draft.
    Field *validity* (engine/model/effort) is enforced afterwards by sanitize_tasks."""
    if not draft_tasks or len(tasks) != len(draft_tasks):
        return tasks
    guarded: list[dict] = []
    for task, draft in zip(tasks, draft_tasks):
        item = dict(task)
        # id and dir stay human-controlled: never let the LLM rename a task or
        # point an unattended agent at a path the human did not specify.
        for key in ("id", "dir"):
            if draft.get(key):
                item[key] = draft[key]
            else:
                item.pop(key, None)
        # brief + engine/model/effort (+fallbacks): keep the LLM's value, else the
        # human draft's. brief is provenance only (the runner reads goal/done);
        # preserving it keeps the source description visible in tasks.json even when
        # the LLM omits it. (goal/done are already validated as non-empty before this
        # runs — a partial LLM result is rejected earlier and falls back to the
        # brief-seeded deterministic draft.)
        for key in ("brief", "engine", "model", "effort", "fallback_engine", "fallback_model", "fallback_effort"):
            if not item.get(key):
                if draft.get(key):
                    item[key] = draft[key]
                else:
                    item.pop(key, None)
        guarded.append(item)
    return guarded


def sanitize_tasks(tasks: list[dict], warn: bool = True) -> list[dict]:
    """Final safety net applied to every task (deterministic or LLM). Repairs a bad
    or ambiguous engine into a valid one, and drops any model/effort that still
    cannot be made valid so the task stays runnable (the runner then uses its
    default) instead of hard-failing `auto-loop.sh validate`."""
    def note(msg: str) -> None:
        if warn:
            print(f"prepare: {msg}", file=sys.stderr)

    out: list[dict] = []
    for task in tasks:
        item = dict(task)
        tid = item.get("id", "?")
        # engine / fallback_engine: coerce to a working engine, else use the default.
        for key in ("engine", "fallback_engine"):
            raw = item.get(key)
            if not raw:
                item.pop(key, None)
                continue
            coerced = coerce_engine(raw)
            if coerced is None:
                note(f"WARN task '{tid}' {key} '{raw}' not recognized; using the default engine")
                item.pop(key, None)
            else:
                if coerced != str(raw).strip().lower():
                    note(f"WARN task '{tid}' {key} '{raw}' -> '{coerced}'")
                item[key] = coerced
        # Resolve engines (default claude) for effort validation.
        engine = item.get("engine") or "claude"
        fb_engine = item.get("fallback_engine") or engine
        # model / fallback_model: must be a plain CLI token, else drop to default.
        for key in ("model", "fallback_model"):
            raw = item.get(key)
            if not raw:
                item.pop(key, None)
            elif not MODEL_RE.match(raw):
                note(f"WARN task '{tid}' {key} '{raw}' is not a valid model token; dropped (CLI default will be used)")
                item.pop(key, None)
        # effort / fallback_effort: keep values the runner already accepts; rewrite
        # creative synonyms to a canonical token; drop only if nothing maps.
        for key, eng in (("effort", engine), ("fallback_effort", fb_engine)):
            raw = item.get(key)
            if not raw:
                item.pop(key, None)
                continue
            spaced = re.sub(r"[ _-]+", " ", str(raw).strip().lower()).strip()
            if spaced in RUNNER_EFFORTS.get(eng, set()):
                continue  # already valid for the runner — keep as written
            canon = normalize_effort(eng, raw)
            if canon is None:
                note(f"WARN task '{tid}' {key} '{raw}' invalid for engine '{eng}'; dropped (default effort will be used)")
                item.pop(key, None)
            else:
                note(f"WARN task '{tid}' {key} '{raw}' -> '{canon}' for engine '{eng}'")
                item[key] = canon
        out.append(item)
    return out


def claude_result_text(stdout: str) -> str:
    texts: list[str] = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict) and isinstance(obj.get("result"), str):
            texts.append(obj["result"])
        elif isinstance(obj, list):
            for item in obj:
                if isinstance(item, dict) and isinstance(item.get("result"), str):
                    texts.append(item["result"])
    return "\n".join(texts).strip() or stdout


def llm_optimize(markdown: str, draft_tasks: list[dict], args: argparse.Namespace) -> dict:
    bin_name = args.llm_bin or os.environ.get("PREPARE_LLM_BIN") or os.environ.get("CLAUDE_BIN") or "claude"
    bin_path = shutil.which(bin_name)
    if not bin_path:
        raise RuntimeError(f"LLM binary not found: {bin_name}")

    prompt = f"""You convert a human-written auto-loop task Markdown file into canonical tasks.json.

Return ONLY a JSON object with this exact shape:
{{"tasks":[{{"id":"slug","dir":"/absolute/path","brief":"optional","goal":"...","done":"...","engine":"claude|codex","model":"optional","effort":"optional","fallback_engine":"claude|codex","fallback_model":"optional","fallback_effort":"optional"}}]}}

Rules:
- Preserve explicit task ids when they are valid slugs. If an id is invalid, minimally slugify it.
- Never invent, change, or add a "dir": copy it verbatim from the deterministic parser draft (the human owns the working directory).
- Do not add or remove tasks.
- Do not invent secrets, tokens, credentials, or private paths not present in the input.
- Normalize accidental //Users/... paths to /Users/...
- Improve the user's task wording without changing intent.
- Integrate doctor-style cleanup directly: make each goal concrete and make each done criterion objectively auditable.
- Prefer named output artifacts and concrete verification commands when implied by the task.
- You MAY set or refine engine/model/effort (and their fallback_* counterparts) to fit the task, but keep the human's explicit choice unless there is a clear reason to change it. Use ONLY engine "claude" or "codex"; effort for claude is one of low|medium|high|extra|max, effort for codex is one of light|medium|high|"extra high".
- REPAIR bad or ambiguous values into a valid, working configuration — do not just drop them. If the human wrote an engine you do not recognize, infer the right one: e.g. engine "gpt"/"gpt-5.5"/"openai" -> engine "codex"; engine "claude-opus"/"anthropic"/"sonnet" -> engine "claude". Do NOT invent a model: keep a model ONLY if the human explicitly named a valid one, and NEVER synthesize a "-codex"-suffixed name (e.g. "gpt-5-codex"/"gpt-5.5-codex") — those are rejected on ChatGPT-plan Codex accounts. When unsure, leave model blank so the CLI uses the account default. Map effort synonyms to the nearest valid tier (e.g. "very high"/"maximum" -> claude "max" or codex "extra high"; "minimal" -> "low"). Only omit engine/model/effort when you truly have no basis to set them.

/goal EXPANSION (the important part):
- A task may give only a short "brief" (a one-or-two-line description of intent) instead of a fully written goal/done. When it does, EXPAND that brief into a complete, self-contained goal contract using the Codex /goal methodology. This is the whole point — the human writes one line, you write the rigorous spec.
- Put the expanded spec in "goal" as structured Markdown with these exact section headers, filling every one:
    **Objective** — one sentence, one concrete deliverable. Forbidden vague verbs: improve, all, thoroughly, better, optimize, clean up, refactor (alone). Use add/remove/replace/migrate/implement/produce.
    **Scope** — "In scope:" and "Out of scope:" lines naming files/dirs/systems (relative to the task dir). Never say "all relevant files"; name them or describe them concretely.
    **Constraints** — hard, mechanically-checkable rules specific to THIS task's domain (e.g. "No new top-level dependencies", "Public API of module X unchanged").
    **Stop if** — machine-recognizable stop conditions (e.g. "More than 3 files outside Scope need edits", "A Constraints rule would have to be violated"). No conditions that need human judgment.
    **Token budget** — "Use a token budget of <N> tokens." Default 80000; lower for surgical fixes, higher for migrations/large refactors.
- Put the "Done when" checklist in "done" as GitHub-style `- [ ]` items, each objectively verifiable with a file path or a shell command (e.g. "`pytest tests/x.py -q` exits 0", "`grep -R 'TODO' src/` returns nothing"). Never "tests pass" without naming the test; never a proxy signal (lint score, test count) instead of the actual deliverable.
- Base Scope/Constraints/Done strictly on the brief and the task's dir. Do NOT fabricate file paths, commands, or facts you cannot reasonably infer; when a path is unknown, describe the target instead of inventing one.
- Do NOT restate the loop's own git/safety rules (work on a feature branch, never touch main, don't print secrets, an auditor verifies you). Those are enforced separately — keep Constraints focused on the task's domain.
- If the human already wrote an explicit goal AND done (not just a brief), keep their intent and only lightly polish/structure them — do not regenerate from scratch.
- Output JSON only. No markdown fences. No commentary.

Human Markdown:
{markdown}

Deterministic parser draft (brief-only tasks show "goal" echoing the brief and a placeholder "done" — REPLACE both with a proper /goal expansion):
{json.dumps({"tasks": draft_tasks}, ensure_ascii=False, indent=2)}
"""
    cmd = [bin_path, "-p", prompt]
    model = args.model or os.environ.get("PREPARE_MODEL") or os.environ.get("MODEL")
    if model:
        cmd.extend(["--model", model])

    result = subprocess.run(cmd, cwd=args.root, text=True, capture_output=True, timeout=args.timeout)
    if result.returncode != 0:
        err = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"LLM prepare failed with exit {result.returncode}: {err[:1000]}")
    text = claude_result_text(result.stdout)
    return extract_json_object(text)


def atomic_write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def cache_file_for(json_path: Path) -> Path:
    return json_path.parent / ".tasks.prepare-cache.json"


def load_prepare_cache(path: Path, source_hash: str) -> list[dict] | None:
    """Return the cached LLM-prepared tasks iff the source markdown is unchanged."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict) or data.get("version") != CACHE_VERSION:
        return None
    if data.get("source_sha256") != source_hash:
        return None
    tasks = data.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        return None
    try:
        return validate_payload({"tasks": tasks})
    except Exception:
        return None


def save_prepare_cache(path: Path, source_hash: str, tasks: list[dict]) -> None:
    payload = {"version": CACHE_VERSION, "source_sha256": source_hash, "tasks": tasks}
    try:
        atomic_write_json(path, payload)
    except Exception as exc:  # a cache write failure must never fail prepare
        print(f"prepare: WARN could not write prepare cache: {exc}", file=sys.stderr)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", default=os.getcwd())
    p.add_argument("--markdown", default=None)
    p.add_argument("--json", default=None)
    p.add_argument("--llm", choices=("on", "auto", "required", "off"), default=os.environ.get("TASK_PREPARE_LLM", "on"))
    p.add_argument("--llm-bin", default=None)
    p.add_argument("--model", default=None)
    p.add_argument("--timeout", type=int, default=int(os.environ.get("TASK_PREPARE_TIMEOUT", "180")))
    p.add_argument("--no-cache", action="store_true", help="ignore and refresh the LLM prepare cache")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    # "on" is the friendly default: LLM-structure the tasks, cache the result so a
    # live session never re-plans the same input. "off" is deterministic-only.
    mode = args.llm.lower()
    llm_enabled = mode != "off"
    llm_required = mode == "required"

    root = Path(args.root).resolve()
    markdown_path = Path(args.markdown).resolve() if args.markdown else root / "tasks.md"
    json_path = Path(args.json).resolve() if args.json else root / "tasks.json"

    if not markdown_path.exists():
        print(f"prepare: missing {markdown_path}", file=sys.stderr)
        return 1

    markdown = markdown_path.read_text(encoding="utf-8")
    # Seed provisional goal/done from any `brief` so a brief-only task stays runnable
    # even with the LLM off; the LLM /goal expansion (default on) overwrites these.
    draft_tasks = fill_from_brief(parse_markdown(markdown))
    if not draft_tasks and not llm_enabled:
        print("prepare: no tasks parsed from Markdown", file=sys.stderr)
        return 1

    source_hash = hashlib.sha256(markdown.encode("utf-8")).hexdigest()
    cache_path = cache_file_for(json_path)

    used_llm = False
    reused_cache = False
    payload: dict = {"tasks": draft_tasks}
    if llm_enabled:
        cached = None
        if draft_tasks and not args.no_cache:
            cached = load_prepare_cache(cache_path, source_hash)
        if cached is not None:
            # Written once, not rewritten again while the source is unchanged.
            payload = {"tasks": cached}
            used_llm = True
            reused_cache = True
        else:
            try:
                payload = llm_optimize(markdown, draft_tasks, args)
                used_llm = True
            except Exception as exc:
                if llm_required or not draft_tasks:
                    print(f"prepare: {exc}", file=sys.stderr)
                    return 1
                print(f"prepare: WARN LLM optimization skipped: {exc}", file=sys.stderr)

    try:
        tasks = validate_payload(payload)
        if used_llm and not reused_cache:
            if len(tasks) != len(draft_tasks):
                raise ValueError(
                    f"LLM changed task count ({len(draft_tasks)} -> {len(tasks)}); "
                    "refusing to trust LLM-supplied ids/dirs"
                )
            tasks = validate_payload({"tasks": guard_llm_tasks(tasks, draft_tasks)})
    except Exception as exc:
        if used_llm and draft_tasks:
            print(f"prepare: WARN LLM output rejected: {exc}; using deterministic draft", file=sys.stderr)
            try:
                tasks = validate_payload({"tasks": draft_tasks})
            except Exception as draft_exc:
                print(f"prepare: {draft_exc}", file=sys.stderr)
                return 1
            used_llm = False
            reused_cache = False
        else:
            print(f"prepare: {exc}", file=sys.stderr)
            return 1

    # Repair/validate engine/model/effort on every path so the written tasks.json
    # always survives `auto-loop.sh validate` and the loop can actually run.
    tasks = sanitize_tasks(tasks)

    final_payload = {"tasks": tasks}
    if args.dry_run:
        print(json.dumps(final_payload, ensure_ascii=False, indent=2))
    else:
        atomic_write_json(json_path, final_payload)
        # Persist the plan only when a fresh LLM pass produced it, so re-running
        # prepare on the same tasks.md reuses it instead of spending more tokens.
        if used_llm and not reused_cache:
            save_prepare_cache(cache_path, source_hash, tasks)
        if used_llm:
            mode_label = "LLM-cached" if reused_cache else "LLM-optimized"
        else:
            mode_label = "deterministic"
        print(f"prepare: wrote {json_path} from {markdown_path} ({mode_label})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

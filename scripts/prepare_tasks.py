#!/usr/bin/env python3
"""Prepare auto-loop tasks.json from a human-editable tasks.md file."""

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
    r"^(id|dir|goal|done|engine|model|effort|fallback_engine|fallback_model|fallback_effort)\s*:\s*(.*)$",
    re.I,
)
# A model string is passed straight to the CLI's --model flag: keep it to a safe token.
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
CACHE_VERSION = 1


def normalize_effort(engine: str, raw: str) -> str | None:
    """Mirror auto-loop.sh normalize_effort_for_engine; return None if invalid."""
    if not raw:
        return None
    effort = re.sub(r"[ _-]+", " ", str(raw).strip().lower()).strip()
    if not effort:
        return None
    if engine == "claude":
        if effort in {"low", "medium", "high", "max"}:
            return effort
        if effort in {"extra", "extra high", "xhigh"}:
            return "xhigh"
        return None
    if engine == "codex":
        if effort in {"light", "low"}:
            return "low"
        if effort in {"medium", "high"}:
            return effort
        if effort in {"extra", "extra high", "xhigh"}:
            return "xhigh"
        return None
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
            value = re.sub(r"^//Users/", "/Users/", value)
        if key in {"engine", "fallback_engine"}:
            value = value.lower()
            if value not in ENGINE_VALUES:
                continue
        out[key] = value
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

        subheading = re.match(r"^###\s+(goal|done)\s*$", stripped, re.I)
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
            if key in {"goal", "done"}:
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
                raise ValueError(f"task #{i} missing required field: {key}")
        if item["id"] in seen:
            raise ValueError(f"duplicate task id: {item['id']}")
        seen.add(item["id"])
        normalized.append(item)
    return normalized


def guard_llm_tasks(tasks: list[dict], draft_tasks: list[dict]) -> list[dict]:
    """Keep the LLM's improved goal/done/engine/model/effort, but never let it
    invent an id or a directory, and reject any engine/model/effort it cannot
    make valid (falling back to the human draft, then omitting)."""
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
        # engine / fallback_engine: normalize_task already dropped anything that
        # is not claude|codex. Keep the LLM's valid choice, else the human draft.
        for key in ("engine", "fallback_engine"):
            if not item.get(key):
                if draft.get(key):
                    item[key] = draft[key]
                else:
                    item.pop(key, None)
        # model / fallback_model: accept a token-safe model, else the human draft.
        for key in ("model", "fallback_model"):
            val = item.get(key)
            if val and not MODEL_RE.match(val):
                val = ""
            if not val:
                if draft.get(key):
                    item[key] = draft[key]
                else:
                    item.pop(key, None)
        # effort / fallback_effort: keep only values that normalize for the
        # resolved engine so the runner never fails validate on a bad effort.
        engine = item.get("engine") or draft.get("engine") or "claude"
        fb_engine = item.get("fallback_engine") or draft.get("fallback_engine") or engine
        for key, eng in (("effort", engine), ("fallback_effort", fb_engine)):
            val = item.get(key)
            if val and normalize_effort(eng, val) is not None:
                continue
            dval = draft.get(key)
            if dval and normalize_effort(eng, dval) is not None:
                item[key] = dval
            else:
                item.pop(key, None)
        guarded.append(item)
    return guarded


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
{{"tasks":[{{"id":"slug","dir":"/absolute/path","goal":"...","done":"...","engine":"claude|codex","model":"optional","effort":"optional","fallback_engine":"claude|codex","fallback_model":"optional","fallback_effort":"optional"}}]}}

Rules:
- Preserve explicit task ids when they are valid slugs. If an id is invalid, minimally slugify it.
- Never invent, change, or add a "dir": copy it verbatim from the deterministic parser draft (the human owns the working directory).
- Do not add or remove tasks.
- Do not invent secrets, tokens, credentials, or private paths not present in the input.
- Normalize accidental //Users/... paths to /Users/...
- Improve the user's task wording without changing intent.
- Integrate doctor-style cleanup directly: make each goal concrete and make each done criterion objectively auditable.
- Prefer named output artifacts and concrete verification commands when implied by the task.
- You MAY set or refine engine/model/effort (and their fallback_* counterparts) to fit the task, but keep the human's explicit choice unless there is a clear reason to change it. Use ONLY engine "claude" or "codex"; effort for claude is one of low|medium|high|extra|max, effort for codex is one of light|medium|high|"extra high". Omit any of these fields you have no basis to set.
- Output JSON only. No markdown. No commentary.

Human Markdown:
{markdown}

Deterministic parser draft:
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
    draft_tasks = parse_markdown(markdown)
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
            tasks = validate_payload({"tasks": draft_tasks})
            used_llm = False
            reused_cache = False
        else:
            print(f"prepare: {exc}", file=sys.stderr)
            return 1

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

# auto-loop 中文说明

[English](README.md) · **简体中文**

> 完整的英文说明（含设计动机、安全、公开发布）见 [`README.md`](README.md)。这里是快速中文向导。

这个目录提供一个很小的 bash 自动循环：按 `tasks.json` 中的顺序，把任务交给 agent CLI（**Claude Code 或 OpenAI Codex**）以非交互模式执行；撞到额度限制就睡到窗口恢复后继续同一个 task session。

**本轮新增的三件事：**

- **多引擎**：每个 task 可写 `"engine": "claude"` 或 `"codex"`（不写就用默认）。Claude 读 `resetsAt` 精确睡到窗口恢复；Codex 没有精确 reset，用 `CODEX_COOLDOWN`（默认 1 小时）退避。
- **独立审计**：worker 说 `TASK_COMPLETE` 后不直接算完成，而是转入 `review`，由**另一个全新的审计 agent**（不共享 session）去跑 `done` 里写的验证命令、看 diff，只有 `AUDIT_PASS` 才标记 complete；失败则打回 `in_progress` 让下轮修。用 `AUDIT=0` 关闭。
- **Web UI（给非程序员）**：`./auto-loop.sh ui` 起一个只绑 `127.0.0.1` 的本地网页，用来加载/编辑任务、看状态、看报告、启停 loop。核心仍然是 CLI。

## 什么时候适合用

适合：

- 任务目标已经明确，且能拆成一次次可提交的代码增量。
- 每个 task 的 `dir` 是一个真实 git repo 或 worktree。
- 完成条件能用命令或文件状态验证。
- 可以接受 Claude 在无人值守状态下创建 feature branch、修改代码、运行测试、commit。

不适合：

- 需要临场判断、发消息、做公开发布决策的任务。
- `dir` 不是 git repo 的任务，因为 worker prompt 要求 commit。
- 需要人工输入验证码、OAuth 登录、2FA 或未配置的 token。
- 把 API token、Vercel token、SSH key 等秘密直接写进 `tasks.json` 的任务。

## task 写法

推荐只编辑 `tasks.md`，不要手写 `tasks.json`。`tasks.json` 是机器生成的规范文件，runner 仍然读取它；这样可以避免 JSON 里最容易出错的原始换行、引号转义、尾逗号。

第一次使用：

```bash
cp tasks.md.example tasks.md
$EDITOR tasks.md
./auto-loop.sh prepare
./auto-loop.sh validate
```

`tasks.md` 写法：

```md
## stable-short-id

dir: /absolute/path/to/repo
engine: claude

goal:
这里可以写多行自然语言，不需要转义引号或换行。

done:
写清楚可验证条件，例如 `npm test` passes，或者
`test -s STRATEGY.md`。
```

`./auto-loop.sh prepare` 会把 Markdown 编译成 `tasks.json`。它先做确定性解析，再在可用时调用 LLM 优化 task 描述，把 `done` 改得更可审计。最终生成的 JSON 仍然会走本地 validator。

兼容的 `tasks.json` 顶层字段仍然是：

```json
{
  "tasks": [
    {
      "id": "stable-short-id",
      "dir": "/absolute/path/to/repo",
      "goal": "One concrete objective.",
      "done": "Concrete completion criteria with commands and expected artifacts."
    }
  ]
}
```

建议：

- `id` 用短 slug，例如 `add-user-auth`（必须匹配 `^[a-z0-9-]+$`）。
- `dir` 必须是绝对路径，且是一个 git repo（worker 要 commit）。
- `goal` 说明最终要完成什么。
- `done` 写可验证条件，例如 `npm run build passes`、`uv run pytest tests/test_x.py -q passes`、`HANDOFF.md updated`。
- `model`（可选）：给这个 task 指定模型，例如 `claude-opus-4-8` / `claude-sonnet-5`。不写就用全局 `MODEL` 环境变量，再没有就用账号默认模型。
- credential 用环境变量，例如 `VERCEL_TOKEN`，不要写入 JSON、日志或 handoff。

## 常用命令

```bash
cd /path/to/auto-loop

# 从 tasks.md 生成 tasks.json（可用时会调用 LLM 做 doctor/优化）
./auto-loop.sh prepare

# 预览 prepare 结果，但不写入 tasks.json
./auto-loop.sh doctor

# 校验 tasks.json（不启动任何任务；检查 id/dir/goal/done、是否 git repo、done 是否可验证）
# 如果 tasks.md 比 tasks.json 新，validate 会先自动 prepare
./auto-loop.sh validate

# 用 $EDITOR 编辑 tasks.md（若存在），退出后自动 prepare + 校验
./auto-loop.sh edit

# 查看当前状态（含 loop 是否在运行）
./auto-loop.sh status

# 列出每个 task 的 session_id / dir（用于交互接管）
./auto-loop.sh sessions

# 交互式接管某个 task：打开正常的 Claude Code TUI，续上无人值守时的那个 session
./auto-loop.sh attach <task-id>

# 生成一份状态报告（也会在每个 5 小时窗口结束、loop 停止时自动生成）
./auto-loop.sh report        # 输出写到 reports/report-<ts>.md

# 前台运行
./auto-loop.sh run

# 后台无人值守运行
nohup ./auto-loop.sh >> logs/nohup.log 2>&1 &

# 看主日志
tail -f logs/main.log

# 停止 loop（优先用 stop，它读锁文件里的 PID）
./auto-loop.sh stop
```

## 交互接管（不是 headless）

loop 用 `claude -p ... --resume <session_id>` 无人值守地推进每个 task，并把 `session_id` 记在 `state.json` 里。你随时可以跳进同一个会话手动接管：

```bash
./auto-loop.sh stop            # 先停 loop，避免和它抢同一个 session
./auto-loop.sh attach <task>   # 打开交互式 Claude Code TUI，续上刚才停下的地方
# …人工检查 / 对话 / 纠偏，然后退出 TUI…
nohup ./auto-loop.sh >> logs/nohup.log 2>&1 &   # 让 loop 继续
```

`attach` 打开的就是你现在用的那种交互式 CLI；它续的是 loop 用的同一个 session，所以“从上次离开的地方接着聊”。注意：loop 在跑时不要同时 attach 同一个 task，否则会把会话分叉——`attach` 会检测到锁并要求你确认。

## 报告

- 每个 5 小时额度窗口结束（loop 进入 sleep 前）、loop 全部跑完、或手动 `./auto-loop.sh report` 时，会在 `reports/` 下写一份 markdown 报告。
- 内容是确定性摘要（不额外消耗 Claude 额度）：每个 task 的 status/runs/errors/最后 sentinel，以及各 task repo 最近 5 条 commit。

## 状态文件

`state.json` 是运行时文件。每个 task 会记录：

- `status`: `pending` / `in_progress` / `complete` / `blocked` / `error`
- `session_id`: Claude Code session id，用于后续 `--resume`
- `runs`: 已跑几轮
- `errors`: 连续非额度错误次数
- `summary`: worker 最后一行 sentinel
- `last`: 最近更新时间

如果 task 写错导致状态污染，确认没有 loop 在跑后，可以删除或重置 `state.json`，下次启动会重新初始化。

## 安全约束

脚本的 worker prompt 要求：

- 只编辑 task 的 `dir` 内部。
- 可以读取 task 明确引用的外部 plan/context 文件。
- 必须在 feature branch 上提交。
- 不碰 `main` / `master`，不 force-push，不 merge。
- 不写出或打印 secret value。
- 每轮只做一个连贯增量，最后输出一个 sentinel：
  - `TASK_COMPLETE`
  - `TASK_BLOCKED: <reason>`
  - `TASK_PROGRESS: <summary>`

默认权限是 `--dangerously-skip-permissions`，用于无人值守执行。只有在 task 足够明确、目标 repo 是 git repo、且没有明文 secret 时才启动。

其它安全约束：

- **启动前校验**：`run` 会先跑 `validate_tasks`，有硬错误（缺字段、dir 不存在、不是 git repo、id 重复）直接拒绝启动。想允许非 git 目录可设 `REQUIRE_GIT=0`。
- **锁文件**：`run` 会写 `.auto-loop.lock`（当前 PID）。第二个实例会被拒绝，避免两个 worker 抢同一个 task；PID 已死的陈旧锁会被忽略。
- **可调环境变量**：`MODEL`、`PERM_FLAGS`、`IDLE_SLEEP`、`RESET_BUFFER`、`MAX_ERRORS`、`CLAUDE_BIN`、`REQUIRE_GIT`、`EDITOR`。
- `logs/`、`reports/`、`state.json`、`.auto-loop.lock` 都在 `.gitignore` 里，不会被提交。每轮完整 JSON transcript 存在 `logs/<task>-<ts>.json`（可能包含 worker 打印的内容，注意不要让 worker 打印 secret）。

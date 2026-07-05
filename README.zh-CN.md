# auto-loop 中文说明

[English](README.md) · **简体中文**

一个小而本地的任务队列：某个 coding-agent CLI 撞到 usage limit 时，让工作继续往前推，而不是卡在原地。

给它一份 Markdown backlog。`auto-loop` 用 Claude Code 或 Codex CLI 一次跑一个任务，为每个 engine 分别保存 session，在 active engine 被限流时切换到配置好的 fallback engine，并且要求一个全新的 auditor 验证过后才能把任务标记为完成。

```
tasks.md
   |
   v
Claude Code ---- usage limit ----> Codex
   |                                  |
   +---------- local repo state ------+
                      |
                      v
              independent audit
                      |
                pass / retry
```

## 为什么做这个

我想在离开电脑前起好几个 coding task，回来看到的是实际进展——而不是队列在第一个 usage-limit 窗口就卡死了。

三个设计选择比较关键：

- **限流就切换，而不是卡死。** Claude 被限流时任务可以换到 Codex 继续，反过来也一样，不用干等整个 reset 窗口。
- **engine 之间的上下文互不干扰。** Claude 和 Codex 分别维护自己的 per-task session 和 resume 状态，resume id 永远不会跨 engine 串用。
- **worker 不能给自己判分。** worker 输出 `TASK_COMPLETE` 只会把任务推进到 `review`；必须有一个全新的 auditor 检查 repo 并验证 `done` 标准，才算真正完成。

全部在本地跑：一个可读的 Bash runner、一个标准库 Python UI、一个 Markdown-to-JSON 编译器。适合仍然想保留本地 Claude Code / Codex CLI 控制权、不想把整个 backlog 交给云服务的人。

## 快速开始

依赖：`bash`、`jq`、`git`、`python3`，以及至少一个已登录的 CLI：

- `claude`
- `codex`

```bash
git clone https://github.com/longfuxu/auto-loop.git
cd auto-loop
cp tasks.md.example tasks.md
$EDITOR tasks.md
./auto-loop.sh prepare            # 默认由 AI 结构化任务；加 TASK_PREPARE_LLM=off 走确定性/离线
./auto-loop.sh validate
./auto-loop.sh run
```

接下来是详细的任务格式、引擎切换、额度保留、独立审计和本地 UI 说明。

<p align="center">
  <img src="docs/ui-status.png" alt="auto-loop web UI - task status" width="820">
  <br>
  <em>UI 适合非命令行场景；真正的执行状态仍然写在本地 state、logs、reports、summaries 里。</em>
</p>

<p align="center">
  <img src="docs/cli-run.jpg" alt="auto-loop terminal run showing quota-aware sleep and audit flow" width="820">
  <br>
  <em>命令行模式适合睡前或远程运行：能看到 prepare、usage limit、sleep、audit、report 的完整链路。</em>
</p>

## tasks.md 写法

推荐只编辑 `tasks.md`。`tasks.json` 是生成文件，runner 读取它。

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

Effort examples:
- Claude: low, medium, high, extra, max
- Codex: light, medium, high, extra high

Leave engine/model/effort blank to use the global default/account default.
Use fallback_engine/fallback_model/fallback_effort when you want continuation after a usage limit.
-->
engine: claude
model:
effort:
fallback_engine: codex
fallback_model:
fallback_effort:

goal:
实现 docs/settings-plan.md 里描述的 settings panel。

done:
在 feature branch 上创建并提交实现。`npm test` 和 `npm run build` 通过。
更新 HANDOFF.md，写清楚改了哪些文件和下次第一条命令。
```

字段说明：

- `id`：默认来自 `##` 标题，也可以显式写 `id:`；必须匹配 `^[a-z0-9-]+$`。
- `dir`：绝对路径，指向一个 git repo 或 worktree。
- `goal`：任务目标。
- `done`：可验证完成标准，最好写具体命令和文件。
- `engine`：可选，`claude` 或 `codex`；不填用 `$ENGINE`，再不填默认 `claude`。
- `model`：可选，传给 primary engine；不填用 `$MODEL`，再不填用账号默认。
- `effort`：可选，传给 primary engine；Claude 可写 `low`、`medium`、`high`、`extra`、`max`；Codex 可写 `light`、`medium`、`high`、`extra high`。
- `fallback_engine`：可选，active engine hit limit 后切换到这里。
- `fallback_model`：可选，传给 fallback engine；不填用 `$MODEL`，再不填用账号默认。
- `fallback_effort`：可选，传给 fallback engine；不填时先继承同 task 的 `effort`，再用 `$EFFORT`，再用 CLI 默认。

编译和校验：

```bash
./auto-loop.sh prepare
./auto-loop.sh validate
```

`prepare` 先用确定性 parser 解析 Markdown，然后默认（`TASK_PREPARE_LLM=on`）让所配置的 CLI 把每个 task 改写成更结构化、更可审计的形式：润色 `goal` / `done`，并可以按任务需要设置或调整 `engine`、`model`、`effort`（以及对应的 `fallback_*`）。**task 数量、id、dir** 始终以确定性 parser 为准——LLM 不能新增/删除 task、改名、编造路径。

非法或含糊的 `engine`/`model`/`effort` 会被**修复而不是直接拒绝**，让任务仍可运行：LLM 会映射到合法配置（如 `engine: gpt-5` → `engine: codex` 且 `model: gpt-5-codex`；`effort: very high` → 该引擎的最高档）。每条路径（含 `off`）都有确定性兜底：能识别的 engine 会被归一（`gpt`/`openai` → codex，`anthropic`/`opus`/`sonnet` → claude），effort 同义词改写成规范档位，实在无法校验的就丢弃，让 runner 用默认值继续，而不是启动失败。

AI 生成的方案会缓存在 `.tasks.prepare-cache.json`，以 `tasks.md` 的哈希为键。只要不修改 `tasks.md`，再次 `prepare`（或重启 loop）都会**复用该方案而不再调用 LLM**——即每次编辑只结构化一次，不会每轮重写，省 token。修改 `tasks.md` 即可重新规划；加 `--no-cache` 可强制刷新；用 `PREPARE_MODEL` 指定模型。想完全关闭优化：

```bash
TASK_PREPARE_LLM=off ./auto-loop.sh prepare
```

## 引擎切换

当 task 撞到 usage limit：

- Claude：能读到 `resetsAt` 时精确记录 reset 时间。
- Codex：没有精确 reset epoch，所以用 `CODEX_COOLDOWN`。
- 如果配置了可用的 `fallback_engine`，不会立刻睡觉，而是切到 fallback engine 继续。
- fallback run 会看到本地 task summary，并被要求先检查 repo state 再继续。

示例：

```md
engine: claude
model: claude-opus-4-8
effort: extra
fallback_engine: codex
fallback_model: gpt-5-codex
fallback_effort: high
```

含义：优先用 Claude 和指定模型/effort；Claude hit limit 后，Codex 接着做。

## 额度保留

默认软阈值是 90%：

```bash
USAGE_LIMIT_THRESHOLD=0.90 ./auto-loop.sh run
```

当 CLI 暴露 utilization 且达到这个阈值时，runner 会先保存当前这次 run 的有效结果，然后把该 engine 记为 limited。配置了 fallback engine 就切过去继续；没有 fallback 就睡到 reset window。这样不会把整个 usage window 吃满，给你白天手动用 Claude/Codex 留出空间。

## 摘要恢复 / token management

```bash
CLAUDE_RESUME_MODE=summary ./auto-loop.sh run
```

模式：

- `full`：默认，继续使用保存的 session id。
- `summary`：正常 resume；Claude hit limit 后，下一次 Claude run 用 `summaries/<task>.md` 开 fresh session。
- `fresh`：只要有 summary，就直接用 summary 开 fresh session。

summary 包含 goal、done、最后一次结果、active engine、各 engine session id、最近 commit 等轻量上下文。

## 独立审计

worker 输出：

```text
TASK_COMPLETE
```

并不会直接 complete。task 会进入 `review`，由另一个独立 auditor 检查：

- git 状态、最近提交和 diff；
- `done` 里写的验证命令；
- 实际文件/产物是否存在。

auditor 只能输出：

- `AUDIT_PASS`
- `AUDIT_FAIL: <reason>`

只有 `AUDIT_PASS` 会把 task 标记为 complete。`AUDIT=0` 可以关闭，但这意味着接受 worker 自证完成。

## 常用命令

```bash
./auto-loop.sh run          # 前台运行
./auto-loop.sh prepare      # tasks.md -> tasks.json
./auto-loop.sh doctor       # 预览生成的 JSON，不写文件
./auto-loop.sh validate     # 校验任务；必要时先 prepare
./auto-loop.sh edit         # 编辑 tasks.md 或 tasks.json，然后校验
./auto-loop.sh status       # 看 task 状态、engine spec、active engine
./auto-loop.sh sessions     # 看每个 task 的 per-engine sessions
./auto-loop.sh attach <id>  # 交互式接管 active engine 的 session
./auto-loop.sh report       # 生成 reports/report-<ts>.md
./auto-loop.sh ui 8787      # 本地网页 UI
./auto-loop.sh stop         # 停止 lock file 里的 PID
```

常用环境变量：

```bash
ENGINE=claude
MODEL=
EFFORT=
USAGE_LIMIT_THRESHOLD=0.90
CLAUDE_RESUME_MODE=summary
CODEX_COOLDOWN=3600
AUDIT=1
AUDIT_ENGINE=
AUDIT_MODEL=
AUDIT_EFFORT=
REQUIRE_GIT=1
```

## Mac 睡前运行和关屏

想睡前开着 auto-loop，但不让屏幕一直亮：

```bash
# 插电时：防止系统睡眠，但允许屏幕睡眠。
caffeinate -s ./auto-loop.sh run

# 只用电池时：防止 idle sleep，但会耗电。
caffeinate -i ./auto-loop.sh run
```

然后另开一个 terminal 关屏：

```bash
pmset displaysleepnow
```

注意：

- 不要用 `caffeinate -d`，它会刻意保持屏幕常亮。
- 不要合上 MacBook 盖子，除非你已经有可用的 clamshell 设置；正常合盖会睡眠。
- 可用 `pmset -g assertions` 检查当前防睡眠断言。
- 第二天早上运行 `./auto-loop.sh status`，再看 `reports/`。

<p align="center">
  <img src="docs/cli-status.jpg" alt="auto-loop terminal status table" width="820">
  <br>
  <em>早上用 status 快速看每个 task 的状态、runs、audit 结果和摘要。</em>
</p>

## 和其它工具的差异

你的定位不应该是“最大的 loop”，而是“本地、轻量、双引擎、可审计的 task queue”。

| 类型 | 代表 | 他们怎么做 | 你的差异 |
|---|---|---|---|
| 任务队列 / rate limit loop | `claude-queue` | Python worker、任务优先级/依赖、监控 Claude plan limit、接近额度时暂停 | 它更像 queue；你的核心卖点是 Claude+Codex 双引擎、per-task session、独立 auditor |
| 连续循环工具 | `Ralph` | 不断调用 coding agent，靠 exit signal、circuit breaker、resume、日志避免无限循环 | Ralph 很强；你不要硬拼“loop”，要打“task list + quota sleep/fallback + audit” |
| PR/CI 型自动开发 | Continuous Claude 类工具 | Bash loop、共享 markdown notes、自动建 PR、等 CI、合并 | 它偏 PR workflow；你更轻、更本地、更适合个人 backlog |
| 图形化 agent 指挥台 | CloudCLI、Codexia、async-code | Web/mobile/desktop UI、session 管理、parallel tasks、worktree、远程控制 | 它们更大更重；你应强调“小、可读、几百行 Bash + 本地 UI” |
| 官方异步 agent | Claude Code on web、Claude routines、OpenAI Codex | 云端 sandbox、GitHub repo、自动 PR、并行任务 | 官方产品强，但不等于本地 CLI queue；你是给仍然想控制本地 Claude Code / Codex CLI 的人 |
| 安全/guardrail | CC Safety Net | hook 拦截危险命令 | 可互补；你也要承认 prompt-level guardrail 不是 sandbox |

## 安全边界

默认会跳过 CLI approval：

- Claude: `--dangerously-skip-permissions`
- Codex: `--dangerously-bypass-approvals-and-sandbox`

这对无人值守是必要的，但也意味着你在授予本地命令执行能力。只用于你愿意让工具修改的 repo。

防线：

- worker prompt 要求只编辑 task 的 `dir`。
- 要求在 feature branch 上提交。
- 禁止碰 `main` / `master`、merge、force-push、打印 secret。
- 启动前校验 task schema、绝对路径、git repo。
- PID lock 防止两个 loop 抢同一个队列。
- secret 放环境变量，不写进 task、日志、报告、handoff。
- local UI 只绑定 `127.0.0.1`，不要暴露到网络。

诚实限制：prompt-level guardrail 不是 OS sandbox。被 prompt injection 或异常行为影响时，worker 仍可能用你给它的权限执行命令。请使用 feature branch、备份、明确的 `done` 命令，以及独立 audit。

## 文件

```text
auto-loop.sh              # runner: engines, fallback, sessions, audit, reports
scripts/prepare_tasks.py  # tasks.md -> tasks.json compiler
ui-server.py              # 标准库本地 UI backend
ui.html                   # 本地 UI
tasks.md.example          # 人类友好的任务模板
tasks.example.json        # JSON 示例
tasks.md                  # 本地任务源，git-ignored
tasks.json                # 生成的任务列表，git-ignored
state.json                # 运行状态，git-ignored
logs/                     # transcript 和 main log，git-ignored
reports/                  # markdown 报告，git-ignored
summaries/                # 上下文 summary，git-ignored
```

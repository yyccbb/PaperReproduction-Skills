---
name: run-visible
description: Launch an AI/ML experiment or training run from this research codebase in a terminal the human can watch live, then monitor it and report progress. Use this skill whenever the user asks to run, launch, start, kick off, train, sweep, fine-tune, evaluate, or reproduce an experiment, a config, a model, or a benchmark — even if they don't mention logs, terminals, or monitoring. Also use it if they ask to check on, watch, or get the status of a run that is already going.
---

# Run Visible

Long training runs must never be executed as a foreground Bash call. They will hit
the tool timeout, and the human will be left staring at a spinner with no idea
whether anything is happening.

Instead, launch the run into a **separate terminal that the human can see**, then
poll it cheaply and narrate progress.

## Workflow

### 1. Resolve the command

Figure out the exact command from the user's request and the repo's conventions
(entrypoint, config path, overrides). If the config is ambiguous, ask **before**
launching — a wrong 6-hour run is expensive.

Do a fast preflight if it's cheap: does the config file exist, is the checkpoint
dir writable, is a GPU visible. Don't skip straight to launch if something obvious
is broken.

### 2. Launch it

```bash
./scripts/spawn_visible.sh <the full training command>
```

Each run gets its own directory, `.paper-reproduction/runs/<RUN_ID>/` (timestamp-named,
overridable via `RUN_ID`/`RUN_DIR` env vars), holding `console.log`, `exit_code`, and
optionally `status.json` — the same `.paper-reproduction/` tree the other pipeline
stages write to. To find a run you didn't launch this session, look for the newest
directory there.

The script picks the best visible surface available and returns immediately:

| Situation | What the human sees |
|---|---|
| Claude Code running inside tmux | a new pane splits in beside you, live |
| WezTerm / kitty | a new split opens, live |
| macOS terminal | a new Terminal or iTerm window opens |
| Linux with a display | a new terminal window opens |
| Headless / SSH | detached tmux session, attach command printed |

It prints a block of `KEY=VALUE` lines. **Relay `BACKEND` and `ATTACH` to the user
in your very next message** so they know where to look. If `BACKEND=tmux-detached`
or `nohup`, give them the attach/tail command verbatim.

If the user is not in tmux and you're on a headless box, say so plainly and suggest
they relaunch Claude Code inside `tmux` next time — that's the best experience.

### 3. Monitor without flooding your context

Poll roughly every 60 seconds. Never `cat` the whole log.

Prefer the heartbeat file if the codebase writes one:

```bash
cat "$RUN_DIR/status.json"
```

Otherwise, read the tail of the console log. tqdm writes carriage returns, so
translate them before tailing or you'll get one enormous line:

```bash
tail -c 4000 "$LOG" | tr '\r' '\n' | grep -v '^$' | tail -5
```

If the run is in a tmux pane, this is better still — tmux has already resolved the
progress bar into its current on-screen state:

```bash
tmux capture-pane -pt "$SESSION" | grep -v '^$' | tail -10
```

Report **one line** per poll: step, metric, ETA. Not a wall of log.

### 4. Detect completion

```bash
[ -f "$RUN_DIR/exit_code" ] && cat "$RUN_DIR/exit_code"
```

- Exit 0 → summarize final metrics and point at the artifacts/checkpoints.
- Non-zero → read the last ~80 lines of the log, diagnose, and propose a fix.
  Do **not** silently relaunch; confirm with the user first.

## Hard rules

- Never run the training command directly in the foreground Bash tool.
- Never dump raw log contents into the conversation. Summarize.
- Never launch a second run while one is active without saying so — check
  `tmux has-session -t "$SESSION"` or the absence of `exit_code`.
- Always give the human the attach command, even when a window opened
  automatically. Windows get closed by accident.

## Optional: heartbeat for cheap polling

If the training loop doesn't already emit one, add this next to the existing
logging call. It makes every status check ~100 tokens instead of parsing logs:

```python
import json, os, time, pathlib
run_dir = pathlib.Path(os.environ.get("RUN_DIR", "."))
(run_dir / "status.json").write_text(json.dumps({
    "step": step, "total": total_steps, "loss": float(loss),
    "eta_s": int(eta), "phase": "train", "updated": time.time(),
}))
```

Also set `disable=not sys.stderr.isatty()` on tqdm bars so non-interactive paths
stay clean while the visible terminal still gets the animated bar.

## Optional: live progress in the Claude Code status line

Add to `.claude/settings.json` so progress is always on screen without attaching:

```json
{ "statusLine": { "type": "command", "command": ".claude/statusline.sh" } }
```

```bash
#!/usr/bin/env bash   # .claude/statusline.sh
S=$(cat .paper-reproduction/runs/latest/status.json 2>/dev/null) || exit 0
jq -r '"⏵ \(.step)/\(.total)  loss \(.loss|tostring[0:5])  eta \(.eta_s/60|floor)m"' <<<"$S"
```

Have the launcher `ln -sfn "$RUN_DIR" .paper-reproduction/runs/latest` if you use this.

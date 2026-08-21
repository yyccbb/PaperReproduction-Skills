---
name: run-experiment
description: Stage of a paper-reproduction pipeline, run from inside the cloned paper codebase after experiment-scoping, resource-download, environment-setup, and run-validation have written their reports under .paper-reproduction/. Use whenever the task is to launch the full-length reproduction runs — scale the validated mock commands back up to paper-faithful duration, expand sweeps, execute every run sequentially via the run-visible skill, and record logs, artifacts, and evidence in a structured report. Do not use for scoping experiments, downloading assets, building or repairing environments, or running/validating mock commands.
---

# run-experiment

Launch the full-length reproduction runs: scale the validated commands back up to their
paper values, expand sweeps into an explicit run list, execute each run sequentially in a
visible terminal, and record every command, log, artifact, and outcome so the results can
be compared to the paper without re-reading the session.

## Position in the pipeline

This is stage 5. Everything before it existed to make this stage boring, and everything
it records — `run-experiment.md`'s Run index and the per-run `run.json`s — is what
**result-analysis** (stage 6) reads to compare the runs against the paper's numbers:

- **experiment-scoping** (stage 1): `.paper-reproduction/experiment-scoping.md` — the
  full-run commands, the "Mock-run downscaling" section (which flags were reduced and
  their paper-faithful values), and the valid-tuple tables for sweeps.
- **resource-download** (stage 2): `.paper-reproduction/resource-download.md` — context
  for asset paths and the hardware the feasibility verdicts apply to.
- **environment-setup** (stage 3): the conda env `pr-<repo-dirname>` and its lockfile.
- **run-validation** (stage 4): `.paper-reproduction/run-validation.md` — the **validated
  commands** (concrete, placeholder-substituted, proven to execute), the fix log, the
  per-experiment verdicts, and "Notes for the full runs" (pre-announced risks like OOM).
- **run-visible** (helper skill): how every run is launched — in a terminal the human can
  watch — and monitored. Read it before launching; this skill overrides two of its
  behaviors (poll cadence and on-failure handling), stated below.

Your output is the set of completed runs on disk plus `run-experiment.md` indexing them.
This stage **does not fix anything**: the codebase was frozen by stage 4's validation,
and an edit here — to code, env, or scientifically meaningful hyperparameters — would
mean the thing that ran is no longer the thing that was validated. A run that fails at
full scale is a *finding*, recorded with a diagnosis and handed back to stage 4, not a
debugging session.

## Inputs

- The codebase is the current working directory (or the directory the user points at).
- `.paper-reproduction/run-validation.md` and `.paper-reproduction/experiment-scoping.md`
  are **required**. If either is absent, say so and stop — deriving full commands without
  the validated baseline would silently skip the pipeline's safety net.
- The conda env named in `.paper-reproduction/environment-setup.md` — `pr-<repo-dirname>`
  by default, possibly a reused env in a baseline repo — must exist (`conda env list`);
  if not, stop and point at stage 3. Use that name wherever this skill writes
  `pr-<repo-dirname>`.
- Only experiments marked **VALIDATED** by stage 4 are yours to run. SKIPPED, FAILED, and
  BLOCKED experiments are recorded in your report with the upstream verdict, never
  resurrected — if the user wants one revived, that goes back through stage 4.

## Process

### 1. Preflight: pin down exactly what will run

- **Git state**: confirm the repo is on the `run-validation` branch with a clean working
  tree (untracked/ignored `.paper-reproduction/` content is fine). Record the commit
  hash — every run's results must be attributable to an exact code state. A dirty tree
  or a different branch means someone touched the code after validation: stop and report
  rather than run unattributable experiments.
- **Read stage 4's "Notes for the full runs"** and carry each item into your report's
  Risk section — these are the failures the mock couldn't surface (OOM at real batch
  size, slow steps, fixes whose interpretation should be checked against results).

### 2. Build the run list — from stage 4's commands, not stage 1's

For each VALIDATED experiment, the full command is derived, not re-invented:

1. Start from **stage 4's validated command** — it already has real paths substituted
   and provably executes. Re-deriving from stage 1 would redo the substitution and
   re-introduce exactly the errors stage 4 spent commits fixing.
2. Restore the duration knobs to their full values using stage 1's **"Mock-run
   downscaling"** section (e.g. `--epochs 2` → `--epochs 200`). Touch only the flags
   that section names; everything else in the validated command stays verbatim.
3. If the experiment is a sweep, expand stage 1's **valid-tuple table** into one command
   per row by varying the swept flags on top of the scaled-up command. Apply stage 4's
   **fix log** to every row, not just the canonical one — a renamed flag or repaired
   argparse entry from validation affects the whole sweep, and a row built from stage
   1's original text would reintroduce the bug.
4. Assign each run a deterministic id: `exp<N>-run<K>-<slug>` where `<slug>` is a short
   human-readable tag from the tuple (e.g. `exp1-run2-syn4-t5`). Predictable ids are
   what make the runs directory navigable and the resume scan (step 3) possible.

Write the complete list — every fully written-out command with its run id — into the
report's "Run manifest" section **before executing anything**. If a launch later
deviates from the manifest for any reason, that is a report-worthy event, not a silent
substitution.

Estimate wall-time per run while you're here: mock runtime × the duration-knob ratio
(e.g. mock ran 2 epochs in 3 min → 200 epochs ≈ 5 h) is crude but honest. Record the
per-run and total estimates, and sanity-check checkpoint disk usage across the sweep
against free disk. Launch regardless — the estimates are for the record and for pacing
your monitoring, not a gate.

### 3. Resume scan: never redo a finished run

Full sweeps outlive sessions. Before launching, scan `.paper-reproduction/runs/` for
directories matching your run ids. A run is **already complete** when its `exit_code`
file reads `0` *and* its log or artifacts show real work (the same evidence bar as step
5). Mark such runs COMPLETE (prior session) in the report and skip them; everything
else — missing, non-zero exit, or exit 0 without evidence — runs fresh. This makes
re-invoking the skill continue the sweep instead of restarting it.

### 4. Execute sequentially with run-visible

One run at a time, in manifest order. Sequential is the point, not a limitation: full
runs contend for the same GPU, and two half-speed runs that OOM each other are worse
than a queue.

Launch each run through run-visible's launcher with explicit naming, wrapping the
command in the env (the launcher's wrapper does **not** activate conda):

```bash
RUN_ID=exp1-run2-syn4-t5 \
  <path-to-run-visible>/scripts/spawn_visible.sh \
  conda run --no-capture-output -n pr-<repo-dirname> bash -c '<full command>'
```

Relay `BACKEND` and `ATTACH` to the user as run-visible instructs. Then monitor, with
two deliberate overrides of run-visible's defaults:

- **Poll cadence scales with the estimate.** run-visible's ~60 s cadence suits an
  interactive run; polling a 6-hour run every minute burns the entire context on log
  tails. Poll at roughly `estimate / 20`, clamped to [2 min, 30 min], and report one
  line per poll. Use the heartbeat `status.json` when the code writes one.
- **On failure, do not enter a fix loop.** run-visible says "diagnose and propose a
  fix"; here the policy is **record & continue**: read the tail of the log, write a
  one-paragraph diagnosis (what failed, at what step, whether stage 4's notes predicted
  it), mark the run FAILED in the report with a pointer back to stage 4, and start the
  next run. Never edit code, never touch the env, and never shrink a batch size or
  other meaningful hyperparameter to coax a pass — a "successful" run with altered
  hyperparameters reproduces nothing.

After harvesting `exit_code`, clean up: if the backend was a detached tmux session,
kill it (`tmux kill-session -t exp-<RUN_ID>`) so a 12-run sweep doesn't strand 12
sessions waiting at "press enter to close". Leave visible panes/windows to the human.

### 5. Judge each run by evidence, then record it

Exit 0 is necessary but not sufficient (stage 4's rule, unchanged): a run **completes**
when it exits 0 and the log/artifacts show the work happened at full scale — the final
epoch/step reached, finite losses, the eval metric printed, checkpoints/result files
where the code writes them. Exit 0 after suspiciously little wall-time gets investigated
and, if hollow, recorded as FAILED with that diagnosis.

For every run (COMPLETE or FAILED), write `run.json` into its run directory:

```json
{
  "run_id": "exp1-run2-syn4-t5",
  "experiment": "Exp 1: <name>",
  "command": "<the exact command executed>",
  "tuple": {"DATASET": "syn4", "T": 5},
  "git_commit": "<hash>",
  "started": "<ISO time>", "ended": "<ISO time>",
  "exit_code": 0,
  "status": "COMPLETE",
  "evidence": "reached epoch 200/200, final test acc 91.2",
  "artifacts": ["/abs/path/to/ckpt.pth", "/abs/path/to/results.json"],
  "log": "/abs/path/to/console.log"
}
```

This file is what makes the runs directory self-describing: a later comparison against
the paper's numbers should need only the `run.json`s and the artifacts, not this
conversation.

## Output format

ALWAYS use this exact structure, saved to `.paper-reproduction/run-experiment.md` under
the repo root (update it incrementally as runs finish — a crash mid-sweep must not lose
the record of completed runs):

`````markdown
# Run Experiment Report

## Summary
- Code state: branch run-validation @ <commit hash>
- Env: pr-<name>
- Runs: <N> complete, <N> failed, <N> resumed from a prior session, <N> not run (upstream verdict)

| Run | Experiment | Status | Wall time | Evidence / reason |
|---|---|---|---|---|
| exp1-run1-syn1-t4 | Exp 1 | COMPLETE | 4h50m | test acc 91.2, ckpt saved |
| exp1-run2-syn4-t5 | Exp 1 | FAILED | 1h12m | CUDA OOM at step 8k (predicted by stage 4 notes) |
| — | Exp 2 | NOT RUN | — | stage 4 verdict: FAILED |

## Run manifest
Per run: id, the exact full command (written before execution), and the wall-time
estimate. Note any launch that deviated from the manifest and why.

## Run index
Per run: run directory, log path, `run.json` path, artifact paths. This is the section
a results-analysis step reads first.

## Failed runs
Per FAILED run: the final error, the step/epoch reached, the diagnosis, whether stage
4's notes predicted it, and what stage 4 (or the user) would need to address.

## Risks carried from validation
Stage 4's "Notes for the full runs", each annotated with what actually happened.

## Notes
Anything a results-comparison step should know: runs resumed rather than launched,
suspicious-but-accepted outputs, disk/time actuals vs. estimates.
`````

## Boundaries

- **Never edit code, the environment, or scientifically meaningful hyperparameters.**
  Failures at full scale are recorded and routed back to stage 4 — a fix applied here
  would desynchronize the run from what was validated.
- Never download assets; a missing path is a FAILED run with a stage-2 pointer.
- Runs are strictly sequential; never launch a run while another is active.
- Never re-execute a run already complete with evidence; never delete or overwrite an
  existing run directory.
- Never run experiments stage 4 did not mark VALIDATED, and never start extra runs the
  manifest doesn't list (no bonus seeds, no extra ablations).
- Full runs only — mock/smoke commands belong to stage 4.

---
name: run-validation
description: Stage of a paper-reproduction pipeline, run from inside the cloned paper codebase after experiment-scoping, resource-download, and environment-setup have written their reports under .paper-reproduction/. Use whenever the task is to execute the planned mock-run commands, validate that each experiment runs end-to-end, and fix the code in an error-driven loop with every fix tracked as a git commit — including feeding environment errors back to the environment-setup skill for repair. Do not use for scoping experiments, downloading datasets/checkpoints, building environments from scratch, or launching the final full-length reproduction runs.
---

# run-validation

Prove that every planned experiment actually executes end-to-end, by running its mock
command and fixing whatever breaks — code fixes committed one by one to git, environment
errors handed to the environment-setup skill — until the mock passes or a stop rule fires.

## Position in the pipeline

This is stage 4. It consumes everything the earlier
stages wrote:

- **experiment-scoping** (stage 1): `.paper-reproduction/experiment-scoping.md` — the
  mock-run commands you will execute verbatim (after placeholder substitution), and a
  Notes/risks section that often pre-announces bugs (README flags the parser rejects,
  suspected code drift) left deliberately for this stage to fix.
- **resource-download** (stage 2): `.paper-reproduction/resource-download.md` — the
  placeholder→absolute-path mapping to substitute into commands, and per-experiment
  feasibility verdicts (SKIPPED/BLOCKED experiments are not yours to resurrect).
- **environment-setup** (stage 3): the conda env `pr-<repo-dirname>`, the lockfile, and
  `.paper-reproduction/environment-setup.md`. When a run fails with an *environment*
  error, you do not fix the env yourself — you invoke the environment-setup skill in
  repair mode with the env name and the traceback, and rerun after it reports success.

Your output is the **fixed codebase** (a git branch of small, revertable commits) plus a
validation report. A mock run that passes here means the full reproduction run can be
launched with confidence; a fix log in git means any fix that later turns out to be wrong
can be reverted surgically instead of archaeologically.

## Inputs

- The codebase is the current working directory (or the directory the user points at).
- `.paper-reproduction/experiment-scoping.md` is **required**. If absent, say so and stop —
  do not invent commands to validate; that would hide that the pipeline is running out of
  order.
- `.paper-reproduction/resource-download.md` is required whenever the scoping commands
  contain placeholders (`<DATA_DIR>`, `<CKPT_DIR>`, …). If the scoping report needs no
  assets, its absence is fine — note that and proceed.
- The conda env named in `.paper-reproduction/environment-setup.md` — `pr-<repo-dirname>`
  by default, but possibly a reused env from another repo (e.g. `pr-<main-repo>` in a
  baseline repo) — must exist (`conda env list`). If it doesn't, stop and point the user
  at stage 3 — running mock commands in an arbitrary environment produces errors that say
  nothing about the code. Use that env name wherever this skill writes `pr-<name>`.

## Process

### 0. Establish the git baseline

Every fix must be tracked, and the pristine state must stay recoverable:

- If the repo already has a git history (the normal case for a cloned paper repo): record
  the baseline commit hash, then create and switch to a branch named `run-validation`. If
  the working tree is dirty (earlier stages wrote `.paper-reproduction/`), make sure
  `.paper-reproduction/` is gitignored (append to `.gitignore` if needed — that change is
  your first commit); commit any other pre-existing modifications as a
  `[run-validation] baseline` commit so your fixes are cleanly separated from them.
- If there is genuinely no `.git`: `git init`, gitignore `.paper-reproduction/` (plus
  obvious bulk like `data/` if present), and make an initial commit of the pristine tree.

**Commit policy: one logical fix = one commit**, made immediately after the fix and
*before* rerunning. One commit may touch several files if they are the same fix (e.g. a
renamed function and its call sites), but never bundle two unrelated fixes — the whole
point is that a wrong fix can be reverted alone. Message format:

```
[run-validation] <exp id, or "pre-run">: <what was fixed>

Error: <the error line that motivated it, or "found in pre-run scan">
```

### 1. Pre-run pass: fix only the *obvious* errors

Before executing anything, fix errors that are certain without running. The bar is
strict, because every pre-run fix is speculative — the run loop is the ground truth, and
a "fix" applied on a misreading breaks working code. An error is **obvious** only if it
is mechanical and its correction is unambiguous:

- **Syntax errors** — the file does not compile. Check every script an experiment touches
  with `conda run -n pr-<name> python -m py_compile <file>` (the entry script plus the
  repo-local modules it imports, followed transitively).
- **Spelling/typo errors in identifiers** where the intended name is unambiguous:
  `import nunpy`, `from data_loder import ...` when `data_loader.py` exists,
  `model.forwrad(x)` when the class defines `forward`.
- **Module-path errors** where the file plainly moved: `from utils.metrics import f`
  when the function lives in `metrics.py` at the repo root and no `utils/` exists.
- **Bugs stage 1 explicitly flagged with a located cause** — e.g. "README flag
  `--warmup` will fail argparse; the value is consumed in `train.py:88`". Stage 1
  already did the investigation; finish the repair it prescribed (add the missing
  argparse entry), don't re-litigate it.

Everything else is **not obvious**, even when you have a strong hunch: logic bugs, shape
mismatches, off-by-ones, API-migration breakage (`torch.load` weights_only, moved
functions), missing files, wrong defaults. Those wait for the run loop, where the actual
traceback confirms the diagnosis before you touch the code.

Commit each pre-run fix separately under the policy above.

### 2. Prepare the concrete commands

For each experiment in the scoping report:

- Honor stage 2's verdicts first: an experiment marked SKIPPED or with a BLOCKED asset is
  recorded as SKIPPED in your report with stage 2's reason, and never run.
- Substitute every placeholder in the mock command using stage 2's "Placeholder mapping"
  table, verbatim. Verify each substituted path exists (`ls`) before running — a missing
  path at this point is a stage-2 discrepancy to report, not something to fix by
  downloading.
- Record the final concrete command; that exact string is what you run and what goes in
  the report.

### 3. The run-and-fix loop (per experiment, one at a time)

```
run → passed? done : classify error → repair (env: delegate / code: fix+commit) → rerun
```

**Run** the concrete mock command from the repo root inside the env, capturing output:

```bash
conda run --no-capture-output -n pr-<name> bash -c '<command>' \
  > .paper-reproduction/runs/validation/exp<N>-attempt<K>.log 2>&1
```

Mock runs are downscaled by design, so foreground with a generous timeout is usually
fine; if a run legitimately needs longer than the tool timeout, launch it in the
background and poll the log tail (translate `\r` to `\n` before tailing — progress bars
otherwise produce one enormous line). Never paste whole logs into the conversation; read
the tail and the traceback.

**On failure, classify before touching anything** — use the same taxonomy
environment-setup's repair mode uses, so the two stages never disagree:

- **Environment error**: `ModuleNotFoundError`/`ImportError`, version-attribute errors
  (`module 'x' has no attribute 'y'` from a moved API), ABI/binary errors (numpy 2.x vs
  1.x-compiled modules), CUDA runtime/initialization failures, resolver conflicts.
  → Invoke the **environment-setup skill in repair mode**, giving it the env name and
  the full traceback. When it reports the env repaired and re-verified, rerun. Do not
  pip-install into the env yourself — casual installs bypass its lockfile discipline and
  desynchronize `environment.lock.txt`.
- **Code error**: logic exceptions, shape mismatches, argparse failures, wrong paths
  constructed in code, missing attributes on the repo's own classes, and API-migration
  breakage where the right response is adapting the *call site* to the installed
  version. → Fix it yourself, smallest faithful change, one commit, rerun.
- **Asset error**: a file the placeholder mapping was supposed to provide doesn't exist
  or is malformed. → Not yours to fix by downloading; record it as BLOCKED for this
  experiment with what stage 2 must redo, and move on.

If environment-setup examines an error you sent it and hands it back as a code error,
accept that verdict and fix the code. If the *same* error bounces between the two
classifications twice, stop that experiment and report the impasse honestly rather than
looping.

**Fixes must preserve the experiment's meaning.** You are validating the authors' code,
not improving it:

- Never change scientifically meaningful hyperparameters to make an error go away
  (shrinking the batch size to dodge an OOM changes the experiment — record the OOM as a
  finding instead, noting that the *full* run will need a real resolution).
- Never delete or comment out failing functionality, and never wrap failures in
  `try/except` to get to exit 0 — a mock that "passes" by skipping the broken part
  validates nothing and poisons the full run.
- When a fix requires choosing among plausible author intents (which of two shapes did
  they mean?), pick the one consistent with the paper and say so in the commit message
  and report.

**Stop rules**, so a stubborn experiment can't consume the whole session: give up on an
experiment and mark it FAILED when (a) the same error recurs unchanged after a fix that
was supposed to address it, twice in a row; (b) roughly 10 fix-rerun cycles have not
produced a pass; or (c) the fix that would be required is not mechanical but scientific
(missing model code, a dataset format the code never supported). A FAILED experiment
gets its best diagnosis in the report; the remaining experiments still run.

### 4. Declare success honestly

Exit code 0 is necessary but not sufficient. A mock run **passes** when it exits 0 *and*
the log shows it actually did the work — training steps/epochs logged with finite (non-NaN)
losses, an eval metric printed, an output artifact (checkpoint, results file) created
where expected. A script that exits 0 in two seconds after printing nothing gets
investigated, not celebrated. Record the evidence (last metric line, artifact path) in
the report.

## Output format

ALWAYS use this exact structure, saved to `.paper-reproduction/run-validation.md` under
the repo root:

`````markdown
# Run Validation Report

## Summary
- Branch: run-validation (baseline: <hash>)
- Experiments: <N> validated, <N> failed, <N> skipped

| Experiment | Status | Attempts | Evidence / reason |
|---|---|---|---|
| Exp 1: <name> | VALIDATED | 3 | 2 epochs, final loss 1.83, ckpt at <path> |
| Exp 2: <name> | SKIPPED | — | stage 2 verdict: 20B ckpt > VRAM |
| Exp 3: <name> | FAILED | 10 | best diagnosis: <one line> |

## Validated commands
Per validated experiment, the exact concrete command (placeholders substituted) that
passed, ready to be scaled back up to the full run.

## Fix log
| Commit | Exp | Error (one line) | Fix (one line) |
|---|---|---|---|
| <hash> | pre-run | `from data_loder import` typo | corrected import |
| <hash> | Exp 1 | argparse missing --warmup | added arg, consumed at train.py:88 (per stage 1 note) |

## Environment repairs
Errors delegated to environment-setup, with its outcome — or "none". (Details live in
its own Repair log.)

## Failed / blocked experiments
Per FAILED experiment: the final error, the fixes attempted, and the best diagnosis.
Per BLOCKED experiment: the missing/malformed asset and what stage 2 must redo.

## Notes for the full runs
Anything the mock surfaced that the full-length runs must account for: OOM risks noted
(not papered over), slow steps, warnings that will matter at scale, fixes whose chosen
interpretation should be double-checked against results.
`````

## Boundaries

- This skill runs **mock commands only**. The full-length reproduction runs are a
  separate, deliberate act after validation (e.g. via a run-launching skill) — do not
  start one because the mock passed.
- Never modify the environment directly — environment errors go to the environment-setup
  skill in repair mode, so the lockfile stays truthful.
- Never download datasets or checkpoints — missing assets are BLOCKED findings for
  stage 2, not gaps to fill.
- Never edit code except to fix an error under the rules above — no refactors, no style
  cleanup, no speculative hardening; every commit must trace to a specific error or a
  stage-1 flagged bug.
- Never force-push, rewrite history, or touch branches other than `run-validation`.

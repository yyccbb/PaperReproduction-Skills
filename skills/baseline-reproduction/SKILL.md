---
name: baseline-reproduction
description: Stage 5.5 of a paper-reproduction pipeline, run from inside the main cloned paper codebase after run-experiment has finished the main method's full runs. Use whenever the task is to also reproduce the baseline/comparison methods' numbers for the experiments already reproduced — locate each baseline's code, clone it as a sibling repo, and drive the existing pipeline stages (experiment-scoping in scoped mode, resource-download, environment-setup, run-validation, run-experiment) inside each baseline repo, restricted to exactly the datapoints the main paper's comparisons need, then index everything in .paper-reproduction/baselines.md for result-analysis. Do not use for reproducing the main method itself, for analyzing or plotting results, or for baselines whose entry point lives inside the main repo.
---

# baseline-reproduction

Reproduce the comparison rows, not just the method: for each baseline the paper compares
against, find its code, clone it beside the main repo, and run the same pipeline inside
it — scoped down to exactly the datapoints the main paper's tables and figures need — then
hand result-analysis one index of where every baseline's results live.

## Position in the pipeline

This is stage 5.5, between run-experiment and result-analysis, run from inside the **main**
repo. It is an *orchestrator*: it does no scoping, downloading, env-building, fixing, or
running itself — it drives the existing stage skills inside each baseline repo, the same
way the main pipeline drove them inside this one:

- **experiment-scoping** (stage 1, main repo): its **Baseline coverage** table names the
  baseline methods per experiment, whether this repo has an entry point for them, and any
  code source the paper states. Baselines with an entry point *here* are already covered
  by the main runs and are not this stage's business.
- **run-experiment** (stage 5, main repo): its report tells you which experiments actually
  completed — by default, baselines are reproduced only for those, and this stage must not
  start while main full runs still occupy the GPU.
- **resource-download** (stage 2, main repo): its report is passed into each baseline
  repo's resource-download invocation as the known-assets report, so shared benchmarks are
  never downloaded twice.
- **environment-setup** (stage 3, main repo): the env `pr-<main-repo-dirname>` is passed
  into each baseline repo's environment-setup invocation as the candidate env, reused only
  when it needs zero modification.
- **result-analysis** (stage 6) consumes *your* output, `.paper-reproduction/baselines.md`:
  absolute paths to every baseline's run index, plus per-datapoint statuses and
  comparability caveats.

## Inputs

- The **main** codebase is the current working directory (or the directory the user points
  at). All paths in your report are absolute, because they cross repo boundaries.
- `.paper-reproduction/experiment-scoping.md` and `.paper-reproduction/run-experiment.md`
  are **required**. If either is absent, say so and stop — without the scoping report there
  is no baseline list, and without the run report there is no knowing which experiments
  merit baselines (or whether the GPU is free).
- The main paper PDF, found in the repo the same way stage 1 found it.
- `.paper-reproduction/resource-download.md` and the env `pr-<main-repo-dirname>` are used
  when present (reuse inputs for the sub-pipelines); their absence disables reuse but does
  not block the stage.

## Process

### 1. Build the baseline manifest

From stage 1's Baseline coverage table, the main paper, and stage 5's run report, decide
exactly what must be produced. Per baseline method:

- **Which experiments it appears in**, restricted by default to experiments with at least
  one COMPLETE main run in stage 5's report. Baselines for experiments the main pipeline
  never completed are deliberately excluded — list them as such (the user can override).
- **The exact datapoints needed**: for each experiment, the table/figure cells the paper
  reports for this baseline — dataset/setting, metric, and the paper's stated value with
  its table/page citation. This list is the compute budget: nothing outside it gets run.
- **Hyperparameters the main paper states for this baseline** (experimental-setup sections
  and appendices often specify how baselines were configured — budget-matched training,
  same backbone, specific λ). Extract them now, with citations; they go into the scope
  file, where they outrank the baseline repo's own defaults.
- **Skip baselines the main repo already covers**: coverage rows marked "yes — entry point
  in this repo" (ablations, w/o variants) belong to the main runs, not here.

### 2. Acquire each baseline's code

Locate the implementation with this precedence, recording provenance for each:

1. A code source the main paper states (citation footnote, appendix URL) — the Baseline
   coverage table's "Code source" column.
2. The baseline's own paper (find it from the main paper's bibliography, e.g. on arXiv)
   and the official repo it links.
3. A web search for the official implementation — "official" meaning the repo is owned by
   the baseline paper's authors or their lab/org.
4. A well-known third-party reimplementation, only when no official code exists — record
   it prominently as **unofficial**, because it is a comparability caveat that
   result-analysis must surface.

If nothing credible is found, mark the baseline NOT FOUND with what was searched, and move
on — never reimplement a baseline from scratch here.

Clone each found repo to a **sibling** location, never inside the main repo:
`<parent-of-main-repo>/baselines/<method-slug>/`. (Inside the main repo it would sit in a
gitignored directory of another git checkout and confuse run-validation's git handling in
both repos.) Fetch the baseline's own paper PDF (arXiv) into its repo when you can find
it; in scoped mode it is helpful but optional. If the target directory already exists from
a prior session, resume rather than re-clone: inspect its `.paper-reproduction/` reports
and skip sub-stages that already completed.

### 3. Write the scope file

In each baseline repo, write `.paper-reproduction/scope.md` — the contract that switches
experiment-scoping into scoped mode and carries everything it needs from the main paper,
so the sub-pipeline never has to re-read it:

```markdown
# Reproduction Scope
- Invoking paper: <title>; main repo at <absolute path>
- Method to reproduce in this repo: <name as the invoking paper calls it>

## Datapoints required
| # | Invoking-paper experiment | Table/Figure cell | Dataset / setting | Metric | Paper-reported value |
|---|---|---|---|---|---|
| 1 | Main result (Table 1) | Table 1 row "L2X", col "syn1" | syn1 | median rank | 4.6 |

## Hyperparameters stated by the invoking paper for this method
- <flag-level detail with citation, or "none stated">

## Notes
<protocol details from the invoking paper: seeds, budget matching, backbone, eval script>
```

The scope file is the *only* channel of intent into the sub-pipeline: if a constraint is
not written here, the sub-stages will not honor it.

### 4. Drive the sub-pipeline, one baseline repo at a time

Spawn one subagent per baseline repo, **sequentially** — the later sub-stages compete for
the same GPU, and two baselines validating at once OOM each other. Each subagent works
from inside its baseline repo and invokes the existing skills in order:

1. **experiment-scoping** — enters scoped mode automatically via the scope file.
2. **resource-download** — pass the main repo's `resource-download.md` (absolute path) as
   the known-assets report, so shared datasets resolve to already-downloaded paths.
3. **environment-setup** — pass `pr-<main-repo-dirname>` as the candidate env; it reuses
   only on a clean zero-install pass, otherwise builds `pr-<baseline-dirname>`.
4. **run-validation** — unchanged.
5. **run-experiment** — unchanged.

Failure and blocking policy, per baseline:

- A sub-stage that fails hard (scoping finds no entry point for any scoped datapoint,
  validation FAILs everything) ends that baseline's sub-pipeline: record the status and
  the failing stage's verdict, then move to the next baseline. One stubborn baseline must
  never sink the stage.
- If resource-download inside a baseline blocks on a manual-access asset, do not stall
  the queue: record the baseline as PENDING-USER with the exact request its report
  prepared, continue with the other baselines, and surface all pending requests together
  in your final message. Re-invoking this stage after the user acts resumes exactly there.
- Partial success is normal and worth keeping: a baseline with 3 of 5 datapoints COMPLETE
  is indexed with per-datapoint statuses, not discarded.

### 5. Index everything into baselines.md

As each baseline finishes (or fails), update the report — a crash must not lose completed
baselines.

## Output format

ALWAYS use this exact structure, saved to `.paper-reproduction/baselines.md` under the
**main** repo root:

`````markdown
# Baseline Reproduction Report

## Summary
| Baseline | Code | Repo path | Env | Datapoints | Status |
|---|---|---|---|---|---|
| L2X | official (paper App. F) | /abs/path/baselines/l2x | pr-l2x | 4/4 | COMPLETE |
| INVASE | unofficial (github.com/x/y) | /abs/path/baselines/invase | reused pr-<main> | 2/5 | PARTIAL |
| REAL-X | — | — | — | 0/3 | NOT FOUND |

## Deliberately excluded
Baselines covered by the main repo's own runs (entry point in main repo), and baselines
for experiments the main pipeline did not complete — each with a one-line reason.

---

## Baseline: <method>

- **Repo:** /abs/path (cloned from <URL>; official / unofficial — provenance in one line)
- **Scope file:** /abs/path/.paper-reproduction/scope.md
- **Env:** pr-<name>, or "reused pr-<main-name> (zero-install pass)"
- **Stage reports:** absolute paths to its experiment-scoping.md, resource-download.md,
  environment-setup.md, run-validation.md, run-experiment.md (whichever exist)
- **Run index:** absolute path to its run-experiment.md — the section result-analysis
  reads first.

| Datapoint (scope #) | Status | Evidence / reason |
|---|---|---|
| 1 — Table 1, syn1 | COMPLETE | run l2x-exp1-run1, median rank in results.json |
| 2 — Table 1, syn4 | FAILED | OOM at full length; its run-validation notes flagged it |

## Pending user action
Per PENDING-USER baseline: the exact manual step its resource-download report prepared —
or "none".

## Notes for result-analysis
Comparability caveats (unofficial code, fewer seeds than the paper, protocol deviations),
extraction hints per baseline (where metrics land, which env reads its artifacts), and
anything a side-by-side reader must weigh.
`````

## Boundaries

- **Never touch the main repo's code or env.** In the main repo this stage writes exactly
  one thing: `.paper-reproduction/baselines.md`.
- This skill orchestrates; the sub-stages do the work. Never scope, download, build envs,
  fix code, or launch runs directly — if a sub-stage refuses something, that refusal is a
  finding, not something to do by hand around it.
- Compute discipline: nothing beyond the scoped datapoints — no baseline ablations, no
  extra seeds, no "while we're here" experiments in baseline repos.
- Run only after the main repo's stage 5 is finished; baseline repos run strictly one at
  a time.
- Never reimplement a baseline; NOT FOUND is an honest and acceptable verdict.
- No result comparison, no plots, no verdicts — that is stage 6's job, fed by your index.

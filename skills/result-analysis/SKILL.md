---
name: result-analysis
description: Final stage of a paper-reproduction pipeline, run from inside the cloned paper codebase after run-experiment has written .paper-reproduction/run-experiment.md and the runs directory. Use whenever the task is to analyze or compare reproduction results against the paper — locate each experiment's results presentation (table or figure) in the paper PDF, extract metrics from the actual run logs and artifacts with scripts, regenerate the paper's table or plot from the actual results, and present paper and reproduction side by side. Do not use for scoping experiments, downloading assets, setting up environments, validating mock runs, or launching runs.
---

# result-analysis

Turn the completed reproduction runs into a paper-vs-reproduction comparison: for each
experiment, find where the paper presents its results, extract the corresponding numbers
from the actual runs with auditable scripts, regenerate the paper's table or plot from
those numbers, and present the two side by side — without passing judgment on whether the
reproduction "succeeded".

## Position in the pipeline

This is stage 6, the last one. Everything upstream exists so that this stage can be pure
reading and arithmetic:

- **run-experiment** (stage 5): `.paper-reproduction/run-experiment.md` — its **Run index**
  is written for exactly this consumer (run directories, logs, `run.json` paths, artifact
  paths), and its **Notes** often contain extraction hints ("Figure-1 points must be
  extracted post-hoc from TB event files") and caveats a reader of your report needs (runs
  that hit the epoch cap while still improving). Each run directory's `run.json` carries
  the exact command, the swept tuple, and the artifact list.
- **experiment-scoping** (stage 1): `.paper-reproduction/experiment-scoping.md` — maps each
  experiment to the paper table/figure it reproduces (experiment names cite them, e.g.
  "Main result — CIFAR-10 (paper Table 1)") and records the metrics involved.
- **environment-setup** (stage 3): the conda env `pr-<repo-dirname>`, which is where your
  extraction and plotting scripts run. It is expected to already contain the analysis
  packages this stage relies on (matplotlib, pandas, numpy, pymupdf, tbparse) alongside
  the repo's own stack (torch, lightning, …) for reading checkpoints and event files.
- The **paper PDF**, found in the repo the same way stage 1 found it.
- **baseline-reproduction** (stage 5.5, optional): `.paper-reproduction/baselines.md` —
  when present, it indexes reproduced baseline results living in sibling baseline repos:
  per baseline, absolute paths to its own `run-experiment.md` and run directories,
  per-datapoint statuses, the env that reads its artifacts, and comparability caveats.
  Reproduced baselines join the side-by-side; the file's absence just means the
  comparison covers the main method only.

Your output is `.paper-reproduction/result-analysis.md` plus the scripts, data files, and
figures under `.paper-reproduction/analysis/`. The codebase and the environment stay
frozen: this stage adds analysis files and nothing else. A number that cannot be extracted,
a package that is missing, a run that failed upstream — each is a *finding to report*, not
something to fix, install, or re-run here.

## Inputs

- The codebase is the current working directory (or the directory the user points at).
- `.paper-reproduction/run-experiment.md` is **required**. If absent, say so and stop —
  there is nothing trustworthy to analyze, and reconstructing results by scavenging the
  repo would bypass the pipeline's chain of evidence.
- The paper PDF: glob for `*.pdf` (root first, then recursively, ignoring obvious
  non-paper PDFs). If several candidates exist, pick the one that looks like the paper and
  say which you chose. If none is found, stop — the whole point of this stage is the
  comparison, and half of it would be missing.
- Only runs marked **COMPLETE** in stage 5's report are analyzed. Experiments that are
  FAILED or NOT RUN upstream appear in your report as NOT ANALYZED with the upstream
  reason — never re-run, never patched around, and never represented by partial numbers
  scraped from a dead run's log.
- The conda env `pr-<repo-dirname>` must exist (`conda env list`) whenever extraction needs
  to execute code (reading TB events, unpickling checkpoints, even just matplotlib). If it
  doesn't, stop and point at stage 3.

## Process

### 1. Preflight: inventory what exists before writing anything

- Read stage 5's Run index and Notes, and stage 1's per-experiment sections. Build the
  work list: for each experiment, its COMPLETE runs (with artifact paths) or its upstream
  verdict.
- Introspect the env once: `conda run -n pr-<repo-dirname> pip list` (or targeted import
  checks). Record the versions of the packages your scripts will use — and **write the
  scripts against the versions actually installed**, not against whatever API you remember
  as current. The env is read-only: if something needed is missing, record it as a blocker
  for stage 3 in the report and analyze what you can without it. Never pip/conda install.
- Create `.paper-reproduction/analysis/{scripts,data,figures}/`. Everything you produce
  lives there.

### 2. Locate the paper's presentation of each experiment

For each experiment, find where the paper reports the results this experiment reproduces —
usually already cited by stage 1's experiment name. Record:

- The exact identifier and page: "Table 1, p. 6" / "Figure 3 (left), p. 8".
- The **mode**: table or plot.
- What is being presented: the rows/columns and metrics for a table; the axes, scales,
  series, and metrics for a plot.
- The paper's numeric values, **only where the paper states them as numbers** — table
  cells, or values quoted in the text. A curve in a figure is not a source of numbers:
  reading data points off a plotted line is fabrication with extra steps, and a
  side-by-side of the images already lets the human make exactly that visual comparison.

### 3. Extract the actual metrics — with scripts, never by hand

Every number in your report must be reproducible by running a saved script, because the
report's whole value is that a human can audit it without trusting this session. The
failure mode to design against is hand-transcribing: reading a number off a log with your
eyes and typing it into a table or a plot script. Instead:

- Write one extraction script per experiment (or per artifact format) in
  `.paper-reproduction/analysis/scripts/`, run it with
  `conda run --no-capture-output -n pr-<repo-dirname> python …`, and have it write its
  output as CSV/JSON into `.paper-reproduction/analysis/data/`.
- Prefer sources in this order: machine-readable artifacts (`results.json`, metric CSVs)
  → structured logs (TB event files via tbparse) → parsing `console.log` with explicit
  patterns → loading checkpoints and recomputing (last resort — heaviest and easiest to
  get subtly wrong; when you must, reuse the repo's own eval code paths rather than
  reimplementing the metric).
- The script reads the run directories from stage 5's index; if a needed artifact is
  missing or malformed, that is a reported finding for that experiment, not a reason to
  substitute a number from anywhere else.
- When `baselines.md` exists, extract reproduced-baseline metrics the same way: scripts
  read each baseline's run directories via the absolute paths in its run index, and only
  datapoints its own stage-5 report marks COMPLETE are used — the same evidence rules,
  applied per repo. If the main env cannot read a baseline's artifacts, run that
  extraction script under the baseline's env named in `baselines.md` (still read-only:
  never install into either env).
- Aggregate the way the paper does (mean over seeds, best-of-N tries, final epoch vs best
  epoch…). When the paper is ambiguous about aggregation, pick the most defensible reading,
  do it in the script, and state the choice in the report — it is a prime suspect for any
  gap.

### 4. Regenerate the paper's presentation from the actual results

Imitate the paper's own presentation so the two sides are comparable at a glance:

- **Table** → a markdown table in the report mirroring the paper's layout, with the paper
  value and the reproduced value adjacent (paired columns per metric), plus a delta —
  absolute, and relative where scales make it meaningful. Cells the paper has but the runs
  don't cover (or vice versa) are marked `—` with a one-line reason, never left blank.
  With reproduced baselines, keep the paper's row structure: one row per method (main and
  each baseline), each carrying its own paper/ours/Δ triple; baseline rows without a
  reproduced value keep the paper value with `—` for ours. Annotate rows whose
  reproduction `baselines.md` flags as unofficial code or protocol-deviating.
- **Plot** → a matplotlib figure generated by a script in `analysis/scripts/`, reading only
  the extracted CSV/JSON from `analysis/data/`, imitating the paper's axes, scales, ranges,
  and labels, saved as PNG in `analysis/figures/`. Matching the paper's axis ranges matters
  more than looking pretty: same limits, same log/linear choice, so shapes are visually
  comparable.

### 5. Render the paper's side and present the two together

- For a **plot**, crop the paper's figure out of the PDF: render the page and clip the
  figure region to a PNG (pymupdf), saved in `analysis/figures/` as
  `paper-<figure-id>.png`. The report then embeds the paper's crop and your regenerated
  plot side by side. Do not overlay paper curves onto your plot — the only paper values
  that may ever appear on your axes are ones the paper states numerically, and the default
  is not to overlay at all.
- For a **table**, the paired-column markdown table from step 4 *is* the side-by-side.
- Under each comparison, write factual observations only: the deltas, which direction they
  run, trends that match or don't (monotonicity, orderings, curve shape), and anything
  stage 5's Notes flagged that bears on interpretation (e.g. training was still improving
  at the epoch cap). **No verdict** — no "REPRODUCED", no "failed to reproduce", no score.
  Deciding whether a 2-point gap matters is the human's call, and a verdict from this stage
  would anchor that judgment on evidence the reader hasn't weighed yet.

## Output format

ALWAYS use this exact structure, saved to `.paper-reproduction/result-analysis.md` under
the repo root (update it incrementally as experiments finish — a crash must not lose
completed comparisons):

`````markdown
# Result Analysis Report

## Summary
- Analyzed: <N> experiments; not analyzed: <N> (upstream verdicts)
- One line per experiment: what was compared against what, and a pointer to its section.

| Experiment | Paper presentation | Mode | Status |
|---|---|---|---|
| Exp 1: <name> | Figure 1, p. 5 | plot | ANALYZED |
| Exp 2: <name> | Table 2, p. 7 | table | NOT ANALYZED (stage 5: FAILED) |

---

## Experiment 1: <name>

**Paper presentation:** <Figure/Table N, page, what it shows — axes/columns and metrics.>

**Extraction:** <source (results.json / TB events / console.log / checkpoints), the
script, the data file(s) it wrote, and the aggregation used (with the paper's wording
if the choice was ambiguous).>

**Side-by-side:**
For a plot — embed both images:
| Paper (Figure N) | Reproduction |
|---|---|
| ![paper](analysis/figures/paper-fig1.png) | ![ours](analysis/figures/exp1-fig1.png) |

For a table — one paired-column table (Method column only when reproduced baselines exist):
| Method | Setting | Paper | Ours | Δ |
|---|---|---|---|---|
| ours (SUWR) | cifar10 | 91.2 | 90.8 | −0.4 |
| L2X (baseline, unofficial code) | cifar10 | 88.1 | 87.5 | −0.6 |
| INVASE (baseline) | cifar10 | 89.0 | — (stage 5.5: FAILED) | — |

**Observations:** factual notes only — deltas and their direction, matching/diverging
trends, caveats inherited from stage 5's Notes. No verdict.

---

## Not analyzed
Per skipped experiment: the upstream verdict and reason, verbatim from stage 5.

## Scripts and data index
Every script, data file, and figure produced, with paths and a one-line purpose each —
the audit trail: rerunning the scripts must regenerate every number and figure above.

## Environment used
The env name and the versions of the analysis-relevant packages the scripts were written
against; any missing package recorded as a blocker for stage 3 (environment-setup).

## Notes
Anything the reader needs to weigh the comparison: ambiguous aggregation choices,
artifacts that were missing or odd, differences in what was run vs what the paper ran
(fewer seeds, one dataset of three, …).
`````

## Boundaries

- **Never edit the codebase, never commit, never launch or re-run training/eval runs.**
  The runs on disk are the evidence; if they are insufficient, the report says so and the
  gap routes back to stage 5 (or 4), not through new execution here.
- The environment is **read-only**: never install, upgrade, or remove any package. Write
  scripts against the installed versions; report missing packages as stage-3 blockers.
- Never fabricate paper data: no digitizing curves, no estimating values off a figure, no
  filling gaps by interpolation. Paper numbers come only from table cells and stated text.
- Never analyze runs stage 5 did not mark COMPLETE, and never blend validation-era or
  mock-run outputs into the comparison.
- Every reported number must trace to a saved script and data file under
  `.paper-reproduction/analysis/` — a number that exists only in the report text is a bug.
- All new files live under `.paper-reproduction/analysis/` (plus the report itself under
  `.paper-reproduction/`); nothing is written anywhere else in the repo. Baseline repos
  are read-only sources of run artifacts — never written to at all.
- No verdicts: present, compare, observe — the reproduction judgment belongs to the human.

---
name: experiment-scoping
description: First stage of a paper-reproduction pipeline, run from inside a cloned paper codebase that has the paper's PDF placed in it. Use whenever the task is to study the paper together with its code and decide which experiments to reproduce. For each experiment, produce one runnable command with hyperparameter flags, justification for non-obvious hyperparameter choices, and the datasets/checkpoints it needs. Do not use for downloading datasets/checkpoints, setting up environments, or executing and debugging runs.
---

# experiment-scoping

Turn a paper + codebase pair into a concrete, grounded experiment plan: one command per
experiment, ready to be smoke-tested by later pipeline stages.

## Position in the pipeline

This is stage 1 of a reproduction pipeline. Your output is consumed by machines and agents,
not only humans:

- **resource-download** (stage 2) reads your dataset/checkpoint list to fetch assets.
- **code-fix** (stage 4) runs your commands verbatim and fixes errors iteratively.

So the plan must be *actionable without you*: every command must be copy-paste runnable from
the repo root (given the assets exist), and every asset must be named precisely enough to
download. Vague output here poisons every downstream stage.

## Inputs

This skill assumes it is invoked **from inside the cloned codebase** (the paper's official
implementation), and that the paper's PDF has been **manually copied into the repo** by the
user. So:

- The codebase is the current working directory (or the directory the user points at).
- Find the paper PDF by globbing for `*.pdf` in the repo (root first, then recursively,
  ignoring obvious non-paper PDFs like figures or docs). If several candidates exist, pick
  the one that looks like the paper and say which you chose. Read it directly with the Read
  tool; it handles PDFs.

If no PDF is found, or the directory doesn't look like a paper's implementation, say so and
stop — do not scope from the paper alone or the code alone. The whole value of this stage is
reconciling the two.

## Process

### 1. Study the paper — briefly, and with a purpose

You are not writing a review. Read only what you need to answer three questions: *what
experiments does the paper report, what would it take to rerun each one, and which
hyperparameters matter?* In practice that means:

- Abstract + intro: what is the core claim.
- The experiments/results section: enumerate the distinct experiments (main results table,
  ablations, transfer/generalization studies). Note the datasets, model variants, baselines,
  and metrics for each.
- Implementation-details / setup subsections and appendix tables: this is where
  hyperparameters live (learning rate, batch size, epochs/steps, seeds, schedules,
  architecture knobs). Record page/table numbers — you will cite them as justification.

Skip related work and most of the method's math; you need the method only well enough to
recognize its knobs in the code.

### 2. Map the codebase's entry points

Find how the authors intend the code to be run:

- README usage examples and any `scripts/`, `examples/`, `configs/` directories, shell
  scripts, and Makefiles — these are the authors' own invocations and the strongest signal.
- **Read the argparse sections** (or click/hydra/gin/yaml config definitions) of every run
  script the experiments would use. This is required, not optional: it tells you the real
  flag names, their defaults, their choices, and often reveals flags the README never
  mentions. A flag's default in code frequently differs from the paper's value — that gap is
  exactly what your justifications must surface.

### 3. Reconcile paper and code

For each experiment from step 1, match it to an entry point from step 2, then decide every
hyperparameter by this precedence:

1. An author-provided script/config that explicitly corresponds to that experiment — use it
   as-is unless it contradicts the paper.
2. The paper's stated value, expressed via the real flag name from argparse.
3. The code's default, when the paper is silent — note that you are trusting the default.
4. Your own inference, only when neither source says anything — always justify it.

When paper and code disagree (paper says lr 3e-4, default is 1e-3), prefer the paper but
flag the discrepancy explicitly; discrepancies are prime suspects for later reproduction
gaps.

### 4. Select the experiment set

Prefer the smallest set that covers the paper's headline claims: usually every row-group of
the main results table, plus ablations only if the user asked for full coverage. If the
paper has many dataset × model combinations, pick one representative combination per claim
and say why. List what you deliberately left out.

### 5. Write one mock-run command per experiment

Each command's purpose downstream is a *mock run*: proving the pipeline executes end-to-end,
not reproducing final numbers. So:

- Keep all scientifically meaningful hyperparameters paper-faithful (lr, batch size, model
  size, dataset) — a mock run with fake hyperparameters validates nothing.
- Scale down only duration-type knobs (epochs/steps, eval frequency, number of seeds) and
  say what the full-run value would be.
- Never invent a flag. Every flag in the command must exist in the argparse/config you read
  in step 2. If a needed knob has no flag, say so — that is a finding, not something to
  paper over.
- Use paths as placeholders in an obvious, consistent form (`<DATA_DIR>/cifar10`,
  `<CKPT_DIR>/resnet50.pth`) so stage 2 can substitute real paths mechanically.

## Output format

ALWAYS use this exact structure (one block per experiment):

`````markdown
# Experiment Scoping Report

## Paper summary
2-4 sentences: core claim, and which experiments substantiate it.

## Experiments selected
Bullet list of selected experiments and one line on anything deliberately excluded.

---

## Experiment 1: <name, e.g. "Main result — CIFAR-10 classification (paper Table 1)">

**Command** (run from repo root):
```bash
python train.py --dataset cifar10 --lr 3e-4 --batch-size 128 --epochs 2 ...
```

**Mock-run downscaling:** which flags were reduced and their paper-faithful values
(e.g. `--epochs 2` for the mock run; paper uses 200).

**Hyperparameter justification** (non-obvious choices only — skip flags whose value is
both the code default and uncontroversial):
- `--lr 3e-4`: paper §4.1 / Table 5; code default is 1e-3 — discrepancy, following paper.
- `--warmup 1000`: not in paper; using code default.

**Datasets needed:**
- cifar10 — auto-downloaded by torchvision / manual from <URL> — expected at `<DATA_DIR>/cifar10`

**Checkpoints needed:**
- resnet50 ImageNet-pretrained — from <URL or hub name> — expected at `<CKPT_DIR>/resnet50.pth`
- (or "none — trains from scratch")

**Notes / risks:** missing flags, paper-code discrepancies, anything ambiguous.
`````

For checkpoints, include a rough size or parameter count when the paper/repo states one —
stage 2 uses it for hardware feasibility checks.

## Boundaries

- This skill reads and plans. It does not download anything, create environments, install
  packages, or execute the commands it writes.
- Do not fix code, even if you spot a bug — record it under Notes/risks for later stages.
- If the codebase clearly cannot run some paper experiment (no entry point exists), report
  that honestly rather than fabricating a command.

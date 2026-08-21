---
name: environment-setup
description: Set up or repair the Python environment for a research/paper codebase, run from inside the cloned repo. Works standalone on any repo, and also serves as stage 3 of a paper-reproduction pipeline. Use whenever the task is to create the conda/Python environment a repo needs, resolve and pin package versions, work out Python/CUDA/torch compatibility, or repair a broken environment given an install, import, or version-conflict error (including errors fed back from a later run-and-fix stage). Do not use for scoping experiments from the paper, downloading datasets/checkpoints, or fixing the repo's own code.
---

# environment-setup

Turn a repo's scattered version evidence into one working conda environment, with every
package version captured in a lockfile and every non-obvious choice justified in a report.

## Position in the pipeline

This skill runs standalone on any repo, and doubles as stage 3 of a reproduction
pipeline. When the pipeline context exists, use it:

- **experiment-scoping** (stage 1) may have produced
  `.paper-reproduction/experiment-scoping.md`, which tells you which entry points the
  experiments invoke and whether they train on GPU or only run inference — that sharpens
  what must be importable and whether CUDA must work. If the report is absent, derive
  the same facts from the repo itself (see Inputs); its absence is never a reason to
  stop.
- **run-validation** (stage 4) consumes *your* output: it activates the env you name and runs
  the planned commands verbatim. When a run fails with an environment error, it invokes
  this skill again in **repair mode** with the error text.

Either way, your report must be mechanically actionable: an exact activation command, an
exact lockfile path, and honest verification results. An env that "should work" but was
never import-tested wastes a full debug cycle later on a problem you could have caught
in seconds here.

## Three modes

- **Fresh setup** (the default): no env exists yet for this repo — build one.
- **Repair**: you are given an existing env plus an error (typically by stage 4, or by a
  user pasting a traceback). Fix the env in place with the smallest change that resolves
  the error. Repair reuses the same version-precedence rules as fresh setup; it is
  described after the main process below.
- **Fresh setup with a candidate env**: the invoker names an existing env to try before
  building one (the baseline-reproduction stage passes the main repo's
  `pr-<main-repo-dirname>` when setting up a baseline repo). Reuse is all-or-nothing —
  see "Candidate-env check" below.

## Inputs

- The codebase is the current working directory (or the directory the user points at).
- **The scoping report** at `.paper-reproduction/experiment-scoping.md` is optional but
  valuable when present: it names the entry points the experiments invoke (your
  import-verification targets), whether runs need GPU, and sometimes dependency caveats
  a spec scan would miss. If it is absent, proceed anyway and derive the same facts
  yourself: entry points from the README's usage examples and the repo's run scripts,
  and the GPU expectation from the hardware ("host has a GPU ⇒ install a CUDA torch
  build and `torch.cuda.is_available()` must pass"). Note in the report that this was a
  standalone run without a scoping report.
- **Repair** needs the env name and the error text; the scoping report and a previous
  `environment-setup.md` are used when present but their absence doesn't block a repair.
- A **candidate env** name may be supplied by the invoker (see "Candidate-env check");
  absent one, fresh setup proceeds directly.
- The paper PDF (if present in the repo) is a legitimate version source — see tier 3.

## Candidate-env check

When the invoker names a candidate env, decide reuse before doing any creation work:

1. Inventory this repo's requirements exactly as in step 1 (tier precedence applies),
   then compare against what the candidate actually has
   (`conda run -n <candidate> pip freeze`).
2. Run the step-4 verification *inside the candidate*: import the major packages this
   repo needs at the versions found, import this repo's entry-point modules, check
   `torch.cuda.is_available()` as usual.
3. **Reuse only on a clean pass with zero installs.** The candidate belongs to another
   repo — installing, upgrading, or removing anything in it could silently break that
   repo's validated runs. Any missing package, any conflict with a tier-1 pin of this
   repo, or any failed import means: leave the candidate untouched and fall through to a
   normal fresh setup (`pr-<this-repo-dirname>`).
4. On reuse: skip creation and the lockfile export (the owning repo's lockfile stays the
   authoritative record); write this repo's report naming the candidate env, recording
   the verification results, and stating plainly that the env is **reused — do not
   modify**. If a later repair invocation targets a reused env, the reuse bet has failed:
   never modify the candidate — build this repo its own env instead (fresh setup), then
   update the report.

## Process (fresh setup)

### 1. Inventory every version-evidence source

Search the repo for spec files and rank all evidence into tiers. **Higher tiers win
whenever two sources disagree; lower tiers only fill gaps** the higher ones leave open.

**Tier 1 — lockfiles and pinned specs** (the authors' machine, written down):
`environment.yml`, `requirements.txt`, `setup.py` / `pyproject.toml`, `poetry.lock`,
`Pipfile.lock`, `conda-lock.yml`, and any **Dockerfile**.

Treat a Dockerfile purely as a *spec document*, never something to build or run: the base
image tag encodes exact python/CUDA/torch versions (e.g.
`pytorch/pytorch:1.13.1-cuda11.6-cudnn8-runtime`, `nvcr.io/nvidia/pytorch:22.08-py3` —
look up what the NGC tag ships), and its `RUN pip install` / `apt-get install` lines are
as authoritative as a requirements file. The actual environment is always conda + pip:
pip torch wheels bundle the CUDA runtime, so Docker's main benefit is already covered,
and downstream stages need commands that run directly on the host, not inside a container.

Within tier 1, note *how pinned* each file is: a `requirements.txt` with `==` pins gives
you versions; one with bare names gives you only the package list, and its versions fall
through to lower tiers or inference.

**Tier 2 — README / docs install instructions**: exact commands the authors published
(`conda create -n x python=3.7`, `pip install torch==1.8.0`). Weaker than tier 1 only
because READMEs drift out of date more often than lockfiles.

**Tier 3 — the paper**: implementation-details sections and appendices sometimes state
framework versions ("implemented in PyTorch 1.4"). Cite the section when you use one.

**Tier 4 — inference from imports**: only when tiers 1–3 leave a version undetermined.
Procedure:

1. **Python and torch first**, from clues in the code itself: API calls, syntax, and
   import styles that only exist in certain version ranges. Examples of the reasoning:
   `torch.cuda.amp` ⇒ torch ≥ 1.6; `torch.func` ⇒ ≥ 2.0; `Variable(...)`-heavy code ⇒
   the ≤ 1.4 era; walrus operator ⇒ python ≥ 3.8; `from __future__ import annotations`
   absent but PEP-604 `int | None` used ⇒ ≥ 3.10. Use clues to bound from both sides —
   an API that was later removed or renamed caps the version from above.
2. If the clues still admit multiple python/torch versions, **disambiguate by
   contemporaneous research practice**: date the repo (`git log -1 --format=%cI`) and
   pick the python/torch combination that comparable research code of that period
   typically used (e.g. a mid-2020 vision repo overwhelmingly means python 3.7/3.8 +
   torch 1.5–1.6).
3. **Every other package**: infer its presence from imports, then pin a version that
   (a) is consistent with the API usage you actually see in the code, and (b) forms a
   **mutually conflict-free set** with python, torch, and the other pins — verify with a
   resolver dry-run (`pip install --dry-run ...`) and adjust on conflict, then
   `pip check` after the real install. The commit-era is a tiebreak signal, not a rule:
   the right pin is *not* necessarily the latest release before the commit date — set
   compatibility is the requirement, era only breaks remaining ties.

Record, per resolved fact (python version, torch version, each pinned package), which
tier decided it — this becomes the Spec-sources table in the report.

### 2. Resolve Python and CUDA/torch explicitly

This pair is called out because it is where most reproduction environments die.

- **Python**: from the specs; if unstated, from tier-4 clues + era.
- **Host GPU reality**: `nvidia-smi` for the driver version (treat a missing `nvidia-smi`
  as "no GPU → CPU-only torch", not an error). Also check what the experiments need —
  from the scoping report when present, otherwise from the README/run scripts: an
  inference-only plan on small models may not need CUDA at all.
- **torch build**: pick the wheel whose CUDA runtime is supported by the host *driver*
  (the driver is the only host-side constraint — pip wheels ship their own CUDA runtime,
  no system toolkit needed). Use the official torch/CUDA compatibility table and install
  with the matching index, e.g.
  `pip install torch==1.13.1+cu116 --extra-index-url https://download.pytorch.org/whl/cu116`.
- **When the repo's pin can't work here** (torch build too old for the driver or for any
  python you can conda-install, wheel no longer published): choose the nearest version
  that installs and satisfies the code's API usage, and record it as a deviation with the
  reasoning. A recorded deviation is recoverable; a silent substitution poisons stage 4's
  debugging.

### 3. Create the environment

One conda env per repo, named `pr-<repo-dirname>` (predictable, so stage 4 and the user
can find it without reading the report).

- If a usable `environment.yml` exists: `conda env create -f environment.yml -n pr-<name>`.
- Otherwise: `conda create -n pr-<name> python=X.Y -y`, then install everything else with
  the **env's own pip** (`conda run -n pr-<name> pip install ...`).
- Install torch (with its index URL) **before** the bulk of requirements, then install the
  rest — if a requirements line would replace the carefully chosen torch build, constrain
  it (`--no-deps` for the offender, or add the torch pin to the same install command so
  the resolver respects it).
- If the repo is a package (`setup.py`/`pyproject.toml`), finish with `pip install -e .`
  so the entry points import the way the authors intended.

### 4. Verify before declaring success

Run, inside the env:

- Import every major package and print its version — confirm the pins actually took.
- `python -c "import torch; print(torch.cuda.is_available())"` — must be `True` when GPU
  use is expected (scoping report says so, or the host simply has a GPU and you installed
  a CUDA build); if it is `False` on a GPU machine, the env is *not done*, whatever pip
  said.
- Import the entry-point modules the experiments will run — those named in the scoping
  report's commands when present, otherwise the run scripts the README points at (e.g.
  `python -c "import train"` or the package path the scripts use) — **import only, never
  run the commands**; execution and its errors belong to the run-and-fix stage.
  Import-time `ModuleNotFoundError`s are yours to fix now, in a repair-style loop,
  before writing the report.

### 5. Install the analysis-stage packages

After all of the repo's own packages are pinned and verified, install the packages the
final result-analysis stage's scripts need: `matplotlib`, `pandas`, `numpy`, `pymupdf`,
`tbparse`.

- These come **last** so they can never influence the version resolution of the repo's
  own dependencies, and they must not disturb it either: if one of them (or a dependency,
  e.g. numpy via pandas) is already installed at a pinned version, keep that version —
  add explicit pins for the already-installed ones to the install command so the resolver
  respects them, rather than letting it upgrade.
- If a version conflict makes one of them uninstallable alongside the repo's pins,
  install the newest version that fits; if nothing fits, skip that package and record it
  in Notes — the repo's environment always wins over analysis conveniences.
- Verify with a quick import of each (`matplotlib`, `pandas`, `numpy`, `fitz`,
  `tbparse`), and re-run `pip check`.

### 6. Export the lockfile

Write `.paper-reproduction/environment.lock.txt`:

- `conda run -n pr-<name> pip freeze` output (the authoritative package-version list);
- plus a short header recording python version, and for conda-created deps
  `conda env export --no-builds -n pr-<name>` appended under a separator when conda
  installed anything beyond python itself.

This file is the authoritative record of what got installed — the run-and-fix stage (or
the user) uses it to know exactly what it is debugging against, and the env can be
rebuilt from it.

## Repair mode

Invoked with an env name and an error (stage 4 feeds you the traceback and the current
env; a user may paste an error directly).

1. **Diagnose first**: is this actually an environment error? Env errors: import errors,
   version-attribute errors (`module 'x' has no attribute 'y'` from an API that moved),
   ABI/binary errors (numpy 2.x vs modules compiled against 1.x), CUDA
   runtime/initialization errors, resolver conflicts. Code errors: logic exceptions,
   shape mismatches, missing files, argparse failures. If it is a code error, say so
   explicitly and hand it back — fixing code is stage 4's job, and misclassifying here
   causes the two stages to fight each other.
2. **Smallest change that fixes it**, chosen under the same tier precedence as fresh
   setup: prefer adjusting the one offending package; respect existing pins that came
   from tier-1 specs (if the fix requires overriding one, that is a deviation to record,
   with why); typical fixes — install the missing package at an era/API-consistent
   version, move one version pin, swap the torch build's CUDA variant, cap numpy below
   2.0. Rebuild the env from scratch only when it is genuinely unsalvageable, and say so.
3. **Re-verify** (the step-4 checks, at minimum the failing import) and **re-export the
   lockfile** — a repaired env with a stale lockfile is worse than no lockfile, because
   it lies.
4. **Append to the Repair log** in `environment-setup.md` (create the report if it
   doesn't exist): the error, the diagnosis, the change, and the re-verification result.

## Output format

ALWAYS use this exact structure, saved to `.paper-reproduction/environment-setup.md`
under the repo root:

`````markdown
# Environment Setup Report

## Environment
- **Conda env:** pr-<name>
- **Activation:** `conda activate pr-<name>`
- **Python:** 3.x.y
- **Lockfile:** .paper-reproduction/environment.lock.txt
- **Scoping report:** used / not found — standalone run (entry points and GPU
  expectation derived from the repo)

## CUDA / torch
- Host: <GPU + driver version, or "no GPU — CPU-only">
- torch <version> (<cuXXX / cpu> build) — <one line: why this build is compatible with
  the host driver and the repo's requirement>

## Spec sources
| Fact | Value | Decided by | Source detail |
|---|---|---|---|
| python | 3.7 | Tier 1 | Dockerfile base image pytorch/pytorch:1.4-cuda10.1 |
| torch | 1.4.0 → 1.13.1 | Tier 1 + deviation | pinned 1.4.0 uninstallable on host, see Deviations |
| numpy | 1.21.6 | Tier 4 | inferred from imports; conflict-free with torch pin |

## Deviations
Every place the env differs from what the specs say, with why — or "none".

## Verification
- Package imports: <which, and versions printed>
- torch.cuda.is_available(): <True/False/n.a., and whether that meets the expected GPU use>
- Entry-point imports: <which modules were imported (from the scoping commands, or the
  README/run scripts on a standalone run), results>
- Analysis packages: <matplotlib / pandas / numpy / pymupdf / tbparse versions installed
  for the result-analysis stage, and any skipped due to conflicts>

## Notes
Anything whoever runs the code next should know: packages installed --no-deps and why,
suspected fragile pins, conda-vs-pip split, warnings seen during install.

## Repair log
(empty on fresh setup; repair invocations append dated entries: error → diagnosis →
change → re-verification)
`````

## Boundaries

- This skill builds and repairs environments. It does not run experiment commands, does
  not edit the repo's code (even to fix an obvious bug — record it in Notes for stage 4),
  and does not download datasets or checkpoints (stage 2's job; don't "helpfully" fetch a
  missing dataset while fixing an env error).
- Never build or run Docker images — Dockerfiles are read as version specs only.
- In repair mode, if the error is a code error, report that verdict back instead of
  attempting any fix.
